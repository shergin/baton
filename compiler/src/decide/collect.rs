//! The one pass that collects what the shared file declares from the
//! decided program: the types its code names, the type sets, the slots with
//! and without variables, the abstract slots and the argument sites; and the
//! check that the module and the shared enums declare each name once.

use std::collections::{BTreeMap, BTreeSet};

use super::keys::SlotRef;
use super::lens::{
    AliasGuard, ErrorCheck, ErrorLine, Primitive, Read, ReaderPlan, SatisfiedCheck, ScalarShape,
    SlotAccess, SpreadGuard, TypeTest,
};
use super::{Guard, NormalizationKind, NormalizationSelection, Program};
use crate::naming::{Kind, NameError, Naming, Reserved, Scope, Spelled, Written};
use crate::pipeline::{OperationKind, Plan, TypePlan};

/// A field of an input object as its struct declares it: the schema's
/// field, and what its base reads as when it is a scalar.
#[derive(Debug, Clone, PartialEq)]
pub struct InputField {
    pub name: String,
    pub type_: TypePlan,
    /// The field's type contains the input itself outside a list, so the
    /// struct boxes the field.
    pub indirect: bool,
    /// What the base reads as, for a scalar or an enum.
    pub primitive: Primitive,
}

/// What the shared file declares.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Shared {
    pub schema_digest: String,
    /// Every type the module's code names.
    pub types: BTreeSet<String>,
    /// The schema's root types the store knows by another name, which they
    /// are interned by.
    pub root_names: BTreeMap<String, String>,
    /// The possible types of each abstract type tested as a set.
    pub possible_sets: BTreeMap<String, Vec<String>>,
    /// The members of each abstract type that one value keys, which a lookup
    /// without a type probes: its own set, since a type test on the same
    /// type names every member.
    pub keyed_sets: BTreeMap<String, Vec<String>>,
    /// Keys read on object types, and keys with variables.
    pub slots: BTreeSet<SlotRef>,
    /// Constant keys read on an interface or union.
    pub abstract_slots: BTreeSet<SlotRef>,
    /// The identifiers of the spreads with arguments.
    pub sites: BTreeSet<String>,
    /// The conditions `@include` and `@skip` put on selections, which an
    /// owner settles once each.
    pub guards: BTreeSet<Guard>,
    /// The schema's enums the documents read or pass, with their values,
    /// each declared as an enum of the target's.
    pub enums: BTreeMap<String, Vec<String>>,
    /// The schema's input objects the documents' variables name, with their
    /// fields, each declared as a struct of the target's.
    pub inputs: BTreeMap<String, Vec<InputField>>,
    /// The slots of the schema extensions' fields, which the registry marks
    /// as the client's: a lens reads one as absent, not missing, until a
    /// payload writes it.
    pub client_slots: BTreeSet<SlotRef>,
    /// The object types whose records never reach the image.
    pub transient_types: BTreeSet<String>,
    /// The root fields whose cells, keys and operations never reach the
    /// image, by the root type's name and the field's.
    pub transient_fields: BTreeSet<(String, String)>,
}

impl Shared {
    /// What the lenses, plans and builders of `program` use.
    pub(super) fn collect(plan: &Plan, program: &Program, naming: &dyn Naming) -> Shared {
        let mut shared = Shared {
            schema_digest: plan.schema_digest.clone(),
            root_names: plan.root_names.clone(),
            enums: plan.enums.clone(),
            inputs: plan
                .inputs
                .iter()
                .map(|(name, fields)| {
                    let fields = fields
                        .iter()
                        .map(|field| InputField {
                            name: field.name.clone(),
                            type_: field.type_.clone(),
                            indirect: field.indirect,
                            primitive: ScalarShape::primitive(&field.type_, naming),
                        })
                        .collect();
                    (name.clone(), fields)
                })
                .collect(),
            transient_types: plan.transient_types.clone(),
            ..Shared::default()
        };
        for name in &plan.transient_types {
            shared.types.insert(name.clone());
        }
        for fragment in &program.fragments {
            shared.lens(&fragment.lens);
        }
        for operation in &program.operations {
            shared.selection(&operation.normalization);
            shared.lens(&operation.data);
        }
        shared
    }

