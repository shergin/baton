//! Identity: the fields that key a record of each object type, from the
//! `identity` block of `baton.json`, and the transform that selects them
//! wherever a type is read, as Relay's `generate_id_field` selects `id`.
//! A key is the values of those fields at the write, in the configured
//! order; a type whose fields do not include them is keyed by its path.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use common::{Diagnostic, Location, WithLocation};
use graphql_ir::{
    InlineFragment, LinkedField, Program, ScalarField, Selection, Transformed, TransformedValue,
    Transformer,
};
use intern::Lookup;
use intern::string_key::Intern;
use schema::{FieldID, ObjectID, SDLSchema, Schema, Type};

use crate::config::Identity;

/// The key fields of every object type that has a key, by the type's name.
#[derive(Debug, Default, Clone)]
pub struct Keys {
    by_type: BTreeMap<String, Vec<String>>,
}

impl Keys {
    /// Resolves the configuration against the schema. A type's own entry,
    /// else the entry of an interface it implements, else the default; the
    /// default applies silently where every field is a scalar of the type,
    /// an entry is an error where one is not.
    pub fn resolve(
        schema: &SDLSchema,
        identity: &Identity,
        location: Location,
    ) -> Result<Keys, Vec<Diagnostic>> {
        let mut errors = Vec::new();
        let mut fail = |message: String| errors.push(Diagnostic::error(message, location));
        for (name, fields) in &identity.types {
            match schema.get_type(name.intern()) {
                Some(Type::Object(_)) | Some(Type::Interface(_)) => {}
                Some(_) => fail(format!(
                    "the identity of `{name}` is configured, but `{name}` is not an object or interface type"
                )),
                None => fail(format!(
                    "the identity of `{name}` is configured, but the schema has no such type"
                )),
            }
            check_list(name, fields, &mut fail);
        }
        check_list("the default", &identity.default, &mut fail);
        let mut by_type = BTreeMap::new();
        for object in schema.get_objects() {
            let name = object.name.item.0.lookup();
            let (fields, explicit) = match identity.types.get(name) {
                Some(fields) => (fields.clone(), true),
                None => {
                    let mut inherited: BTreeSet<&Vec<String>> = BTreeSet::new();
                    for interface in &object.interfaces {
                        let interface_name = schema.interface(*interface).name.item.0.lookup();
                        if let Some(fields) = identity.types.get(interface_name) {
                            inherited.insert(fields);
                        }
                    }
                    match inherited.len() {
                        0 => (identity.default.clone(), false),
                        1 => (inherited.into_iter().next().unwrap().clone(), true),
                        _ => {
                            fail(format!(
                                "`{name}` implements interfaces whose identities differ: configure the identity of `{name}` itself"
                            ));
                            continue;
                        }
                    }
                }
            };
            let Some(type_ @ Type::Object(_)) = schema.get_type(object.name.item.0) else {
                continue;
            };
            let mut keyed = true;
            for field in &fields {
                match schema.named_field(type_, field.intern()) {
                    Some(id) if is_key_field(schema, id) => {}
                    Some(_) if explicit => fail(format!(
                        "the identity of `{name}` names `{field}`, which is not a scalar of one value: a key is own scalar fields"
                    )),
                    None if explicit => fail(format!(
                        "the identity of `{name}` names `{field}`, which `{name}` does not have"
                    )),
                    _ => keyed = false,
                }
            }
            if keyed {
                by_type.insert(name.to_string(), fields);
            }
        }
        if !errors.is_empty() {
            return Err(errors);
        }
        Ok(Keys { by_type })
    }

    /// The key fields of an object type, in order; none for a type keyed by
    /// its path.
    pub fn of(&self, type_name: &str) -> Option<&[String]> {
        self.by_type.get(type_name).map(Vec::as_slice)
    }
}

/// A key names at least one field, each an own field: a path through a
/// link waits for an entity with no scalar key of its own.
fn check_list(owner: &str, fields: &[String], fail: &mut impl FnMut(String)) {
    if fields.is_empty() {
        fail(format!("the identity of {owner} names no field"));
    }
    for field in fields {
        if field.contains('.') {
            fail(format!(
                "the identity of {owner} names `{field}`: a key is own scalar fields, not a path through a link"
            ));
        }
    }
}

/// Whether a field can key a record: a scalar or enum of one value, not a
/// list, and not a `Float` or `Boolean`, whose texts do not name a thing.
fn is_key_field(schema: &SDLSchema, field: FieldID) -> bool {
    let field = schema.field(field);
    if field.type_.is_list() {
        return false;
    }
    match field.type_.inner() {
        Type::Enum(_) => true,
        Type::Scalar(_) => {
            let name = schema.get_type_name(field.type_.inner()).lookup();
            name != "Float" && name != "Boolean"
        }
        _ => false,
    }
}

