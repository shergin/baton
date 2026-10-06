//! The decide pass: what the emitters print, decided from the lowered plan.
//!
//! The emitters only print: every name, nullability, read form, guard,
//! check, binding and type set is settled here, and one pass then collects
//! what the shared file declares from what was decided, so nothing is
//! collected as a side effect of formatting.
//!
//! A normalization selection becomes one list of fields per group of concrete
//! types that read the same fields, plus a list for any other type, and each
//! field carries the `@include` and `@skip` conditions it is fetched under as
//! guards. The runtime settles the guards once per set of variables and the
//! variant once per record, then walks plain lists: nothing tests a type
//! condition or a condition per field. A lens becomes a `ReaderPlan`
//! (`reader`), an operation an `OperationValue` with its optimistic
//! builders (`operation`).

use std::collections::{BTreeMap, BTreeSet};

mod checks;
mod collect;
mod keys;
mod lens;
mod members;
mod operation;
mod reader;

pub use collect::Shared;
pub use keys::{KeyPart, SlotRef, constant_json};
pub use lens::{
    Accessor, AliasGuard, AliasedRead, BoundArgument, ConditionRead, ConnectionMembers, ErrorCheck,
    ErrorLine, Guarded, LinkedForm, LinkedRead, LoadMore, Primitive, Read, ReaderPlan,
    RefetchMembers, SatisfiedCheck, ScalarForm, ScalarRead, ScalarShape, SlotAccess, SpreadForm,
    SpreadGuard, SpreadRead, TypeTest,
};
pub use operation::{BuilderPlan, BuilderValue, OperationValue, VariableBase, VariableValue};

use crate::names::{NameError, Reserved, Written, enum_type_name};
use crate::pipeline::{
    ConditionClass, ConnectionPlan, EditPlan, LookupPlan, Plan, SelectionPlan, StorageKeyPlan,
    TypePlan,
};

/// Everything the emitters print, in the plan's order.
#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub fragments: Vec<FragmentLens>,
    pub operations: Vec<OperationValue>,
    pub shared: Shared,
}

/// A fragment's lens and where it was declared.
#[derive(Debug, Clone, PartialEq)]
pub struct FragmentLens {
    pub name: String,
    /// The file the fragment was declared in.
    pub source: String,
    pub type_condition: String,
    pub lens: ReaderPlan,
}

/// Decides everything the emitters print for `plan`, or returns the names
/// some scope would declare twice. The fragments are decided before the
/// operations and each lens before the lenses nested in it, the order that
/// numbers argument sites.
pub fn program(plan: &Plan) -> Result<Program, Vec<NameError>> {
    let mut readers = reader::Readers::new(plan);
    let builder_names = Reserved::builders(plan.enums.keys().map(|name| enum_type_name(name)));
    let mut duplicates = Vec::new();
    let fragments = plan
        .fragments
        .iter()
        .map(|fragment| FragmentLens {
            name: fragment.name.clone(),
            source: fragment.source.clone(),
            type_condition: fragment.type_condition.clone(),
            lens: readers.fragment(fragment),
        })
        .collect();
    let operations = plan
        .operations
        .iter()
        .map(|operation| {
            operation::operation(
                operation,
                &plan.fragments,
                &mut readers,
                &builder_names,
                &mut duplicates,
            )
        })
        .collect();
    let mut program = Program {
        fragments,
        operations,
        shared: Shared::default(),
    };
    program.shared = Shared::collect(plan, &program);
    let mut all = std::mem::take(&mut readers.duplicates);
    all.extend(duplicates);
    all.extend(program.shared.duplicates(plan));
    // A fragment's field is in the normalization of every operation that
    // spreads the fragment, so its clash with a builder's names is found
    // once per operation: once is told.
    let mut errors: Vec<NameError> = Vec::new();
    for error in all {
        if !errors.contains(&error) {
            errors.push(error);
        }
    }
    debug_assert_eq!(
        program.shared.sites, readers.sites,
        "the collected sites are the ones the lenses allocated"
    );
    if errors.is_empty() {
        Ok(program)
    } else {
        Err(errors)
    }
}