    fn lens(&mut self, lens: &ReaderPlan) {
        self.types.insert(lens.type_name.clone());
        if let Some(identity) = lens
            .refetch
            .as_ref()
            .and_then(|refetch| refetch.identity.as_ref())
        {
            self.slot(identity);
        }
        self.guards.extend(lens.own_guards().into_iter().cloned());
        for accessor in &lens.accessors {
            match &accessor.read {
                Read::Scalar(read) => self.slot(&read.slot),
                Read::Linked(read) => {
                    self.slot(&read.slot);
                    self.types.insert(read.base_type.clone());
                }
                Read::Spread(read) => {
                    if let Some(binding) = &read.binding {
                        self.sites.insert(binding.site.clone());
                    }
                    for guard in &read.guards {
                        if let SpreadGuard::Test(test) = guard {
                            self.test(test);
                        }
                    }
                }
                Read::Aliased(read) => {
                    for guard in &read.guards {
                        if let AliasGuard::Test(test) = guard {
                            self.test(test);
                        }
                    }
                }
                Read::Condition(read) => self.test(&read.test),
            }
        }
        if let Some(connection) = &lens.connection {
            self.types.insert(connection.edge_type.clone());
            self.types.insert(connection.page_info_type.clone());
        }
        for entry in lens.satisfied.iter().flatten() {
            match &entry.item {
                Some(
                    SatisfiedCheck::HasValue { slot, .. }
                    | SatisfiedCheck::Converts { slot, .. }
                    | SatisfiedCheck::Linked { slot, .. },
                ) => self.slot(slot),
                None => {}
            }
        }
        for check in lens.field_errors.iter().flatten() {
            match check {
                ErrorCheck::Condition { test, .. } => self.test(test),
                ErrorCheck::Member(lines) => {
                    for line in &lines.item {
                        match line {
                            ErrorLine::Field(slot)
                            | ErrorLine::Linked { slot, .. }
                            | ErrorLine::List { slot, .. }
                            | ErrorLine::Required { slot, .. }
                            | ErrorLine::Converts { slot, .. } => self.slot(slot),
                            ErrorLine::Nested(_) => {}
                            ErrorLine::Spread(read) => {
                                if let Some(binding) = &read.binding {
                                    self.sites.insert(binding.site.clone());
                                }
                                for guard in &read.guards {
                                    if let SpreadGuard::Test(test) = guard {
                                        self.test(test);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        for presence in lens.is_present.iter().flatten() {
            self.slot(&presence.item);
        }
        for child in &lens.nested {
            self.lens(child);
        }
    }

    fn slot(&mut self, access: &SlotAccess) {
        self.types.insert(access.slot.type_name.clone());
        if access.on_record_type && !access.slot.has_variables() {
            self.abstract_slots.insert(access.slot.clone());
        } else {
            self.slots.insert(access.slot.clone());
        }
    }

    fn test(&mut self, test: &TypeTest) {
        match test {
            TypeTest::Is(type_name) => {
                self.types.insert(type_name.clone());
            }
            TypeTest::InSet { condition, types } => {
                self.types.insert(condition.clone());
                self.types.extend(types.iter().cloned());
                self.possible_sets.insert(condition.clone(), types.clone());
            }
        }
    }

    fn selection(&mut self, selection: &NormalizationSelection) {
        self.types.insert(selection.type_name.clone());
        for variant in &selection.variants {
            self.types.extend(variant.types.iter().flatten().cloned());
            let slot_type = variant.slot_type(selection);
            for field in &variant.fields {
                self.slots.insert(SlotRef::new(slot_type, &field.key));
                if field.extension {
                    self.client_slots
                        .insert(SlotRef::new(slot_type, &field.key));
                }
                if field.transient {
                    self.transient_fields
                        .insert((slot_type.to_string(), field.key.name.clone()));
                }
                for conjunction in &field.guards {
                    self.guards.extend(conjunction.iter().cloned());
                }
                if let Some(edge_type) = field
                    .edit
                    .as_ref()
                    .and_then(|edit| edit.edge_type_name.as_ref())
                {
                    self.types.insert(edge_type.clone());
                }
                let NormalizationKind::Linked {
                    lookup,
                    connection,
                    selection: child,
                    ..
                } = &field.kind
                else {
                    continue;
                };
                if let Some(lookup) = lookup {
                    match &lookup.type_name {
                        Some(type_name) => {
                            self.types.insert(type_name.clone());
                        }
                        None => {
                            self.types.extend(lookup.possible_types.iter().cloned());
                            self.keyed_sets
                                .insert(child.type_name.clone(), lookup.possible_types.clone());
                        }
                    }
                }
                if let Some(connection) = connection {
                    self.slots
                        .insert(SlotRef::new(slot_type, &connection.storage_key));
                    self.types.insert(connection.edge_type.clone());
                    self.types.insert(connection.page_info_type.clone());
                }
                self.selection(child);
            }
        }
    }

    /// The names the module's top level and the shared enums would declare
    /// twice: the documents' types beside the shared enums, the runtime's
    /// module and what the generated code spells from the language itself,
    /// and in the enums the types, sets, slots and sites the lenses use.
    pub(super) fn duplicates(&self, plan: &Plan, naming: &dyn Naming) -> Vec<NameError> {
        let none = Reserved::none(naming);
        let mut module = Scope::new("the module", &none);
        for (name, what) in naming.module_names() {
            module.declare(name, Kind::Type, what);
        }
        module.declare_spelled(naming, Spelled::Runtime);
        module.declare_spelled(naming, Spelled::Types);
        module.declare_spelled(naming, Spelled::Slots);
        if !self.sites.is_empty() {
            module.declare_spelled(naming, Spelled::Sites);
        }
        if !self.guards.is_empty() {
            module.declare_spelled(naming, Spelled::Guards);
        }
        for name in self.enums.keys() {
            module.declare(
                &naming.enum_type(name),
                Kind::Type,
                format!("the schema's enum `{name}`"),
            );
        }
        for name in self.inputs.keys() {
            module.declare(
                &naming.input_type(name),
                Kind::Type,
                format!("the schema's input object `{name}`"),
            );
        }
        if !self.abstract_slots.is_empty() {
            module.declare_spelled(naming, Spelled::AbstractSlots);
        }
        for fragment in &plan.fragments {
            module.declare_written(
                &fragment.name,
                Kind::Type,
                format!("the fragment `{}`", fragment.name),
                fragment.origin.clone().map(|origin| Written {
                    origin,
                    remedy: "rename the fragment",
                }),
            );
        }
        // A refetch query is named by its fragment's `@refetchable`, and
        // its name's origin is the fragment's.
        let refetch_queries: BTreeSet<&str> = plan
            .fragments
            .iter()
            .filter_map(|fragment| Some(fragment.refetch.as_ref()?.operation.as_str()))
            .collect();
        for operation in &plan.operations {
            let (what, remedy) = if refetch_queries.contains(operation.name.as_str()) {
                (
                    format!("the refetch query `{}`", operation.name),
                    "name it otherwise in `@refetchable(queryName:)`",
                )
            } else {
                (
                    format!("the {} `{}`", operation.kind, operation.name),
                    rename(operation.kind),
                )
            };
            module.declare_written(
                &operation.name,
                Kind::Type,
                what,
                operation
                    .origin
                    .clone()
                    .map(|origin| Written { origin, remedy }),
            );
        }
        let mut types = Scope::new(naming.spelling(Spelled::Types), &none);
        types.declare("schemaDigest", Kind::Static, "the schema's digest");
        types.declare("format", Kind::Static, "the format of the generated code");
        if !self.transient_types.is_empty() || !self.transient_fields.is_empty() {
            types.declare("transient", Kind::Static, "what never reaches the image");
        }
        for type_name in &self.types {
            types.declare(
                &naming.type_constant(type_name),
                Kind::Static,
                format!("the type `{type_name}`"),
            );
        }
        for condition in self.keyed_sets.keys() {
            types.declare(
                &naming.keyed_types(condition),
                Kind::Static,
                format!("the types that satisfy `{condition}` that one value keys"),
            );
        }
        for condition in self.possible_sets.keys() {
            types.declare(
                &naming.possible_types(condition),
                Kind::Static,
                format!("the types that satisfy `{condition}`"),
            );
        }
        let mut sites = Scope::new(naming.spelling(Spelled::Sites), &none);
        for site in &self.sites {
            sites.declare(site, Kind::Static, format!("the site `{site}`"));
        }
        let mut duplicates = module.finish();
        duplicates.extend(types.finish());
        duplicates.extend(sites.finish());
        for (family, slots) in [
            (naming.spelling(Spelled::Slots), &self.slots),
            (
                naming.spelling(Spelled::AbstractSlots),
                &self.abstract_slots,
            ),
        ] {
            let mut enclosing = Scope::new(family, &none);
            let mut by_type: BTreeMap<&str, Vec<&SlotRef>> = BTreeMap::new();
            for slot in slots {
                by_type.entry(&slot.type_name).or_default().push(slot);
            }
            for (type_name, slots) in by_type {
                enclosing.declare(type_name, Kind::Type, format!("the slots of `{type_name}`"));
                let mut scope = Scope::new(format!("{family}.{type_name}"), &none);
                for slot in slots {
                    scope.declare(
                        &slot.member(&|name| naming.slot_name(name)),
                        Kind::Static,
                        format!("the slot `{}`", slot.template),
                    );
                }
                duplicates.extend(scope.finish());
            }
            duplicates.extend(enclosing.finish());
        }
        duplicates
    }
}

/// What renaming an operation of `kind` takes.
fn rename(kind: OperationKind) -> &'static str {
    match kind {
        OperationKind::Query => "rename the query",
        OperationKind::Mutation => "rename the mutation",
        OperationKind::Subscription => "rename the subscription",
    }
}