/// Selects every type's key fields where a document reads the type, so
/// that a record is keyed however the document reached it. An object type
/// gets the fields it lacks unaliased; an abstract type gets each of its
/// members' fields under `... on Member`, or on itself where it declares
/// them and every keyed member shares them. Runs after Relay's transforms,
/// on the programs the server and the ingest see, as Relay's `id` does. A
/// field aliased to a key field's name is an error: the alias would take
/// the key's place in the response.
pub fn select_key_fields(program: &Program, keys: &Keys) -> Result<Program, Vec<Diagnostic>> {
    let mut transform = SelectKeyFields {
        program,
        keys,
        errors: Vec::new(),
    };
    let next = transform
        .transform_program(program)
        .replace_or_else(|| program.clone());
    if !transform.errors.is_empty() {
        return Err(transform.errors);
    }
    Ok(next)
}

struct SelectKeyFields<'a> {
    program: &'a Program,
    keys: &'a Keys,
    errors: Vec<Diagnostic>,
}

impl Transformer<'_> for SelectKeyFields<'_> {
    const NAME: &'static str = "SelectKeyFields";
    const VISIT_ARGUMENTS: bool = false;
    const VISIT_DIRECTIVES: bool = false;

    fn transform_linked_field(&mut self, field: &LinkedField) -> Transformed<Selection> {
        let selections = self.transform_selections(&field.selections);
        let schema = &self.program.schema;
        let target = schema.field(field.definition.item).type_.inner();
        let location = field.definition.location;
        let mut added: Vec<Selection> = Vec::new();
        match target {
            Type::Object(id) => {
                self.refuse_aliases(id, &field.selections);
                for key_field in self.missing(id, &field.selections) {
                    added.push(scalar(location, key_field));
                }
            }
            Type::Interface(_) | Type::Union(_) => {
                let members = self.members(target);
                for member in &members {
                    self.refuse_aliases(*member, &field.selections);
                }
                let shared = self.shared_key(target, &members);
                let mut inline: Vec<(String, Vec<FieldID>)> = Vec::new();
                // The fields a member of the shared key lacks, selected on the
                // abstract type itself, once for every such member.
                let mut on_type: Vec<FieldID> = Vec::new();
                for member in &members {
                    let missing = self.missing(*member, &field.selections);
                    if missing.is_empty() {
                        continue;
                    }
                    let name = schema.object(*member).name.item.0.lookup();
                    if shared
                        .as_ref()
                        .is_some_and(|shared| self.keys.of(name) == Some(shared))
                    {
                        for id in missing {
                            let declared = schema
                                .named_field(target, schema.field(id).name.item)
                                .expect("a shared key is declared by the type");
                            if !on_type.contains(&declared) {
                                on_type.push(declared);
                            }
                        }
                        continue;
                    }
                    inline.push((name.to_string(), missing));
                }
                for id in on_type {
                    added.push(scalar(location, id));
                }
                inline.sort_by(|left, right| left.0.cmp(&right.0));
                for (name, missing) in inline {
                    let type_ = schema.get_type(name.intern()).expect("a member is a type");
                    added.push(Selection::InlineFragment(Arc::new(InlineFragment {
                        type_condition: Some(type_),
                        directives: Default::default(),
                        selections: missing.into_iter().map(|id| scalar(location, id)).collect(),
                        spread_location: Location::generated(),
                    })));
                }
            }
            _ => {}
        }
        if added.is_empty() {
            return match selections {
                TransformedValue::Keep => Transformed::Keep,
                TransformedValue::Replace(selections) => {
                    Transformed::Replace(linked(field, selections))
                }
            };
        }
        let mut next = selections.replace_or_else(|| field.selections.clone());
        next.extend(added);
        Transformed::Replace(linked(field, next))
    }

    fn transform_scalar_field(&mut self, _field: &ScalarField) -> Transformed<Selection> {
        Transformed::Keep
    }
}