/// A selection set on one type, as the normalization walks it.
#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationSelection {
    pub type_name: String,
    /// The fields that key a record of the selection's type, in order, as
    /// `baton.json` configures them; empty for a type keyed by its path. On
    /// an interface or union, the key its members share, which a type the
    /// build did not list is keyed by; a member with another key has its own
    /// variant.
    pub key: Vec<String>,
    /// Whether the type is an interface or union: the payload's `__typename`
    /// names each record's type.
    pub is_abstract: bool,
    /// One variant for an object type; for an abstract type, one per group
    /// of concrete types that read the same fields, one per interface or
    /// union condition for a type the build did not list, then the one that
    /// serves every other type.
    pub variants: Vec<NormalizationVariant>,
    /// Relay's `__isX: __typename` fields the response answers a type
    /// condition with: the response key and the condition, for a record of
    /// a type the build did not list.
    pub memberships: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationVariant {
    /// The concrete types this variant serves; `None` serves every other type,
    /// or, with a condition, every type a response says satisfies it.
    pub types: Option<Vec<String>>,
    /// The interface or union whose members the variant serves when the
    /// build did not list them: the fields under the condition, with those
    /// every type reads.
    pub condition: Option<String>,
    /// The key of the listed types, where the variant lists them: it may
    /// differ from the selection's. `None` keys by the selection's.
    pub key: Option<Vec<String>>,
    pub fields: Vec<NormalizationField>,
}

impl NormalizationSelection {
    /// Whether a field of the selection, or of one nested in it, is fetched
    /// under an `@include` or `@skip`, so that its plan names `Guards`.
    pub fn has_guards(&self) -> bool {
        self.variants
            .iter()
            .flat_map(|variant| &variant.fields)
            .any(|field| {
                if !field.guards.is_empty() {
                    return true;
                }
                match &field.kind {
                    NormalizationKind::Linked { selection, .. } => selection.has_guards(),
                    _ => false,
                }
            })
    }
}

impl NormalizationVariant {
    /// The type whose slots the variant's fields name: a variant of one type
    /// names that type's, which the runtime then takes as they are.
    pub fn slot_type<'a>(&'a self, selection: &'a NormalizationSelection) -> &'a str {
        match self.types.as_deref() {
            Some([only]) => only,
            _ => &selection.type_name,
        }
    }
}

#[derive(Debug, Clone)]
pub struct NormalizationField {
    pub response_key: String,
    /// Where the document wrote the response key, for a builder whose own
    /// names it clashes with.
    pub written: Option<Written>,
    pub key: StorageKeyPlan,
    /// Alternatives of conjunctions: the field is selected when any
    /// alternative holds. Empty when it is always selected.
    pub guards: Vec<Vec<Guard>>,
    /// The `@defer` label of the part that carries the field.
    pub deferred: Option<String>,
    /// Whether an error on the field is handled by a `@catch`.
    pub caught: bool,
    /// A client field, from a schema extension: never asked of a server,
    /// never waited for, written by a payload committed by hand.
    pub client: bool,
    /// The field itself is a schema extension's: its slot is a client slot
    /// wherever a lens reads it.
    pub extension: bool,
    /// A root field `transient` names: never written to the image, nor the
    /// operations selecting it.
    pub transient: bool,
    pub edit: Option<EditPlan>,
    pub kind: NormalizationKind,
}

/// Two fields are one when the normalization reads them alike, wherever the
/// document wrote them: two occurrences of a field are one field.
impl PartialEq for NormalizationField {
    fn eq(&self, other: &Self) -> bool {
        let NormalizationField {
            response_key,
            written: _,
            key,
            guards,
            deferred,
            caught,
            client,
            extension,
            transient,
            edit,
            kind,
        } = self;
        *response_key == other.response_key
            && *key == other.key
            && *guards == other.guards
            && *deferred == other.deferred
            && *caught == other.caught
            && *client == other.client
            && *extension == other.extension
            && *transient == other.transient
            && *edit == other.edit
            && *kind == other.kind
    }
}

