//! The one pass that collects what the shared file declares from the
//! decided program: the types its code names, the type sets, the slots with
//! and without variables, the abstract slots and the argument sites; and the
//! check that the module and the shared enums declare each name once.

use std::collections::{BTreeMap, BTreeSet};

use super::keys::SlotRef;
use super::reader::{
    AliasGuard, ErrorCheck, ErrorLine, Read, ReaderPlan, SatisfiedCheck, SlotAccess, SpreadGuard,
    TypeTest,
};
use super::{NormalizationKind, NormalizationSelection, Program};
use crate::names::{Kind, NameError, Reserved, Scope, Written};
use crate::pipeline::{OperationKind, Plan};

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
    /// Keys read on object types, and keys with variables.
    pub slots: BTreeSet<SlotRef>,
    /// Constant keys read on an interface or union.
    pub abstract_slots: BTreeSet<SlotRef>,
    /// The identifiers of the spreads with arguments.
    pub sites: BTreeSet<String>,
}

impl Shared {
    /// What the lenses, plans and builders of `program` use.
    pub(super) fn collect(plan: &Plan, program: &Program) -> Shared {
        let mut shared = Shared {
            schema_digest: plan.schema_digest.clone(),
            root_names: plan.root_names.clone(),
            ..Shared::default()
        };
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
                    SatisfiedCheck::HasValue { slot, .. } | SatisfiedCheck::Linked { slot, .. },
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
                            | ErrorLine::Required { slot, .. } => self.slot(slot),
                            ErrorLine::Nested(_) => {}
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
                            self.possible_sets
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
    /// twice: the documents' types beside the shared enums and the runtime's
    /// module, which the generated code names, and in the enums the types,
    /// sets, slots and sites the lenses use.
    pub(super) fn duplicates(&self, plan: &Plan) -> Vec<NameError> {
        let none = Reserved::none();
        let mut module = Scope::new("the module", &none);
        module.declare("Baton", Kind::Type, "the runtime's module `Baton`");
        module.declare("Types", Kind::Type, "the shared enum `Types`");
        module.declare("Slots", Kind::Type, "the shared enum `Slots`");
        if !self.sites.is_empty() {
            module.declare("Sites", Kind::Type, "the shared enum `Sites`");
        }
        if !self.abstract_slots.is_empty() {
            module.declare(
                "AbstractSlots",
                Kind::Type,
                "the shared enum `AbstractSlots`",
            );
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
        let mut types = Scope::new("Types", &none);
        types.declare("schemaDigest", Kind::Static, "the schema's digest");
        for type_name in &self.types {
            types.declare(type_name, Kind::Static, format!("the type `{type_name}`"));
        }
        for condition in self.possible_sets.keys() {
            types.declare(
                &format!("{condition}_possible"),
                Kind::Static,
                format!("the types that satisfy `{condition}`"),
            );
        }
        let mut sites = Scope::new("Sites", &none);
        for site in &self.sites {
            sites.declare(site, Kind::Static, format!("the site `{site}`"));
        }
        let mut duplicates = module.finish();
        duplicates.extend(types.finish());
        duplicates.extend(sites.finish());
        for (family, slots) in [
            ("Slots", &self.slots),
            ("AbstractSlots", &self.abstract_slots),
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
                    let member = slot.member();
                    scope.declare(
                        member.trim_matches('`'),
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