impl SelectKeyFields<'_> {
    /// The key fields of an object type the selections do not select
    /// unaliased, at their own level or under a condition the type
    /// satisfies.
    fn missing(&self, object: ObjectID, selections: &[Selection]) -> Vec<FieldID> {
        let schema = &self.program.schema;
        let name = schema.object(object).name.item.0.lookup();
        let Some(key) = self.keys.of(name) else {
            return Vec::new();
        };
        key.iter()
            .filter_map(|field| schema.named_field(Type::Object(object), field.intern()))
            .filter(|id| !selects(selections, schema, object, *id))
            .collect()
    }

    /// An alias that takes a key field's name on a keyed type is refused:
    /// the response would carry another value where the key is read.
    fn refuse_aliases(&mut self, object: ObjectID, selections: &[Selection]) {
        let schema = &self.program.schema;
        let type_name = schema.object(object).name.item.0.lookup();
        let Some(key) = self.keys.of(type_name) else {
            return;
        };
        for alias in aliases(selections, schema, object) {
            let name = alias.item.lookup();
            if key.iter().any(|field| field == name) {
                self.errors.push(Diagnostic::error(
                    format!("`{name}` keys `{type_name}`: no field may be aliased to it"),
                    alias.location,
                ));
            }
        }
    }

    /// The possible object types of an abstract type, in the schema's order.
    fn members(&self, type_: Type) -> Vec<ObjectID> {
        let schema = &self.program.schema;
        match type_ {
            Type::Interface(id) => schema
                .interface(id)
                .recursively_implementing_objects(schema.as_ref())
                .into_iter()
                .collect(),
            Type::Union(id) => schema.union(id).members.clone(),
            _ => Vec::new(),
        }
    }

    /// The key every keyed member shares, when the abstract type declares
    /// its fields itself, so one selection on it serves every member.
    fn shared_key(&self, type_: Type, members: &[ObjectID]) -> Option<Vec<String>> {
        let schema = &self.program.schema;
        let mut keys: BTreeSet<&[String]> = BTreeSet::new();
        for member in members {
            if let Some(key) = self.keys.of(schema.object(*member).name.item.0.lookup()) {
                keys.insert(key);
            }
        }
        if keys.len() != 1 {
            return None;
        }
        let key = keys.into_iter().next().unwrap();
        let declared = key
            .iter()
            .all(|field| schema.named_field(type_, field.intern()).is_some());
        declared.then(|| key.to_vec())
    }
}

/// Whether the selections select the field unaliased, at their own level
/// or under an inline fragment the object satisfies: one without a type
/// condition, one on the object itself, or one on an interface or union it
/// belongs to.
fn selects(selections: &[Selection], schema: &SDLSchema, object: ObjectID, id: FieldID) -> bool {
    let name = schema.field(id).name.item;
    selections.iter().any(|selection| match selection {
        Selection::ScalarField(field) => {
            field.alias.is_none() && schema.field(field.definition.item).name.item == name
        }
        Selection::InlineFragment(fragment) => {
            satisfies(schema, object, fragment.type_condition)
                && selects(&fragment.selections, schema, object, id)
        }
        _ => false,
    })
}

/// The aliases the selections give fields of the object, at their own level
/// or under an inline fragment the object satisfies.
fn aliases<'a>(
    selections: &'a [Selection],
    schema: &SDLSchema,
    object: ObjectID,
) -> Vec<&'a WithLocation<intern::string_key::StringKey>> {
    let mut found = Vec::new();
    for selection in selections {
        match selection {
            Selection::ScalarField(field) => found.extend(field.alias.as_ref()),
            Selection::LinkedField(field) => found.extend(field.alias.as_ref()),
            Selection::InlineFragment(fragment)
                if satisfies(schema, object, fragment.type_condition) =>
            {
                found.extend(aliases(&fragment.selections, schema, object));
            }
            _ => {}
        }
    }
    found
}

/// Whether an object is read under a type condition: none, itself, or an
/// interface or union it is a member of.
fn satisfies(schema: &SDLSchema, object: ObjectID, condition: Option<Type>) -> bool {
    match condition {
        None => true,
        Some(Type::Object(id)) => id == object,
        Some(Type::Interface(id)) => schema.object(object).interfaces.contains(&id),
        Some(Type::Union(id)) => schema.union(id).members.contains(&object),
        Some(_) => false,
    }
}

fn scalar(location: Location, id: FieldID) -> Selection {
    Selection::ScalarField(Arc::new(ScalarField {
        alias: None,
        definition: WithLocation::new(location, id),
        arguments: Default::default(),
        directives: Default::default(),
    }))
}

fn linked(field: &LinkedField, selections: Vec<Selection>) -> Selection {
    Selection::LinkedField(Arc::new(LinkedField {
        alias: field.alias,
        definition: field.definition,
        arguments: field.arguments.clone(),
        directives: field.directives.clone(),
        selections,
    }))
}