/// Built once per compilation and read by the emitter, so the size
/// difference between a scalar and a linked field is of no account.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum NormalizationKind {
    Scalar {
        /// The field's type, which the builder of an optimistic response
        /// shapes its value by.
        type_: TypePlan,
    },
    Linked {
        plural: bool,
        lookup: Option<LookupPlan>,
        connection: Option<ConnectionPlan>,
        selection: NormalizationSelection,
    },
}

/// One condition of a guard: the variable and the value that selects.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Guard {
    pub variable: String,
    pub passing: bool,
}

/// The normalization selection of an operation, from its root type.
pub fn normalization(root_type: &str, selections: &[SelectionPlan]) -> NormalizationSelection {
    let mut occurrences = Vec::new();
    collect(selections, root_type, &[], None, None, &mut occurrences);
    decide(root_type, &BTreeMap::new(), false, &[], &occurrences)
}

/// A field as one place in the document selects it: under which conditions,
/// for which of the parent's concrete types, in which deferred part.
#[derive(Clone)]
struct Occurrence<'a> {
    selection: &'a SelectionPlan,
    guard: Vec<Guard>,
    /// `None`: every type the parent admits.
    types: Option<Vec<String>>,
    /// The interface or union condition the occurrence is under, when it is
    /// under one that several types satisfy.
    condition: Option<String>,
    deferred: Option<String>,
}

/// The fields a selection set selects at its own level, through inline
/// fragments and conditions; spreads were inlined by the compiler already.
fn collect<'a>(
    selections: &'a [SelectionPlan],
    parent_type: &str,
    guard: &[Guard],
    types: Option<&[String]>,
    deferred: Option<&str>,
    into: &mut Vec<Occurrence<'a>>,
) {
    collect_under(
        selections,
        parent_type,
        guard,
        types,
        Enclosing::None,
        deferred,
        into,
    );
}

/// What encloses a selection on the way down: no condition, an interface
/// or union condition a type the build did not list may satisfy, or a
/// concrete fragment, under which no condition is one such a type can
/// satisfy, whatever is nested inside it.
#[derive(Clone, Copy)]
enum Enclosing<'a> {
    None,
    Condition(&'a str),
    Narrowed,
}

impl<'a> Enclosing<'a> {
    fn condition(self) -> Option<&'a str> {
        match self {
            Enclosing::Condition(condition) => Some(condition),
            Enclosing::None | Enclosing::Narrowed => None,
        }
    }
}

fn collect_under<'a>(
    selections: &'a [SelectionPlan],
    parent_type: &str,
    guard: &[Guard],
    types: Option<&[String]>,
    enclosing: Enclosing<'_>,
    deferred: Option<&str>,
    into: &mut Vec<Occurrence<'a>>,
) {
    for selection in selections {
        match selection {
            SelectionPlan::Scalar { .. } | SelectionPlan::Linked { .. } => into.push(Occurrence {
                selection,
                guard: guard.to_vec(),
                types: types.map(<[String]>::to_vec),
                condition: enclosing.condition().map(str::to_string),
                deferred: deferred.map(str::to_string),
            }),
            SelectionPlan::Inline {
                type_condition,
                condition_types,
                condition_class,
                deferred: label,
                selections: child,
                ..
            } => {
                // A condition on the parent's own type restricts nothing.
                let restriction = match (type_condition, condition_types) {
                    (Some(condition), Some(condition_types)) if condition != parent_type => {
                        Some(match types {
                            Some(types) => types
                                .iter()
                                .filter(|type_name| condition_types.contains(type_name))
                                .cloned()
                                .collect(),
                            None => condition_types.clone(),
                        })
                    }
                    _ => types.map(<[String]>::to_vec),
                };
                // A condition several types satisfy is one a type the build
                // did not list may satisfy too: the response says. One every
                // compiled type satisfies says nothing of such a type, and
                // counts the same. A concrete fragment narrows to one type the
                // build knows, which no unlisted type is: nothing under it, at
                // any depth, belongs to a condition variant.
                let under = match (enclosing, type_condition, condition_class) {
                    (Enclosing::Narrowed, _, _) => Enclosing::Narrowed,
                    (_, Some(_), Some(ConditionClass::Concrete(_))) => Enclosing::Narrowed,
                    (_, Some(named), Some(ConditionClass::Set)) => Enclosing::Condition(named),
                    (_, Some(named), Some(ConditionClass::Always)) if named != parent_type => {
                        Enclosing::Condition(named)
                    }
                    _ => enclosing,
                };
                collect_under(
                    child,
                    parent_type,
                    guard,
                    restriction.as_deref(),
                    under,
                    label.as_deref().or(deferred),
                    into,
                );
            }
            SelectionPlan::Condition {
                variable,
                passing,
                selections: child,
            } => {
                let mut inner = guard.to_vec();
                // A constant condition is settled by Relay's transforms
                // before lowering; what reaches here always holds.
                if let Some(variable) = variable {
                    inner.push(Guard {
                        variable: variable.clone(),
                        passing: *passing,
                    });
                }
                collect_under(child, parent_type, &inner, types, enclosing, deferred, into);
            }
            // Lowering reports a spread on the normalization side as a
            // fault of the compiler, so none reaches here.
            SelectionPlan::Spread { .. } => {}
        }
    }
}

/// A selection from the occurrences of its fields. On an abstract type, each
/// concrete type the type admits reads the fields selected on the abstract
/// type and those under type conditions it satisfies; types that read the
/// same list share a variant, and types that read only the abstract type's
/// own fields are served by the variant for every other type.
fn decide(
    type_name: &str,
    keys: &BTreeMap<String, Vec<String>>,
    is_abstract: bool,
    possible_types: &[String],
    occurrences: &[Occurrence],
) -> NormalizationSelection {
    // The key the selection's records share: the type's own, or the one
    // every keyed member of an abstract type has, which serves a type the
    // build did not list as well.
    let distinct: BTreeSet<&Vec<String>> = keys.values().collect();
    let key: Vec<String> = match distinct.len() {
        1 => distinct.into_iter().next().unwrap().clone(),
        _ => Vec::new(),
    };
    if !is_abstract {
        let all: Vec<&Occurrence> = occurrences.iter().collect();
        return NormalizationSelection {
            type_name: type_name.to_string(),
            key,
            is_abstract,
            variants: vec![NormalizationVariant {
                types: None,
                condition: None,
                key: None,
                fields: merge(&all),
            }],
            memberships: Vec::new(),
        };
    }
    let own: Vec<&Occurrence> = occurrences
        .iter()
        .filter(|occurrence| occurrence.types.is_none())
        .collect();
    let others = merge(&own);
    let mut groups: Vec<(Vec<String>, Vec<String>, Vec<NormalizationField>)> = Vec::new();
    for concrete in possible_types {
        let concrete_key: Vec<String> = keys.get(concrete).cloned().unwrap_or_default();
        let applicable: Vec<&Occurrence> = occurrences
            .iter()
            .filter(|occurrence| {
                occurrence
                    .types
                    .as_ref()
                    .is_none_or(|types| types.contains(concrete))
            })
            .collect();
        // A type that reads what every type reads and is keyed as the
        // selection keys is served by the variant for every other type.
        if applicable.len() == own.len() && concrete_key == key {
            continue;
        }
        let fields = merge(&applicable);
        if fields == others && concrete_key == key {
            continue;
        }
        match groups.iter_mut().find(|(_, existing_key, existing)| {
            *existing_key == concrete_key && *existing == fields
        }) {
            Some((types, _, _)) => types.push(concrete.clone()),
            None => groups.push((vec![concrete.clone()], concrete_key, fields)),
        }
    }
    let mut variants: Vec<NormalizationVariant> = groups
        .into_iter()
        .map(|(types, variant_key, fields)| NormalizationVariant {
            types: Some(types),
            condition: None,
            key: Some(variant_key),
            fields,
        })
        .collect();
    // A variant per interface or union condition, for a type the build did
    // not list that a response says satisfies it: the fields every type
    // reads, with those under the condition.
    let mut conditions: Vec<String> = Vec::new();
    for occurrence in occurrences {
        if let Some(condition) = &occurrence.condition
            && !conditions.contains(condition)
        {
            conditions.push(condition.clone());
        }
    }
    for condition in &conditions {
        let under: Vec<&Occurrence> = occurrences
            .iter()
            .filter(|occurrence| {
                occurrence.types.is_none() || occurrence.condition.as_deref() == Some(condition)
            })
            .collect();
        variants.push(NormalizationVariant {
            types: None,
            condition: Some(condition.clone()),
            key: None,
            fields: merge(&under),
        });
    }
    variants.push(NormalizationVariant {
        types: None,
        condition: None,
        key: None,
        fields: others,
    });
    let mut memberships: Vec<(String, String)> = Vec::new();
    for occurrence in occurrences {
        if let (
            true,
            Some(condition),
            SelectionPlan::Scalar {
                alias: Some(alias), ..
            },
        ) = (
            is_type_membership(occurrence.selection),
            &occurrence.condition,
            occurrence.selection,
        ) && !memberships.iter().any(|(key, _)| key == alias)
        {
            memberships.push((alias.clone(), condition.clone()));
        }
    }
    NormalizationSelection {
        type_name: type_name.to_string(),
        key,
        is_abstract,
        variants,
        memberships,
    }
}

/// One field per response key and deferred part, in the order of first
/// selection, with `__typename` first. Occurrences of a field are selected
/// when any of them is; the child selections of a linked field merge, each
/// child carrying the conditions of the occurrence that selected it when
/// the occurrences differ. Relay's `__isX: __typename` fields record type
/// membership, which the variants already decide, and are dropped.
fn merge(occurrences: &[&Occurrence]) -> Vec<NormalizationField> {
    let mut groups: Vec<(String, Option<String>, Vec<&Occurrence>)> = Vec::new();
    for occurrence in occurrences {
        let response_key = response_key(occurrence.selection);
        if is_type_membership(occurrence.selection) {
            continue;
        }
        match groups
            .iter_mut()
            .find(|(key, deferred, _)| *key == response_key && *deferred == occurrence.deferred)
        {
            Some((_, _, members)) => members.push(occurrence),
            // The ingest reads a response key by the first field that has
            // it, and the initial payload carries the field that is not
            // deferred, so that one goes before any deferred copy.
            None if occurrence.deferred.is_none() => {
                let position = groups
                    .iter()
                    .position(|(key, _, _)| *key == response_key)
                    .unwrap_or(groups.len());
                groups.insert(position, (response_key, None, vec![occurrence]));
            }
            None => groups.push((response_key, occurrence.deferred.clone(), vec![occurrence])),
        }
    }
    let mut fields: Vec<NormalizationField> = groups
        .into_iter()
        .map(|(response_key, deferred, members)| field(response_key, deferred, &members))
        .collect();
    if let Some(position) = fields
        .iter()
        .position(|field| field.response_key == "__typename")
    {
        let typename = fields.remove(position);
        fields.insert(0, typename);
    }
    fields
}

fn field(
    response_key: String,
    deferred: Option<String>,
    members: &[&Occurrence],
) -> NormalizationField {
    let guards = any(members.iter().map(|member| member.guard.clone()).collect());
    let written = written_key(members[0].selection);
    let caught = members.iter().all(|member| caught(member.selection));
    let client = is_client(members[0].selection);
    let extension = is_extension(members[0].selection);
    let transient = is_transient(members[0].selection);
    let edit = members.iter().find_map(|member| edit(member.selection));
    match members[0].selection {
        SelectionPlan::Scalar {
            storage_key, type_, ..
        } => NormalizationField {
            response_key,
            written,
            key: storage_key.clone(),
            guards,
            deferred,
            caught,
            client,
            extension,
            transient,
            edit,
            kind: NormalizationKind::Scalar {
                type_: type_.clone(),
            },
        },
        SelectionPlan::Linked {
            storage_key,
            type_,
            keys,
            is_abstract,
            possible_types,
            lookup,
            connection,
            ..
        } => {
            let differ = members
                .iter()
                .any(|member| member.guard != members[0].guard);
            let mut children = Vec::new();
            for member in members {
                let SelectionPlan::Linked { selections, .. } = member.selection else {
                    continue;
                };
                let guard: &[Guard] = if differ { &member.guard } else { &[] };
                collect(
                    selections,
                    type_.base_name(),
                    guard,
                    None,
                    None,
                    &mut children,
                );
            }
            NormalizationField {
                response_key,
                written,
                key: storage_key.clone(),
                guards,
                deferred,
                caught,
                client,
                extension,
                transient,
                edit,
                kind: NormalizationKind::Linked {
                    plural: type_.is_list(),
                    lookup: lookup.clone(),
                    connection: connection.clone(),
                    selection: decide(
                        type_.base_name(),
                        keys,
                        *is_abstract,
                        possible_types,
                        &children,
                    ),
                },
            }
        }
        _ => unreachable!("occurrences are fields"),
    }
}

/// The disjunction of conjunctions, simplified: a conjunction that holds
/// always makes the whole always (empty), a contradictory one is dropped,
/// and repeats go. When every conjunction is contradictory the field is
/// selected by no variables, and one contradiction stays, which none pass;
/// dropping them all would read as always.
pub fn any(conjunctions: Vec<Vec<Guard>>) -> Vec<Vec<Guard>> {
    let mut alternatives: Vec<Vec<Guard>> = Vec::new();
    let mut contradiction: Option<Vec<Guard>> = None;
    for mut conjunction in conjunctions {
        conjunction.sort();
        conjunction.dedup();
        let contradictory = conjunction
            .windows(2)
            .any(|pair| pair[0].variable == pair[1].variable);
        if contradictory {
            contradiction.get_or_insert(conjunction);
            continue;
        }
        if conjunction.is_empty() {
            return Vec::new();
        }
        if !alternatives.contains(&conjunction) {
            alternatives.push(conjunction);
        }
    }
    match contradiction {
        Some(contradiction) if alternatives.is_empty() => vec![contradiction],
        _ => alternatives,
    }
}

fn response_key(selection: &SelectionPlan) -> String {
    match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            alias.clone().unwrap_or_else(|| name.clone())
        }
        _ => unreachable!("occurrences are fields"),
    }
}

/// Where the document wrote a field's response key or a selection's alias,
/// and what changing it takes; none for a selection Relay generated.
fn written_key(selection: &SelectionPlan) -> Option<Written> {
    let (origin, remedy) = match selection {
        SelectionPlan::Scalar { alias, origin, .. }
        | SelectionPlan::Linked { alias, origin, .. } => {
            let remedy = match alias {
                Some(_) => "choose another alias",
                None => "alias the field",
            };
            (origin, remedy)
        }
        SelectionPlan::Inline { origin, .. } => (origin, "choose another alias"),
        _ => return None,
    };
    Some(Written {
        origin: origin.clone()?,
        remedy,
    })
}

fn is_type_membership(selection: &SelectionPlan) -> bool {
    matches!(selection, SelectionPlan::Scalar { name, alias: Some(alias), .. }
        if name == "__typename" && alias.starts_with("__is"))
}

fn caught(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { caught, .. } | SelectionPlan::Linked { caught, .. } => *caught,
        _ => false,
    }
}

fn is_client(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { client, .. } | SelectionPlan::Linked { client, .. } => *client,
        _ => false,
    }
}

fn is_transient(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { transient, .. } | SelectionPlan::Linked { transient, .. } => {
            *transient
        }
        _ => false,
    }
}

fn is_extension(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { extension, .. } | SelectionPlan::Linked { extension, .. } => {
            *extension
        }
        _ => false,
    }
}

fn edit(selection: &SelectionPlan) -> Option<EditPlan> {
    match selection {
        SelectionPlan::Scalar { edit, .. } | SelectionPlan::Linked { edit, .. } => edit.clone(),
        _ => None,
    }
}

#[cfg(test)]
#[path = "tests/decide_tests.rs"]
mod tests;
