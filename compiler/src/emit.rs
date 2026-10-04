//! The Swift emitter: lens types, operation values, plan tables, mutation
//! actions with their optimistic builders, connection lenses with their
//! pagination, the error and nullability surface (`@required`, `@catch`,
//! `@throwOnFieldError`, `@semanticNonNull`, `@defer`), and the shared file
//! of interned types and slots. Everything here reads the plan IR only.
//!
//! Output per host file `X.swift` is `X.baton.swift`; the per-target
//! `Baton.baton.swift` carries `Types` and `Slots`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

use crate::decide::{self, Guard, NormalizationField, NormalizationKind, NormalizationSelection};
use crate::names::{
    DuplicateName, Kind, Reserved, Scope, capitalize, escape, lower_camel, slot_name,
};
use crate::pipeline::{
    ArgumentValuePlan, CatchPlan, ConditionClass, ConnectionPlan, ConstantPlan, FragmentPlan,
    HandlePlan, LookupPlan, OperationPlan, Plan, RefetchPlan, RequiredPlan, SelectionPlan,
    StorageKeyPlan, TypeKind, VariablePlan,
};

/// Generated Swift, grouped by the source file that declared the documents.
pub struct Output {
    pub files: BTreeMap<String, String>,
    pub shared: String,
}

/// A part of a storage key as the runtime builds it: text, or an operation
/// variable rendered as JSON.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum KeyPart {
    Literal(String),
    Variable(String),
}

/// A slot the generated code refers to: a parent type and a storage key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct SlotRef {
    type_name: String,
    /// The key with `$name` in place of each variable: what names the slot
    /// in this module.
    template: String,
    field: String,
    has_arguments: bool,
    parts: Vec<KeyPart>,
}

impl SlotRef {
    fn new(type_name: &str, key: &StorageKeyPlan) -> SlotRef {
        let parts = key_parts(key);
        SlotRef {
            type_name: type_name.to_string(),
            template: template(&parts),
            field: key.name.clone(),
            has_arguments: !key.arguments.is_empty(),
            parts,
        }
    }

    fn has_variables(&self) -> bool {
        self.parts
            .iter()
            .any(|part| matches!(part, KeyPart::Variable(_)))
    }

    /// The slot's name among its type's: `name`, or `characters_1a2b3c` when
    /// the key has arguments. Slots are nested per type, so a type's name
    /// and a field's never run together into another pair's.
    fn member(&self) -> String {
        if !self.has_arguments {
            return slot_name(&self.field);
        }
        let digest = format!("{:x}", md5::compute(self.template.as_bytes()));
        format!("{}_{}", self.field, &digest[..6])
    }

    /// The constant's path in one of the shared enums: `Slots.Character.name`.
    fn path(&self, family: &str) -> String {
        format!("{family}.{}.{}", slot_name(&self.type_name), self.member())
    }

    /// The Swift expression that yields the slot.
    fn expression(&self) -> String {
        if self.has_variables() {
            format!("anchor.owner.slot({})", self.path("Slots"))
        } else {
            self.path("Slots")
        }
    }

    /// The parts of a key with variables, as `Baton.KeyPart` literals.
    fn parts_literal(&self) -> String {
        let parts: Vec<String> = self
            .parts
            .iter()
            .map(|part| match part {
                KeyPart::Literal(text) => format!(".literal({})", swift_literal(text)),
                KeyPart::Variable(name) => format!(".variable({})", swift_literal(name)),
            })
            .collect();
        format!("[{}]", parts.join(", "))
    }
}

/// What a spread accessor needs to know about the fragment it produces.
#[derive(Clone, Copy, Default)]
struct FragmentFlags {
    bubbles: bool,
    throws: bool,
}

/// A fragment's type condition: on an interface or union, the concrete
/// types that satisfy it.
#[derive(Clone, Default)]
struct FragmentCondition {
    is_abstract: bool,
    possible_types: Vec<String>,
}

struct Emitter {
    slots: BTreeSet<SlotRef>,
    /// Constant keys read on an interface or union.
    abstract_slots: BTreeSet<SlotRef>,
    /// The identifiers of the spreads with arguments.
    sites: BTreeSet<String>,
    types: BTreeSet<String>,
    /// Every fragment's `@argumentDefinitions`, for binding spreads.
    fragment_arguments: BTreeMap<String, Vec<VariablePlan>>,
    fragment_flags: BTreeMap<String, FragmentFlags>,
    fragment_conditions: BTreeMap<String, FragmentCondition>,
    /// Fragments spread with `@defer` somewhere: their lenses get `isPresent`.
    deferred_fragments: BTreeSet<String>,
    /// Fragments spread alone under `@catch` somewhere: their lenses get
    /// `fieldErrors`, which the catch reads.
    caught_fragments: BTreeSet<String>,
    /// The possible types of each abstract type condition tested as a set.
    possible_sets: BTreeMap<String, Vec<String>>,
    /// The schema's root types the store knows by another name.
    root_names: BTreeMap<String, String>,
    schema_digest: String,
    /// What a nested lens may not be named: the names a lens spells, and
    /// the program's fragments and operations.
    lens_names: Reserved,
    /// What a nested optimistic-response builder may not be named.
    builder_names: Reserved,
    /// Names some scope would have declared twice.
    duplicates: Vec<DuplicateName>,
}

/// What the lenses of one document share: the fragment's `@refetchable` data
/// (reached from a nested connection lens through the fragment's name), and
/// the error policy the types follow.
#[derive(Clone, Copy)]
struct Context<'a> {
    owner: &'a str,
    /// The lens as Swift names it from the file's top level, for messages.
    path: &'a str,
    refetch: Option<&'a RefetchPlan>,
    arguments: &'a [VariablePlan],
    /// `@throwOnFieldError` on the document.
    throws: bool,
    /// Inside a `@catch` field or aliased inline fragment.
    within_catch: bool,
    /// In a fragment a `@catch` spreads: its lenses scan for field errors
    /// for the catch to read, while their types keep the fragment's own
    /// policy, as the fragment is one type wherever it is spread.
    caught_spread: bool,
}

impl Context<'_> {
    /// Semantic non-null types apply, and lenses scan for field errors.
    fn handles_errors(&self) -> bool {
        self.throws || self.within_catch
    }

    /// Lenses scan for field errors: under an error policy, or for a catch.
    fn scans_errors(&self) -> bool {
        self.handles_errors() || self.caught_spread
    }
}

/// A nested lens type still to be written: name, GraphQL type, abstractness,
/// selections, the connection it reads when the field is one, whether its
/// required children can null it, and whether it sits inside a `@catch`.
struct Nested {
    name: String,
    type_name: String,
    is_abstract: bool,
    selections: Vec<SelectionPlan>,
    connection: Option<ConnectionPlan>,
    bubbles: bool,
    within_catch: bool,
}

/// The Swift of a plan, or the names it would have declared twice.
pub fn emit(plan: &Plan) -> Result<Output, Vec<DuplicateName>> {
    let mut deferred_fragments = BTreeSet::new();
    let mut caught_fragments = BTreeSet::new();
    for fragment in &plan.fragments {
        collect_deferred(&fragment.reader, &mut deferred_fragments);
        collect_caught(&fragment.reader, &mut caught_fragments);
    }
    for operation in &plan.operations {
        collect_deferred(&operation.reader, &mut deferred_fragments);
        collect_caught(&operation.reader, &mut caught_fragments);
    }
    let mut emitter = Emitter {
        slots: BTreeSet::new(),
        abstract_slots: BTreeSet::new(),
        sites: BTreeSet::new(),
        types: BTreeSet::new(),
        fragment_arguments: plan
            .fragments
            .iter()
            .map(|fragment| (fragment.name.clone(), fragment.arguments.clone()))
            .collect(),
        fragment_flags: plan
            .fragments
            .iter()
            .map(|fragment| {
                (
                    fragment.name.clone(),
                    FragmentFlags {
                        bubbles: fragment.bubbles,
                        throws: fragment.throws_on_field_error,
                    },
                )
            })
            .collect(),
        fragment_conditions: plan
            .fragments
            .iter()
            .map(|fragment| {
                (
                    fragment.name.clone(),
                    FragmentCondition {
                        is_abstract: fragment.type_is_abstract,
                        possible_types: fragment.possible_types.clone(),
                    },
                )
            })
            .collect(),
        deferred_fragments,
        caught_fragments,
        possible_sets: BTreeMap::new(),
        root_names: plan.root_names.clone(),
        schema_digest: plan.schema_digest.clone(),
        lens_names: Reserved::lenses(
            plan.fragments
                .iter()
                .map(|fragment| fragment.name.as_str())
                .chain(
                    plan.operations
                        .iter()
                        .map(|operation| operation.name.as_str()),
                ),
        ),
        builder_names: Reserved::builders(),
        duplicates: Vec::new(),
    };
    let mut files: BTreeMap<String, String> = BTreeMap::new();
    for fragment in &plan.fragments {
        let text = emitter.fragment(fragment);
        files
            .entry(fragment.source.clone())
            .or_default()
            .push_str(&text);
    }
    for operation in &plan.operations {
        let text = emitter.operation(operation);
        files
            .entry(operation.source.clone())
            .or_default()
            .push_str(&text);
    }
    for text in files.values_mut() {
        *text = format!("{HEADER}\n{text}");
    }
    let shared = emitter.shared();
    emitter.module(plan);
    if !emitter.duplicates.is_empty() {
        return Err(emitter.duplicates);
    }
    Ok(Output { shared, files })
}

const HEADER: &str = "// Generated by batonc. Do not edit.\nimport Baton\n";

/// The fragments spread under `@defer`, anywhere in a selection tree.
fn collect_deferred(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Inline {
                deferred,
                selections: child,
                ..
            } => {
                if deferred.is_some() {
                    for inner in child {
                        if let SelectionPlan::Spread { fragment, .. } = inner {
                            into.insert(fragment.clone());
                        }
                    }
                }
                collect_deferred(child, into);
            }
            SelectionPlan::Linked {
                selections: child, ..
            }
            | SelectionPlan::Condition {
                selections: child, ..
            } => collect_deferred(child, into),
            _ => {}
        }
    }
}

/// The fragments spread alone under an aliased or deferred `@catch`,
/// anywhere in a selection tree: the spread's accessor reads their field
/// errors.
fn collect_caught(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Inline {
                alias,
                deferred,
                catch,
                selections: child,
                ..
            } => {
                if let (Some(_), [SelectionPlan::Spread { fragment, .. }]) =
                    (catch, child.as_slice())
                    && (alias.is_some() || deferred.is_some())
                {
                    into.insert(fragment.clone());
                }
                collect_caught(child, into);
            }
            SelectionPlan::Linked {
                selections: child, ..
            }
            | SelectionPlan::Condition {
                selections: child, ..
            } => collect_caught(child, into),
            _ => {}
        }
    }
}

impl Emitter {
    fn shared(&self) -> String {
        let mut output = String::new();
        output.push_str(HEADER);
        output.push('\n');
        output
            .push_str("/// Interned schema types used by this module's documents.\nnonisolated enum Types {\n");
        let _ = writeln!(
            output,
            "    /// The schema's digest: pass it as the image's `version`, so an image\n    /// written under another schema starts again.\n    static let schemaDigest = \"{}\"",
            self.schema_digest
        );
        for type_name in &self.types {
            // A root type is interned by the name the store's root record
            // has, so its slots are numbered where the root's values are.
            let interned = self.root_names.get(type_name).unwrap_or(type_name);
            let _ = writeln!(
                output,
                "    static let {type_name} = Baton.Registry.type(\"{interned}\")"
            );
        }
        // Inside `Types` the members are named bare: a schema type named
        // `Types` is a member that hides the enum's own name.
        for (condition, types) in &self.possible_sets {
            let members: Vec<&str> = types.iter().map(String::as_str).collect();
            let _ = writeln!(
                output,
                "    /// The types that satisfy `... on {condition}`.\n    static let {condition}_possible: Set<Baton.TypeID> = [{}]",
                members.join(", ")
            );
        }
        output.push_str(
            "}\n\n/// Interned storage keys used by this module's documents.\nnonisolated enum Slots {\n",
        );
        let mut current: Option<&str> = None;
        for slot in &self.slots {
            if current != Some(slot.type_name.as_str()) {
                if current.is_some() {
                    output.push_str("    }\n");
                }
                let _ = writeln!(
                    output,
                    "    nonisolated enum {} {{",
                    slot_name(&slot.type_name)
                );
                current = Some(&slot.type_name);
            }
            if slot.has_variables() {
                let _ = writeln!(
                    output,
                    "        static let {} = Baton.DynamicKey(Types.{}, {})",
                    slot.member(),
                    slot.type_name,
                    slot.parts_literal()
                );
            } else {
                let _ = writeln!(
                    output,
                    "        static let {} = Baton.Registry.slot(Types.{}, {})",
                    slot.member(),
                    slot.type_name,
                    swift_literal(&slot.template)
                );
            }
        }
        if current.is_some() {
            output.push_str("    }\n");
        }
        output.push_str("}\n");
        if !self.sites.is_empty() {
            output.push_str(
                "\n/// The spreads with `@arguments`, where an owner binds a fragment's scope once.\nnonisolated enum Sites {\n",
            );
            for site in &self.sites {
                let _ = writeln!(output, "    static let {site} = Baton.ArgumentSite()");
            }
            output.push_str("}\n");
        }
        if !self.abstract_slots.is_empty() {
            output.push_str(
                "\n/// Storage keys read on interfaces and unions, each resolved once per concrete type.\nnonisolated enum AbstractSlots {\n",
            );
            let mut current: Option<&str> = None;
            for slot in &self.abstract_slots {
                if current != Some(slot.type_name.as_str()) {
                    if current.is_some() {
                        output.push_str("    }\n");
                    }
                    let _ = writeln!(
                        output,
                        "    nonisolated enum {} {{",
                        slot_name(&slot.type_name)
                    );
                    current = Some(&slot.type_name);
                }
                let _ = writeln!(
                    output,
                    "        static let {} = Baton.AbstractSlot({})",
                    slot.member(),
                    swift_literal(&slot.template)
                );
            }
            output.push_str("    }\n}\n");
        }
        output
    }

    /// Checks that the file's top level and the shared enums declare each
    /// name once: the documents' types beside the shared enums, and in
    /// those the types, sets, slots and sites the lenses used.
    fn module(&mut self, plan: &Plan) {
        let none = Reserved::none();
        let mut module = Scope::new("the module", &none);
        module.declare("Types", Kind::Type, "the shared enum of types");
        module.declare("Slots", Kind::Type, "the shared enum of slots");
        if !self.sites.is_empty() {
            module.declare("Sites", Kind::Type, "the shared enum of argument sites");
        }
        if !self.abstract_slots.is_empty() {
            module.declare(
                "AbstractSlots",
                Kind::Type,
                "the shared enum of abstract slots",
            );
        }
        for fragment in &plan.fragments {
            module.declare(
                &fragment.name,
                Kind::Type,
                format!("the fragment `{}`", fragment.name),
            );
        }
        for operation in &plan.operations {
            module.declare(
                &operation.name,
                Kind::Type,
                format!("the {} `{}`", operation.kind, operation.name),
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
        self.duplicates.extend(duplicates);
    }

    fn fragment(&mut self, fragment: &FragmentPlan) -> String {
        let mut output = String::new();
        let _ = writeln!(
            output,
            "/// Lens for `fragment {} on {}`.",
            fragment.name, fragment.type_condition
        );
        let context = Context {
            owner: &fragment.name,
            path: &fragment.name,
            refetch: fragment.refetch.as_ref(),
            arguments: &fragment.arguments,
            throws: fragment.throws_on_field_error,
            within_catch: false,
            caught_spread: self.caught_fragments.contains(&fragment.name),
        };
        self.lens_struct(
            &mut output,
            &fragment.name,
            &fragment.type_condition,
            fragment.type_is_abstract,
            &fragment.reader,
            "",
            context,
            None,
            true,
            fragment.bubbles,
        );
        output.push('\n');
        output
    }

    fn operation(&mut self, operation: &OperationPlan) -> String {
        let mut output = String::new();
        let _ = writeln!(
            output,
            "/// Operation value for `{} {}`.",
            operation.kind, operation.name
        );
        // Each kind is its own protocol: a query and a subscription value
        // carry the handle a view resolves them to, a mutation's is called.
        let (protocol, resolution) = match operation.kind.as_str() {
            "mutation" => ("Mutation", None),
            "subscription" => ("Subscription", Some("SubscriptionHandle")),
            _ => ("Query", Some("OperationHandle")),
        };
        let _ = writeln!(
            output,
            "nonisolated public struct {}: Baton.{protocol} {{",
            operation.name
        );
        self.operation_scope(operation, resolution.is_some());
        for variable in &operation.variables {
            let _ = writeln!(
                output,
                "    public var {}: {}",
                escape(&variable.name),
                variable_type(variable)
            );
        }
        match resolution {
            Some(handle) => {
                let _ = writeln!(
                    output,
                    "    public var resolution: Baton.{handle}<Self>? = nil\n"
                );
            }
            None => output.push('\n'),
        }
        let parameters = parameter_list(&operation.variables);
        let _ = writeln!(output, "    public init({parameters}) {{");
        for variable in &operation.variables {
            let _ = writeln!(
                output,
                "        self.{} = {}",
                escape(&variable.name),
                local_name(&variable.name, &variable_names(&operation.variables))
            );
        }
        output.push_str("    }\n\n");
        let _ = writeln!(
            output,
            "    public static let name = \"{}\"",
            operation.name
        );
        let _ = writeln!(
            output,
            "    public static let persistedID = \"{}\"",
            operation.id
        );
        if let Some(behavior) = &operation.error_behavior {
            let _ = writeln!(
                output,
                "    public static let errorBehavior: Baton.ErrorBehavior? = .{behavior}"
            );
        }
        if operation.throws_on_field_error {
            output.push_str("    public static let throwsOnFieldError = true\n");
        }
        if operation.bubbles {
            output.push_str("    public static let bubbles = true\n");
        }
        if operation.has_deferred {
            output.push_str("    public static let hasDeferred = true\n");
        }
        let _ = writeln!(
            output,
            "    public static let text = #\"\"\"\n{}\n\"\"\"#\n",
            operation.text
        );
        output.push_str("    public var variables: Baton.Variables {\n        Baton.Variables([");
        if operation.variables.is_empty() {
            output.push(':');
        } else {
            let entries: Vec<String> = operation
                .variables
                .iter()
                .map(|variable| {
                    format!(
                        "\"{}\": Baton.Variable({})",
                        variable.name,
                        stored(&variable.name)
                    )
                })
                .collect();
            output.push_str(&entries.join(", "));
        }
        output.push_str("])\n    }\n\n");
        output.push_str("    public static func == (lhs: Self, rhs: Self) -> Bool {\n");
        if operation.variables.is_empty() {
            output.push_str("        true\n");
        } else {
            let comparisons: Vec<String> = operation
                .variables
                .iter()
                .map(|variable| format!("lhs.{0} == rhs.{0}", escape(&variable.name)))
                .collect();
            let _ = writeln!(output, "        {}", comparisons.join(" && "));
        }
        output.push_str("    }\n\n    public func hash(into hasher: inout Hasher) {\n");
        for variable in &operation.variables {
            let _ = writeln!(output, "        hasher.combine({})", stored(&variable.name));
        }
        output.push_str("    }\n\n");

        // The normalization plan, as static data.
        let normalization = decide::normalization(&operation.root_type, &operation.normalization);
        output.push_str("    public static let plan = Baton.Plan(root: ");
        self.selection_plan(&mut output, &normalization, 2);
        output.push_str(")\n\n");

        // The root lens.
        let path = format!("{}.Data", operation.name);
        let context = Context {
            owner: &operation.name,
            path: &path,
            refetch: None,
            arguments: &operation.variables,
            throws: operation.throws_on_field_error,
            within_catch: false,
            caught_spread: false,
        };
        self.lens_struct(
            &mut output,
            "Data",
            &operation.root_type,
            false,
            &operation.reader,
            "    ",
            context,
            None,
            false,
            operation.bubbles,
        );

        if operation.kind == "mutation" {
            output.push('\n');
            output.push_str("    public typealias Action = Baton.MutationAction<Self>\n\n");
            let path = format!("{}.OptimisticResponse", operation.name);
            let duplicates = self.optimistic_builder(
                &mut output,
                &path,
                "OptimisticResponse",
                &normalization,
                "    ",
            );
            self.duplicates.extend(duplicates);
        }
        output.push_str("}\n\n");

        if operation.kind == "mutation" {
            let parameters = parameter_list(&operation.variables);
            let separator = if operation.variables.is_empty() {
                ""
            } else {
                ", "
            };
            let arguments: Vec<String> = operation
                .variables
                .iter()
                .map(|variable| {
                    format!(
                        "{}: {}",
                        escape(&variable.name),
                        local_name(&variable.name, &variable_names(&operation.variables))
                    )
                })
                .collect();
            let _ = writeln!(
                output,
                "extension Baton.MutationAction where Op == {name} {{\n    /// Commits the mutation; the optimistic response, if any, shows at once and rebases until the server answers.\n    @MainActor @discardableResult\n    public func callAsFunction({parameters}{separator}optimistic: {name}.OptimisticResponse? = nil) async throws -> {name}.Data {{\n        try await commit({name}({args}), optimistic: optimistic?.variable)\n    }}\n}}\n",
                name = operation.name,
                args = arguments.join(", ")
            );
        }
        output
    }

    /// Checks that an operation's value declares each name once: its
    /// variables beside what every operation value has.
    fn operation_scope(&mut self, operation: &OperationPlan, resolves: bool) {
        let none = Reserved::none();
        let mut scope = Scope::new(operation.name.as_str(), &none);
        for variable in &operation.variables {
            scope.declare(
                &variable.name,
                Kind::Instance,
                format!("the variable `${}`", variable.name),
            );
        }
        scope.declare("variables", Kind::Instance, "the operation's variables");
        if resolves {
            scope.declare("resolution", Kind::Instance, "the operation's resolution");
        }
        for name in ["name", "persistedID", "text", "plan"] {
            scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
        }
        let flags = [
            ("errorBehavior", operation.error_behavior.is_some()),
            ("throwsOnFieldError", operation.throws_on_field_error),
            ("bubbles", operation.bubbles),
            ("hasDeferred", operation.has_deferred),
        ];
        for (name, declared) in flags {
            if declared {
                scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
            }
        }
        scope.declare("Data", Kind::Type, "the operation's root lens");
        if operation.kind == "mutation" {
            scope.declare("Action", Kind::Type, "the mutation's action");
            scope.declare(
                "OptimisticResponse",
                Kind::Type,
                "the mutation's optimistic response",
            );
        }
        self.duplicates.extend(scope.finish());
    }

    /// Writes a lens struct for a selection set on `type_name`. A fragment root
    /// with `@refetchable` gets `refetch()`; a connection field's lens gets the
    /// connection state and, inside a refetchable fragment, `loadNext`; a lens
    /// whose required children can null it gets `satisfied`; a lens under an
    /// error policy gets `fieldErrors`, `throwing` and `caught`; a fragment
    /// spread with `@defer` gets `isPresent`.
    #[allow(clippy::too_many_arguments)]
    fn lens_struct(
        &mut self,
        output: &mut String,
        name: &str,
        type_name: &str,
        type_is_abstract: bool,
        selections: &[SelectionPlan],
        indent: &str,
        context: Context<'_>,
        connection: Option<&ConnectionPlan>,
        is_fragment_root: bool,
        bubbles: bool,
    ) {
        self.types.insert(type_name.to_string());
        let _ = writeln!(
            output,
            "{indent}nonisolated public struct {name}: Baton.Lens {{"
        );
        let _ = writeln!(output, "{indent}    public let anchor: Baton.Anchor");
        let _ = writeln!(
            output,
            "{indent}    public init(anchor: Baton.Anchor) {{ self.anchor = anchor }}"
        );
        let _ = writeln!(
            output,
            "{indent}    public static let typeName = \"{type_name}\""
        );
        let inner = format!("{indent}    ");
        let mut nested: Vec<Nested> = Vec::new();
        let mut members = members(selections);
        let facts = LensFacts {
            refetchable: is_fragment_root && context.refetch.is_some(),
            connection: connection.is_some(),
            nodes: connection.is_some() && selects_nodes(selections),
        };
        let duplicates = self.name_lens(context.path, facts, selections, type_name, &mut members);
        self.duplicates.extend(duplicates);
        self.accessors(
            output,
            type_name,
            type_is_abstract,
            &mut members,
            &inner,
            &mut nested,
            context,
        );
        if is_fragment_root && let Some(refetch) = context.refetch {
            self.refetch_members(output, refetch, context, &inner);
        }
        if let Some(connection) = connection {
            self.connection_members(
                output,
                connection,
                type_name,
                &members,
                facts.nodes,
                context,
                &inner,
            );
        }
        if bubbles {
            self.satisfied_function(output, type_name, type_is_abstract, &members, &inner);
        }
        if context.scans_errors() {
            self.field_errors_function(output, type_name, type_is_abstract, &members, &inner);
        }
        if is_fragment_root && self.deferred_fragments.contains(name) {
            self.is_present_function(output, type_name, type_is_abstract, &members, &inner);
        }
        for child in nested {
            output.push('\n');
            let path = format!("{}.{}", context.path, child.name);
            let child_context = Context {
                path: &path,
                within_catch: context.within_catch || child.within_catch,
                ..context
            };
            self.lens_struct(
                output,
                &child.name,
                &child.type_name,
                child.is_abstract,
                &child.selections,
                &inner,
                child_context,
                child.connection.as_ref(),
                false,
                child.bubbles,
            );
        }
        let _ = writeln!(output, "{indent}}}");
    }

    /// The `@refetchable` surface of a fragment lens: the descriptor of its
    /// query and `refetch()`.
    fn refetch_members(
        &mut self,
        output: &mut String,
        refetch: &RefetchPlan,
        context: Context<'_>,
        indent: &str,
    ) {
        let option = |value: &Option<String>| match value {
            Some(name) => swift_literal(name),
            None => "nil".to_string(),
        };
        let pagination = refetch.connection.as_ref();
        let _ = writeln!(
            output,
            "{indent}/// How the fragment is fetched again: `{}` with the lens's variables.",
            refetch.operation
        );
        let _ = writeln!(
            output,
            "{indent}public static let refetchable = Baton.Refetch(variables: [{}], identifier: {}, first: {}, after: {}, last: {}, before: {})",
            refetch
                .variables
                .iter()
                .map(|name| swift_literal(name))
                .collect::<Vec<_>>()
                .join(", "),
            option(&refetch.identifier),
            option(&pagination.and_then(|p| p.first.clone())),
            option(&pagination.and_then(|p| p.after.clone())),
            option(&pagination.and_then(|p| p.last.clone())),
            option(&pagination.and_then(|p| p.before.clone())),
        );
        let _ = writeln!(
            output,
            "{indent}/// Fetches the fragment again through `{}` with its current variables; the records update in place.",
            refetch.operation
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public func refetch() async throws {{ try await anchor.refetch({}.self, {}.refetchable) }}",
            refetch.operation, context.owner
        );
    }

    /// The connection surface of a lens over a `@connection` field: Relay's
    /// state read from the store, `nodes`, and pagination when the fragment is
    /// refetchable.
    #[allow(clippy::too_many_arguments)]
    fn connection_members(
        &mut self,
        output: &mut String,
        connection: &ConnectionPlan,
        type_name: &str,
        members: &[Member],
        nodes: bool,
        context: Context<'_>,
        indent: &str,
    ) {
        self.types.insert(connection.edge_type.clone());
        self.types.insert(connection.page_info_type.clone());
        let _ = writeln!(
            output,
            "{indent}/// The connection's slots: edges, nodes, cursors and the page info, for the store's merge and the state below."
        );
        let _ = writeln!(
            output,
            "{indent}public static let connection = Baton.ConnectionSlots(connection: Types.{type_name}, edge: Types.{}, pageInfo: Types.{})",
            connection.edge_type, connection.page_info_type
        );
        if nodes && let Some((edges, node, node_bubbles)) = self.node_lens(members, context) {
            let keep = if node_bubbles {
                format!(", keep: {edges}.{node}.satisfied")
            } else {
                String::new()
            };
            let _ = writeln!(
                output,
                "{indent}/// The edges' nodes, in order, without nulls."
            );
            let _ = writeln!(
                output,
                "{indent}@MainActor public var nodes: [{edges}.{node}] {{ anchor.nodes(Self.connection{keep}) }}"
            );
        }
        let _ = writeln!(
            output,
            "{indent}/// Whether the server has edges after the last one, from the merged `pageInfo`."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public var hasNext: Bool {{ anchor.hasNext(Self.connection) }}"
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public var hasPrevious: Bool {{ anchor.hasPrevious(Self.connection) }}"
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public var isLoadingNext: Bool {{ anchor.isLoadingNext(Self.connection) }}"
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public var isLoadingPrevious: Bool {{ anchor.isLoadingPrevious(Self.connection) }}"
        );
        let _ = writeln!(
            output,
            "{indent}/// Relay's connection id, for the `connections` argument of the edge directives."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public var connectionID: String {{ anchor.record.key }}"
        );

        let Some(refetch) = context.refetch else {
            return;
        };
        let Some(pagination) = refetch.connection.as_ref() else {
            return;
        };
        let default_count = |variable: &Option<String>| -> String {
            variable
                .as_ref()
                .and_then(|name| context.arguments.iter().find(|a| &a.name == name))
                .and_then(|definition| match &definition.default_value {
                    Some(ConstantPlan::Int(count)) => Some(format!(" = {count}")),
                    _ => None,
                })
                .unwrap_or_default()
        };
        if pagination.first.is_some() && pagination.after.is_some() {
            let _ = writeln!(
                output,
                "{indent}/// Fetches the next `count` edges through `{}` and appends them; a no-op while loading or at the end.",
                refetch.operation
            );
            let _ = writeln!(
                output,
                "{indent}@MainActor public func loadNext(_ count: Int{}) async throws {{ try await anchor.loadNext({}.self, Self.connection, {}.refetchable, count: count) }}",
                default_count(&pagination.first),
                refetch.operation,
                context.owner
            );
        }
        if pagination.last.is_some() && pagination.before.is_some() {
            let _ = writeln!(
                output,
                "{indent}/// Fetches the previous `count` edges through `{}` and prepends them; a no-op while loading or at the start.",
                refetch.operation
            );
            let _ = writeln!(
                output,
                "{indent}@MainActor public func loadPrevious(_ count: Int{}) async throws {{ try await anchor.loadPrevious({}.self, Self.connection, {}.refetchable, count: count) }}",
                default_count(&pagination.last),
                refetch.operation,
                context.owner
            );
        }
    }

    /// The lenses `nodes` reads, the edges' and the node's, as their
    /// accessors named them, and whether the node's required children can
    /// null it: when the connection selects `edges { node }` at its own
    /// level.
    fn node_lens(
        &self,
        members: &[Member],
        context: Context<'_>,
    ) -> Option<(String, String, bool)> {
        let edges = members.iter().find(|member| {
            matches!(&member.selection, SelectionPlan::Linked { name, alias: None, .. } if name == "edges")
        })?;
        let SelectionPlan::Linked {
            base_type,
            selections,
            ..
        } = &edges.selection
        else {
            unreachable!("the edges member is a linked field");
        };
        // The edges' lens names its members when it is written; naming them
        // here the same way finds the name its node takes.
        let mut edge_members = crate::emit::members(selections);
        let path = format!("{}.{}", context.path, edges.lens_name());
        let _ = self.name_lens(
            &path,
            LensFacts::default(),
            selections,
            base_type,
            &mut edge_members,
        );
        let node = edge_members.into_iter().find(|member| {
            matches!(&member.selection, SelectionPlan::Linked { name, alias: None, .. } if name == "node")
        })?;
        let SelectionPlan::Linked { bubbles, .. } = &node.selection else {
            unreachable!("the node member is a linked field");
        };
        Some((
            edges.lens_name().to_string(),
            node.lens_name().to_string(),
            *bubbles,
        ))
    }

    /// Names a lens's members, and returns the names it would declare
    /// twice. First what every lens of its kind declares, then the accessors
    /// as the document spells them, the spreads' derived accessors around
    /// those, the nested lenses of fields and aliased selections, and last
    /// each type condition's accessor and lens under one number, so a name
    /// the document chose is never the one that moves.
    fn name_lens(
        &self,
        path: &str,
        facts: LensFacts,
        selections: &[SelectionPlan],
        type_name: &str,
        members: &mut [Member],
    ) -> Vec<DuplicateName> {
        let mut scope = Scope::new(path, &self.lens_names);
        scope.declare("anchor", Kind::Instance, "the anchor every lens has");
        scope.declare(
            "recordID",
            Kind::Instance,
            "the record identity every lens has",
        );
        scope.declare("typeName", Kind::Static, "the type name every lens has");
        if facts.refetchable {
            scope.declare(
                "refetchable",
                Kind::Static,
                "the fragment's refetch descriptor",
            );
        }
        if facts.connection {
            scope.declare("connection", Kind::Static, "the connection's slots");
            if facts.nodes {
                scope.declare("nodes", Kind::Instance, "the connection's nodes");
            }
            for name in [
                "hasNext",
                "hasPrevious",
                "isLoadingNext",
                "isLoadingPrevious",
                "connectionID",
            ] {
                scope.declare(name, Kind::Instance, format!("the connection's `{name}`"));
            }
        }
        for member in members.iter_mut() {
            if let Some((name, what)) = written_accessor(&member.selection) {
                scope.declare(&name, Kind::Instance, what);
                member.accessor = Some(name);
            }
        }
        let preferred = spread_accessor_names(selections, type_name);
        for member in members.iter_mut() {
            let Some(fragment) = derived_spread(&member.selection) else {
                continue;
            };
            let full = lower_camel(fragment);
            let mut candidates = vec![preferred.get(fragment).cloned().unwrap_or(full.clone())];
            if candidates[0] != full {
                candidates.push(full);
            }
            member.accessor = Some(scope.member(
                &candidates,
                Kind::Instance,
                format!("the spread of `{fragment}`"),
            ));
        }
        for member in members.iter_mut() {
            let property = match &member.selection {
                SelectionPlan::Linked { name, alias, .. } => alias.as_deref().unwrap_or(name),
                SelectionPlan::Inline {
                    alias: Some(alias),
                    selections: child,
                    ..
                } if !matches!(child.as_slice(), [SelectionPlan::Spread { .. }]) => alias,
                _ => continue,
            };
            let lens = scope.nested_type(property, format!("the lens of `{property}`"));
            member.lens = Some(lens);
        }
        for member in members.iter_mut() {
            let SelectionPlan::Inline {
                type_condition: Some(condition),
                condition_class: Some(ConditionClass::Concrete(_) | ConditionClass::Set),
                alias: None,
                deferred,
                selections: child,
                ..
            } = &member.selection
            else {
                continue;
            };
            if deferred.is_some() && matches!(child.as_slice(), [SelectionPlan::Spread { .. }]) {
                continue;
            }
            let (accessor, lens) = scope.member_and_type(
                &format!("as{condition}"),
                &format!("As{condition}"),
                format!("the type condition `... on {condition}`"),
            );
            member.accessor = Some(accessor);
            member.lens = Some(lens);
        }
        scope.finish()
    }

    /// `satisfied`: whether every `@required` field (NONE or LOG) of the
    /// selection is present, recursing into required links. Relay nulls the
    /// enclosing object otherwise; here the parent's accessor returns nil.
    fn satisfied_function(
        &mut self,
        output: &mut String,
        type_name: &str,
        type_is_abstract: bool,
        members: &[Member],
        indent: &str,
    ) {
        let _ = writeln!(
            output,
            "{indent}/// Whether every `@required` field is present; the lens is otherwise null to its parent, as Relay bubbles."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public static func satisfied(_ anchor: Baton.Anchor) -> Bool {{"
        );
        for member in own_members(members) {
            // A field a condition left out cannot null the lens.
            let condition = guard_condition(&member.guards);
            let (indent, close) = match &condition {
                Some(condition) => {
                    let _ = writeln!(output, "{indent}    if {condition} {{");
                    (format!("{indent}    "), format!("{indent}    }}"))
                }
                None => (indent.to_string(), String::new()),
            };
            match &member.selection {
                SelectionPlan::Scalar {
                    required: Some(required),
                    storage_key,
                    ..
                } if required.action != "THROW" => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    let _ = writeln!(
                        output,
                        "{indent}    guard anchor.hasValue({slot}, path: {}, log: {}) else {{ return false }}",
                        swift_literal(&required.path),
                        required.action == "LOG"
                    );
                }
                SelectionPlan::Linked {
                    required: Some(required),
                    storage_key,
                    plural,
                    bubbles,
                    ..
                } if required.action != "THROW" => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    if *plural || !*bubbles {
                        let _ = writeln!(
                            output,
                            "{indent}    guard anchor.hasValue({slot}, path: {}, log: {}) else {{ return false }}",
                            swift_literal(&required.path),
                            required.action == "LOG"
                        );
                    } else {
                        let nested = member.lens_name();
                        let _ = writeln!(
                            output,
                            "{indent}    guard let child = anchor.linked({slot}), {nested}.satisfied(child) else {{ return anchor.requiredMissing(path: {}, log: {}) }}",
                            swift_literal(&required.path),
                            required.action == "LOG"
                        );
                    }
                }
                _ => {}
            }
            if !close.is_empty() {
                let _ = writeln!(output, "{close}");
            }
        }
        let _ = writeln!(output, "{indent}    return true");
        let _ = writeln!(output, "{indent}}}");
    }

    /// `fieldErrors`, `throwing` and `caught`: the field errors in this
    /// selection, excluding fields caught by their own `@catch`, plus the
    /// `@required(action: THROW)` fields that are null.
    fn field_errors_function(
        &mut self,
        output: &mut String,
        type_name: &str,
        type_is_abstract: bool,
        members: &[Member],
        indent: &str,
    ) {
        let _ = writeln!(
            output,
            "{indent}/// The field errors in this selection, for `@catch` and `@throwOnFieldError`."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public static func fieldErrors(_ anchor: Baton.Anchor) -> [Baton.FieldError] {{"
        );
        let _ = writeln!(output, "{indent}    var errors: [Baton.FieldError] = []");
        for member in members {
            // A type condition's nested lens: its errors count when the
            // record satisfies the condition.
            if let SelectionPlan::Inline {
                alias: None,
                type_condition,
                condition_class,
                ..
            } = &member.selection
            {
                if let Some((_, _, _, test)) =
                    self.condition_lens(type_condition, condition_class, member)
                {
                    let test = match guard_condition(&member.guards) {
                        Some(condition) => format!("{condition} && {test}"),
                        None => test,
                    };
                    let _ = writeln!(
                        output,
                        "{indent}    if {test} {{ errors.append(contentsOf: {}.fieldErrors(anchor)) }}",
                        member.lens_name()
                    );
                }
                continue;
            }
            if !collects_errors(&member.selection) {
                continue;
            }
            // A field a condition left out has no error to collect.
            let condition = guard_condition(&member.guards);
            let (indent, close) = match &condition {
                Some(condition) => {
                    let _ = writeln!(output, "{indent}    if {condition} {{");
                    (format!("{indent}    "), format!("{indent}    }}"))
                }
                None => (indent.to_string(), String::new()),
            };
            match &member.selection {
                SelectionPlan::Scalar {
                    storage_key,
                    required,
                    ..
                } => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    let _ = writeln!(
                        output,
                        "{indent}    anchor.collectError({slot}, into: &errors)"
                    );
                    if let Some(required) = required
                        && required.action == "THROW"
                    {
                        let _ = writeln!(
                            output,
                            "{indent}    anchor.collectRequired({slot}, path: {}, into: &errors)",
                            swift_literal(&required.path)
                        );
                    }
                }
                SelectionPlan::Linked {
                    storage_key,
                    required,
                    plural,
                    ..
                } => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    let nested = member.lens_name();
                    if *plural {
                        let _ = writeln!(
                            output,
                            "{indent}    anchor.collectErrors(list: {slot}, within: {nested}.fieldErrors, into: &errors)"
                        );
                    } else {
                        let _ = writeln!(
                            output,
                            "{indent}    anchor.collectErrors({slot}, within: {nested}.fieldErrors, into: &errors)"
                        );
                    }
                    if let Some(required) = required
                        && required.action == "THROW"
                    {
                        let _ = writeln!(
                            output,
                            "{indent}    anchor.collectRequired({slot}, path: {}, into: &errors)",
                            swift_literal(&required.path)
                        );
                    }
                }
                SelectionPlan::Inline { alias: Some(_), .. } => {
                    let _ = writeln!(
                        output,
                        "{indent}    errors.append(contentsOf: {}.fieldErrors(anchor))",
                        member.lens_name()
                    );
                }
                _ => {}
            }
            if !close.is_empty() {
                let _ = writeln!(output, "{close}");
            }
        }
        let _ = writeln!(output, "{indent}    return errors");
        let _ = writeln!(output, "{indent}}}");
        let _ = writeln!(
            output,
            "{indent}/// The lens, or the field errors in it as a thrown `FieldErrors`."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public static func throwing(_ anchor: Baton.Anchor) throws -> Self {{"
        );
        let _ = writeln!(output, "{indent}    let errors = fieldErrors(anchor)");
        let _ = writeln!(
            output,
            "{indent}    if !errors.isEmpty {{ throw Baton.FieldErrors(errors) }}"
        );
        let _ = writeln!(output, "{indent}    return Self(anchor: anchor)");
        let _ = writeln!(output, "{indent}}}");
        let _ = writeln!(
            output,
            "{indent}/// The lens, or the field errors in it as a `Result`."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public static func caught(_ anchor: Baton.Anchor) -> Result<Self, Baton.FieldErrors> {{"
        );
        let _ = writeln!(output, "{indent}    let errors = fieldErrors(anchor)");
        let _ = writeln!(
            output,
            "{indent}    return errors.isEmpty ? .success(Self(anchor: anchor)) : .failure(Baton.FieldErrors(errors))"
        );
        let _ = writeln!(output, "{indent}}}");
    }

    /// `isPresent`: whether the fragment's own fields have arrived, for a
    /// spread under `@defer`.
    fn is_present_function(
        &mut self,
        output: &mut String,
        type_name: &str,
        type_is_abstract: bool,
        members: &[Member],
        indent: &str,
    ) {
        let mut checks: Vec<String> = Vec::new();
        for member in own_members(members) {
            let check = match &member.selection {
                SelectionPlan::Scalar {
                    name, storage_key, ..
                } if name != "__typename" => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    format!("anchor.present({slot})")
                }
                SelectionPlan::Linked { storage_key, .. } => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    format!("anchor.present({slot})")
                }
                _ => continue,
            };
            // A field a condition left out is not waited for.
            checks.push(match guard_condition(&member.guards) {
                Some(condition) => format!("(!({condition}) || {check})"),
                None => check,
            });
        }
        let _ = writeln!(
            output,
            "{indent}/// Whether the deferred part that carries this fragment has arrived."
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public static func isPresent(_ anchor: Baton.Anchor) -> Bool {{ {} }}",
            if checks.is_empty() {
                "true".to_string()
            } else {
                checks.join(" && ")
            }
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn accessors(
        &mut self,
        output: &mut String,
        type_name: &str,
        type_is_abstract: bool,
        members: &mut [Member],
        indent: &str,
        nested: &mut Vec<Nested>,
        context: Context<'_>,
    ) {
        for member in members {
            let condition = guard_condition(&member.guards);
            let condition = condition.as_deref();
            match &member.selection {
                SelectionPlan::Scalar {
                    name,
                    base_kind,
                    non_null,
                    semantic_non_null,
                    list,
                    storage_key,
                    required,
                    catch,
                    ..
                } => {
                    if name == "__typename" {
                        continue;
                    }
                    self.scalar_accessor(
                        output,
                        ScalarAccessor {
                            property: member.accessor_name(),
                            base_kind: *base_kind,
                            list: *list,
                            non_null: *non_null
                                || required.is_some()
                                || (*semantic_non_null && context.handles_errors()),
                            required: required.as_ref(),
                            catch: catch.as_ref(),
                        },
                        type_name,
                        type_is_abstract,
                        storage_key,
                        indent,
                        condition,
                    );
                }
                SelectionPlan::Linked {
                    base_type,
                    non_null,
                    semantic_non_null,
                    plural,
                    is_abstract,
                    storage_key,
                    connection,
                    required,
                    catch,
                    bubbles,
                    selections: child,
                    ..
                } => {
                    let nested_name = member.lens_name().to_string();
                    self.types.insert(base_type.clone());
                    self.linked_accessor(
                        output,
                        LinkedAccessor {
                            property: member.accessor_name(),
                            nested: &nested_name,
                            base_type,
                            plural: *plural,
                            non_null: *non_null
                                || required.is_some()
                                || (*semantic_non_null && context.handles_errors()),
                            bubbles: *bubbles,
                            required: required.as_ref(),
                            catch: catch.as_ref(),
                        },
                        type_name,
                        type_is_abstract,
                        storage_key,
                        indent,
                        condition,
                    );
                    nested.push(Nested {
                        name: nested_name,
                        type_name: base_type.clone(),
                        is_abstract: *is_abstract,
                        selections: child.clone(),
                        connection: connection.clone(),
                        bubbles: *bubbles,
                        within_catch: catch.is_some(),
                    });
                }
                SelectionPlan::Spread {
                    fragment,
                    type_condition,
                    arguments,
                } => {
                    self.spread_accessor(
                        output,
                        SpreadAccessor {
                            owner: context.owner,
                            accessor: member.accessor_name(),
                            fragment,
                            arguments,
                            type_condition,
                            deferred: false,
                            catch: None,
                        },
                        type_name,
                        type_is_abstract,
                        indent,
                        condition,
                    );
                }
                SelectionPlan::Inline {
                    type_condition,
                    condition_class,
                    alias,
                    deferred,
                    catch,
                    bubbles,
                    selections: child,
                    ..
                } => {
                    if let [
                        SelectionPlan::Spread {
                            fragment,
                            type_condition: spread_condition,
                            arguments,
                        },
                    ] = child.as_slice()
                        && (alias.is_some() || deferred.is_some())
                    {
                        // `@alias(as:)` or `@defer` around one spread: the spread
                        // keeps its lens, under the alias when given.
                        self.spread_accessor(
                            output,
                            SpreadAccessor {
                                owner: context.owner,
                                accessor: member.accessor_name(),
                                fragment,
                                arguments,
                                type_condition: spread_condition,
                                deferred: deferred.is_some(),
                                catch: catch.as_ref(),
                            },
                            type_name,
                            type_is_abstract,
                            indent,
                            condition,
                        );
                        continue;
                    }
                    let condition_lens =
                        self.condition_lens(type_condition, condition_class, member);
                    if alias.is_some() {
                        // `@alias(as:)` on other selections: a nested lens.
                        let nested_name = member.lens_name().to_string();
                        let (lens_type, lens_abstract) = match &condition_lens {
                            Some((_, lens_type, lens_abstract, _)) => {
                                (lens_type.clone(), *lens_abstract)
                            }
                            None => (type_name.to_string(), type_is_abstract),
                        };
                        let mut guards: Vec<String> = Vec::new();
                        if let Some(condition) = condition {
                            guards.push(condition.to_string());
                        }
                        if let Some((_, _, _, test)) = &condition_lens {
                            guards.push(test.clone());
                        }
                        if *bubbles {
                            guards.push(format!("{nested_name}.satisfied(anchor)"));
                        }
                        let property = escape(member.accessor_name());
                        match catch.as_ref().map(|catch| catch.to.as_str()) {
                            Some("RESULT") if guards.is_empty() => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {property}: Result<{nested_name}, Baton.FieldErrors> {{ {nested_name}.caught(anchor) }}"
                                );
                            }
                            Some("RESULT") => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {property}: Result<{nested_name}, Baton.FieldErrors>? {{ {} ? {nested_name}.caught(anchor) : nil }}",
                                    guards.join(" && ")
                                );
                            }
                            _ if guards.is_empty() => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {property}: {nested_name} {{ {nested_name}(anchor: anchor) }}"
                                );
                            }
                            _ => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {property}: {nested_name}? {{ {} ? {nested_name}(anchor: anchor) : nil }}",
                                    guards.join(" && ")
                                );
                            }
                        }
                        nested.push(Nested {
                            name: nested_name,
                            type_name: lens_type,
                            is_abstract: lens_abstract,
                            selections: child.clone(),
                            connection: None,
                            bubbles: *bubbles,
                            within_catch: catch.is_some(),
                        });
                        continue;
                    }
                    let Some((_, lens_type, lens_abstract, test)) = condition_lens else {
                        // `members` folds every other inline fragment into the lens.
                        continue;
                    };
                    let nested_name = member.lens_name().to_string();
                    let test = match condition {
                        Some(condition) => format!("{condition} && {test}"),
                        None => test,
                    };
                    let _ = writeln!(
                        output,
                        "{indent}@MainActor public var {}: {nested_name}? {{ {test} ? {nested_name}(anchor: anchor) : nil }}",
                        escape(member.accessor_name())
                    );
                    nested.push(Nested {
                        name: nested_name,
                        type_name: lens_type,
                        is_abstract: lens_abstract,
                        selections: child.clone(),
                        connection: None,
                        bubbles: false,
                        within_catch: false,
                    });
                }
                SelectionPlan::Condition { .. } => {
                    unreachable!("members turns conditions into guards")
                }
            }
        }
    }

    /// A type condition some of the parent's types satisfy reads as an
    /// optional nested lens: on the one type that can, or through the
    /// abstract type's keys when several can. The condition's name, the
    /// lens's type and whether it is abstract, and the test of the record.
    fn condition_lens(
        &mut self,
        type_condition: &Option<String>,
        condition_class: &Option<ConditionClass>,
        member: &Member,
    ) -> Option<(String, String, bool, String)> {
        match (type_condition, condition_class) {
            (Some(condition), Some(ConditionClass::Concrete(concrete))) => {
                self.types.insert(concrete.clone());
                Some((
                    condition.clone(),
                    concrete.clone(),
                    false,
                    format!("anchor.record.is(Types.{concrete})"),
                ))
            }
            (Some(condition), Some(ConditionClass::Set)) => {
                let set = self.possible_set(condition, member);
                Some((
                    condition.clone(),
                    condition.clone(),
                    true,
                    format!("Types.{set}.contains(anchor.record.type)"),
                ))
            }
            _ => None,
        }
    }

    /// The lookup: the entity type, or for a field that returns an interface
    /// or union the set of its possible types, and the argument's value, a
    /// variable or a constant written as a record key writes it: a string as
    /// itself, anything else as JSON.
    fn lookup_expression(&mut self, lookup: &LookupPlan, base_type: &str) -> String {
        let types = match &lookup.type_name {
            Some(type_name) => {
                self.types.insert(type_name.clone());
                format!("type: Types.{type_name}")
            }
            None => {
                for type_name in &lookup.possible_types {
                    self.types.insert(type_name.clone());
                }
                self.possible_sets
                    .insert(base_type.to_string(), lookup.possible_types.clone());
                format!("type: nil, possibleTypes: Types.{base_type}_possible")
            }
        };
        let key = match &lookup.value {
            ArgumentValuePlan::Variable(name) => format!(".variable({})", swift_literal(name)),
            ArgumentValuePlan::Constant(ConstantPlan::String(text)) => {
                format!(".literal({})", swift_literal(text))
            }
            ArgumentValuePlan::Constant(constant) => {
                format!(".literal({})", swift_literal(&constant_json(constant)))
            }
            ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_) => {
                unreachable!("lowering rejects a lookup argument that is a list or an object")
            }
        };
        format!("Baton.Lookup({types}, key: {key})")
    }

    /// The name of the shared type set of a condition's possible types,
    /// emitted once in the shared file.
    fn possible_set(&mut self, condition: &str, member: &Member) -> String {
        let SelectionPlan::Inline {
            condition_types: Some(types),
            ..
        } = &member.selection
        else {
            unreachable!("a set condition has its possible types");
        };
        for type_name in types {
            self.types.insert(type_name.clone());
        }
        self.possible_sets
            .insert(condition.to_string(), types.clone());
        format!("{condition}_possible")
    }

    /// A scalar accessor: plain, `@required`, `@catch` or throwing.
    #[allow(clippy::too_many_arguments)]
    fn scalar_accessor(
        &mut self,
        output: &mut String,
        field: ScalarAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
        indent: &str,
        condition: Option<&str>,
    ) {
        let argument = self.slot_expression(type_name, type_is_abstract, storage_key);
        let property = escape(field.property);
        let (reader, swift_type) = scalar_reader(field.base_kind, field.list);
        let required_reader = format!("required{}", capitalize(reader));
        match (
            field.catch.map(|catch| catch.to.as_str()),
            field.required.map(|required| required.action.as_str()),
        ) {
            (Some("RESULT"), _) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                let (value_type, read) = if field.non_null {
                    (
                        swift_type.clone(),
                        format!("$0.{required_reader}({argument})"),
                    )
                } else {
                    (format!("{swift_type}?"), format!("$0.{reader}({argument})"))
                };
                write_accessor(
                    output,
                    indent,
                    &property,
                    format!("Result<{value_type}, Baton.FieldErrors>"),
                    format!("anchor.caught({slot}) {{ {read} }}"),
                    false,
                    condition,
                );
            }
            (Some("NULL"), _) => {
                write_accessor(
                    output,
                    indent,
                    &property,
                    format!("{swift_type}?"),
                    format!("anchor.{reader}({argument})"),
                    false,
                    condition,
                );
            }
            (_, Some("THROW")) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                let path =
                    swift_literal(&field.required.map(|r| r.path.clone()).unwrap_or_default());
                write_accessor(
                    output,
                    indent,
                    &property,
                    swift_type.clone(),
                    format!(
                        "try anchor.throwing({slot}, path: {path}) {{ $0.{reader}({argument}) }}"
                    ),
                    true,
                    condition,
                );
            }
            _ if field.non_null => {
                write_accessor(
                    output,
                    indent,
                    &property,
                    swift_type.clone(),
                    format!("anchor.{required_reader}({argument})"),
                    false,
                    condition,
                );
            }
            _ => {
                write_accessor(
                    output,
                    indent,
                    &property,
                    format!("{swift_type}?"),
                    format!("anchor.{reader}({argument})"),
                    false,
                    condition,
                );
            }
        }
    }

    /// A linked accessor: plain, bubbling, `@required`, `@catch` or throwing,
    /// singular or plural.
    #[allow(clippy::too_many_arguments)]
    fn linked_accessor(
        &mut self,
        output: &mut String,
        field: LinkedAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
        indent: &str,
        condition: Option<&str>,
    ) {
        let argument = self.slot_expression(type_name, type_is_abstract, storage_key);
        let property = escape(field.property);
        let nested = field.nested;
        let base_type = field.base_type;
        let keep = if field.bubbles {
            format!(", keep: {nested}.satisfied")
        } else {
            String::new()
        };
        let catch_to = field.catch.map(|catch| catch.to.as_str());
        let required_action = field.required.map(|required| required.action.as_str());
        let path = swift_literal(&field.required.map(|r| r.path.clone()).unwrap_or_default());
        if field.plural {
            match (catch_to, required_action) {
                (Some("RESULT"), _) => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    if field.non_null {
                        write_accessor(
                            output,
                            indent,
                            &property,
                            format!("Result<Baton.List<{nested}>, Baton.FieldErrors>"),
                            format!(
                                "anchor.caughtRequiredList({slot}, within: {nested}.fieldErrors{keep})"
                            ),
                            false,
                            condition,
                        );
                    } else {
                        write_accessor(
                            output,
                            indent,
                            &property,
                            format!("Result<Baton.List<{nested}>?, Baton.FieldErrors>"),
                            format!(
                                "anchor.caughtList({slot}, within: {nested}.fieldErrors{keep})"
                            ),
                            false,
                            condition,
                        );
                    }
                }
                (_, Some("THROW")) => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    write_accessor(
                        output,
                        indent,
                        &property,
                        format!("Baton.List<{nested}>"),
                        format!("try anchor.throwingList({slot}, path: {path}{keep})"),
                        true,
                        condition,
                    );
                }
                _ if field.non_null && catch_to != Some("NULL") => {
                    write_accessor(
                        output,
                        indent,
                        &property,
                        format!("Baton.List<{nested}>"),
                        format!("anchor.requiredList({argument}{keep})"),
                        false,
                        condition,
                    );
                }
                _ => {
                    write_accessor(
                        output,
                        indent,
                        &property,
                        format!("Baton.List<{nested}>?"),
                        format!("anchor.list({argument}{keep})"),
                        false,
                        condition,
                    );
                }
            }
            return;
        }
        // A link whose children can bubble reads as optional unless it is
        // itself required, when its parent has checked it.
        let optional = !field.non_null
            || (field.bubbles && field.required.is_none())
            || catch_to == Some("NULL");
        let guarded = if field.bubbles {
            format!(".flatMap {{ {nested}.satisfied($0) ? {nested}(anchor: $0) : nil }}")
        } else {
            format!(".map({nested}.init(anchor:))")
        };
        match (catch_to, required_action) {
            (Some("RESULT"), _) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                let (value_type, read) = if optional {
                    (
                        format!("{nested}?"),
                        format!("$0.linked({argument}){guarded}"),
                    )
                } else {
                    (
                        nested.to_string(),
                        format!(
                            "{nested}(anchor: $0.requiredLinked({argument}, type: Types.{base_type}))"
                        ),
                    )
                };
                write_accessor(
                    output,
                    indent,
                    &property,
                    format!("Result<{value_type}, Baton.FieldErrors>"),
                    format!("anchor.caught({slot}, within: {nested}.fieldErrors) {{ {read} }}"),
                    false,
                    condition,
                );
            }
            (_, Some("THROW")) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                write_accessor(
                    output,
                    indent,
                    &property,
                    nested.to_string(),
                    format!(
                        "{nested}(anchor: try anchor.throwingLinked({slot}, path: {path}, satisfied: {nested}.satisfied))"
                    ),
                    true,
                    condition,
                );
            }
            _ if optional => {
                write_accessor(
                    output,
                    indent,
                    &property,
                    format!("{nested}?"),
                    format!("anchor.linked({argument}){guarded}"),
                    false,
                    condition,
                );
            }
            _ => {
                write_accessor(
                    output,
                    indent,
                    &property,
                    nested.to_string(),
                    format!(
                        "{nested}(anchor: anchor.requiredLinked({argument}, type: Types.{base_type}))"
                    ),
                    false,
                    condition,
                );
            }
        }
    }

    /// A spread's accessor. The child's scope is the parent's variables with
    /// the fragment's `@argumentDefinitions` bound: the passed argument, else
    /// the default, else null. The accessor is optional when the type may not
    /// match, the spread is deferred, or the fragment's required fields can
    /// null it; it throws when the fragment has `@throwOnFieldError`; it is a
    /// `Result` of the fragment's field errors under `@catch`, and nil when
    /// the fragment has any under `@catch(to: NULL)`.
    #[allow(clippy::too_many_arguments)]
    fn spread_accessor(
        &mut self,
        output: &mut String,
        spread: SpreadAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        indent: &str,
        condition: Option<&str>,
    ) {
        let fragment = spread.fragment;
        let flags = self
            .fragment_flags
            .get(fragment)
            .copied()
            .unwrap_or_default();
        let definitions = self
            .fragment_arguments
            .get(fragment)
            .cloned()
            .unwrap_or_default();
        let bound = if definitions.is_empty() {
            None
        } else {
            let bindings: Vec<String> = definitions
                .iter()
                .map(|definition| {
                    let value = spread
                        .arguments
                        .iter()
                        .find(|argument| argument.name == definition.name)
                        .map(|argument| argument_expression(&argument.value))
                        .or_else(|| definition.default_value.as_ref().map(variable_literal))
                        .unwrap_or_else(|| ".null".to_string());
                    format!("{}: {value}", swift_literal(&definition.name))
                })
                .collect();
            let site = self.site(spread.owner, spread.accessor);
            Some(format!(
                "anchor.binding(Sites.{site}) {{ [{}] }}",
                bindings.join(", ")
            ))
        };
        let conditional = type_is_abstract && spread.type_condition != type_name;
        if conditional {
            self.types.insert(spread.type_condition.to_string());
        }
        let anchor = if bound.is_some() { "bound" } else { "anchor" };
        let mut guards: Vec<String> = Vec::new();
        if let Some(condition) = condition {
            guards.push(condition.to_string());
        }
        if conditional {
            // A condition on an interface or union holds for any of the
            // types that satisfy it; one on an object type for that type.
            let condition = self
                .fragment_conditions
                .get(fragment)
                .cloned()
                .unwrap_or_default();
            if condition.is_abstract {
                for type_name in &condition.possible_types {
                    self.types.insert(type_name.clone());
                }
                self.possible_sets.insert(
                    spread.type_condition.to_string(),
                    condition.possible_types.clone(),
                );
                guards.push(format!(
                    "Types.{}_possible.contains(anchor.record.type)",
                    spread.type_condition
                ));
            } else {
                guards.push(format!("anchor.record.is(Types.{})", spread.type_condition));
            }
        }
        if spread.deferred {
            guards.push(format!("{fragment}.isPresent({anchor})"));
        }
        if flags.bubbles {
            guards.push(format!("{fragment}.satisfied({anchor})"));
        }
        let catch_to = spread.catch.map(|catch| catch.to.as_str());
        let catches = catch_to == Some("RESULT");
        // `to: NULL` reads a fragment with field errors as nil, and then
        // never throws them.
        let nulls = catch_to == Some("NULL");
        if nulls {
            guards.push(format!("{fragment}.fieldErrors({anchor}).isEmpty"));
        }
        let throws = flags.throws && !nulls;
        let accessor = escape(spread.accessor);
        let optional = !guards.is_empty();
        let (result_type, effect) = match (catches, throws) {
            (true, _) if optional => (format!("Result<{fragment}?, Baton.FieldErrors>"), ""),
            (true, _) => (format!("Result<{fragment}, Baton.FieldErrors>"), ""),
            (false, true) if optional => (format!("{fragment}?"), " get throws"),
            (false, true) => (fragment.to_string(), " get throws"),
            (false, false) if optional => (format!("{fragment}?"), ""),
            (false, false) => (fragment.to_string(), ""),
        };
        // A catch reads the errors through what every lens has,
        // `fieldErrors` and `init(anchor:)`: only a fragment with an error
        // policy of its own has `caught`.
        let make = if catches {
            None
        } else if throws {
            Some(format!("try {fragment}.throwing({anchor})"))
        } else {
            Some(format!("{fragment}(anchor: {anchor})"))
        };
        let miss = if catches { ".success(nil)" } else { "nil" };
        if let Some(make) = &make
            && bound.is_none()
            && guards.is_empty()
        {
            if effect.is_empty() {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {accessor}: {result_type} {{ {make} }}"
                );
            } else {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {accessor}: {result_type} {{ get throws {{ {make} }} }}"
                );
            }
            return;
        }
        let _ = writeln!(
            output,
            "{indent}@MainActor public var {accessor}: {result_type} {{"
        );
        let body_indent = if effect.is_empty() {
            format!("{indent}    ")
        } else {
            let _ = writeln!(output, "{indent}    get throws {{");
            format!("{indent}        ")
        };
        if let Some(bound) = &bound {
            let _ = writeln!(output, "{body_indent}let bound = {bound}");
        }
        if !guards.is_empty() {
            let _ = writeln!(
                output,
                "{body_indent}guard {} else {{ return {miss} }}",
                guards.join(", ")
            );
        }
        match &make {
            Some(make) => {
                let _ = writeln!(output, "{body_indent}return {make}");
            }
            None => {
                let _ = writeln!(
                    output,
                    "{body_indent}let errors = {fragment}.fieldErrors({anchor})"
                );
                let _ = writeln!(
                    output,
                    "{body_indent}return errors.isEmpty ? .success({fragment}(anchor: {anchor})) : .failure(Baton.FieldErrors(errors))"
                );
            }
        }
        if !effect.is_empty() {
            let _ = writeln!(output, "{indent}    }}");
        }
        let _ = writeln!(output, "{indent}}}");
    }

    /// A slot as a value: the static slot, or on an interface or union the
    /// abstract slot taken on the record's type. A key with variables is
    /// resolved by the anchor's owner, once.
    fn slot_expression(
        &mut self,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
    ) -> String {
        if !type_is_abstract {
            return self.slot(type_name, storage_key);
        }
        self.types.insert(type_name.to_string());
        let slot = SlotRef::new(type_name, storage_key);
        if slot.has_variables() {
            let expression = format!(
                "anchor.owner.slot({}, on: anchor.record.type)",
                slot.path("Slots")
            );
            self.slots.insert(slot);
            return expression;
        }
        let expression = format!("{}.on(anchor.record.type)", slot.path("AbstractSlots"));
        self.abstract_slots.insert(slot);
        expression
    }

    /// Writes a `Baton.Selection(...)` expression for the normalization plan:
    /// its fields when every type reads the same, else its variants.
    fn selection_plan(
        &mut self,
        output: &mut String,
        selection: &NormalizationSelection,
        depth: usize,
    ) {
        let type_name = &selection.type_name;
        self.types.insert(type_name.clone());
        let pad = "    ".repeat(depth);
        let _ = write!(
            output,
            "Baton.Selection(type: Types.{type_name}, hasID: {}, abstract: {}",
            selection.has_id, selection.is_abstract
        );
        if let [only] = selection.variants.as_slice()
            && only.types.is_none()
        {
            output.push_str(", fields: [");
            self.plan_fields(output, type_name, &only.fields, depth);
            output.push_str("])");
            return;
        }
        output.push_str(", variants: [");
        for variant in &selection.variants {
            let types = match &variant.types {
                Some(types) => {
                    let names: Vec<String> = types
                        .iter()
                        .map(|name| {
                            self.types.insert(name.clone());
                            format!("Types.{name}")
                        })
                        .collect();
                    format!("[{}]", names.join(", "))
                }
                None => "nil".to_string(),
            };
            // A variant of one type names that type's slots, which the
            // runtime then takes as they are.
            let slot_type = match variant.types.as_deref() {
                Some([only]) => only.clone(),
                _ => type_name.clone(),
            };
            let _ = write!(output, "\n{pad}    .init(types: {types}, fields: [");
            self.plan_fields(output, &slot_type, &variant.fields, depth + 1);
            output.push_str("]),");
        }
        let _ = write!(output, "\n{pad}])");
    }

    /// The fields of one variant, their slots on `type_name`.
    fn plan_fields(
        &mut self,
        output: &mut String,
        type_name: &str,
        fields: &[NormalizationField],
        depth: usize,
    ) {
        let pad = "    ".repeat(depth);
        for field in fields {
            let _ = write!(output, "\n{pad}    ");
            let slot = self.plan_key(type_name, &field.key);
            let handle_argument = field
                .handle
                .as_ref()
                .map(|handle| format!(", handle: {}", self.handle_expression(handle)))
                .unwrap_or_default();
            let deferred_argument = field
                .deferred
                .as_ref()
                .map(|label| format!(", deferred: {}", swift_literal(label)))
                .unwrap_or_default();
            let caught_argument = if field.caught { ", caught: true" } else { "" };
            let guards_argument = guards_expression(&field.guards);
            match &field.kind {
                NormalizationKind::Scalar { base_kind, list } => {
                    let kind = match base_kind {
                        TypeKind::Int => "int",
                        TypeKind::Float => "double",
                        TypeKind::Boolean => "bool",
                        TypeKind::String | TypeKind::Id | TypeKind::Enum => "string",
                        _ => "custom",
                    };
                    let _ = write!(
                        output,
                        ".scalar({}, key: {slot}, kind: .{kind}, list: {list}{handle_argument}{deferred_argument}{caught_argument}{guards_argument}),",
                        swift_literal(&field.response_key)
                    );
                }
                NormalizationKind::Linked {
                    plural,
                    lookup,
                    connection,
                    selection,
                } => {
                    let lookup_argument = match lookup {
                        Some(lookup) => format!(
                            ", lookup: {}",
                            self.lookup_expression(lookup, &selection.type_name)
                        ),
                        None => String::new(),
                    };
                    let connection_argument = connection
                        .as_ref()
                        .map(|connection| {
                            format!(
                                ", connection: {}",
                                self.connection_expression(
                                    type_name,
                                    &selection.type_name,
                                    connection
                                )
                            )
                        })
                        .unwrap_or_default();
                    let _ = write!(
                        output,
                        ".linked({}, key: {slot}, plural: {plural}{lookup_argument}{connection_argument}{handle_argument}{deferred_argument}{caught_argument}{guards_argument}, selection: ",
                        swift_literal(&field.response_key)
                    );
                    self.selection_plan(output, selection, depth + 1);
                    output.push_str("),");
                }
            }
        }
        if !fields.is_empty() {
            let _ = write!(output, "\n{pad}");
        }
    }

    /// The plan's description of a connection: the client key on the parent
    /// type, the slots of the connection, edge and page info types, and the
    /// cursor arguments that pick the merge mode.
    fn connection_expression(
        &mut self,
        parent_type: &str,
        connection_type: &str,
        connection: &ConnectionPlan,
    ) -> String {
        let key = self.plan_key(parent_type, &connection.storage_key);
        self.types.insert(connection.edge_type.clone());
        self.types.insert(connection.page_info_type.clone());
        let cursor = |value: &Option<ArgumentValuePlan>, label: &str| match value {
            Some(ArgumentValuePlan::Variable(name)) => {
                format!(", {label}: .variable({})", swift_literal(name))
            }
            Some(_) => format!(", {label}: .literal"),
            None => String::new(),
        };
        format!(
            "Baton.ConnectionPlan(key: {key}, slots: Baton.ConnectionSlots(connection: Types.{connection_type}, edge: Types.{}, pageInfo: Types.{}){}{})",
            connection.edge_type,
            connection.page_info_type,
            cursor(&connection.after, "after"),
            cursor(&connection.before, "before")
        )
    }

    /// The plan's description of an edge directive.
    fn handle_expression(&mut self, handle: &HandlePlan) -> String {
        let connections = match &handle.connections {
            Some(ArgumentValuePlan::Variable(name)) => {
                format!(", connections: .variable({})", swift_literal(name))
            }
            Some(ArgumentValuePlan::Constant(ConstantPlan::List(items))) => format!(
                ", connections: .literal([{}])",
                items
                    .iter()
                    .map(|item| match item {
                        ConstantPlan::String(text) => swift_literal(text),
                        other => swift_literal(&constant_text(other)),
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            Some(ArgumentValuePlan::Constant(other)) => {
                format!(
                    ", connections: .literal([{}])",
                    swift_literal(&constant_text(other))
                )
            }
            Some(ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)) => {
                unreachable!("lowering rejects connections given as a list with variables")
            }
            None => String::new(),
        };
        let edge_type = match &handle.edge_type_name {
            Some(name) => {
                self.types.insert(name.clone());
                format!(", edgeType: Types.{name}")
            }
            None => String::new(),
        };
        format!(
            "Baton.Handle(kind: .{}{connections}{edge_type})",
            handle.kind
        )
    }

    /// Writes the optimistic-response builder tree for a mutation: one struct
    /// per selection set, every field optional, rendering to JSON. Returns
    /// the names a builder would declare twice.
    fn optimistic_builder(
        &self,
        output: &mut String,
        path: &str,
        name: &str,
        selection: &NormalizationSelection,
        indent: &str,
    ) -> Vec<DuplicateName> {
        let _ = writeln!(
            output,
            "{indent}/// A partial response to show before the server answers; absent fields leave the store untouched."
        );
        let _ = writeln!(
            output,
            "{indent}nonisolated public struct {name}: Sendable {{"
        );
        let inner = format!("{indent}    ");
        // Every field any variant reads, once: the response is written for
        // whichever type it names.
        let mut seen = BTreeSet::new();
        let fields: Vec<&NormalizationField> = selection
            .variants
            .iter()
            .flat_map(|variant| &variant.fields)
            .filter(|field| seen.insert(field.response_key.clone()))
            .collect();
        let mut scope = Scope::new(path, &self.builder_names);
        scope.declare("variable", Kind::Instance, "the builder's rendering");
        for field in &fields {
            scope.declare(
                &field.response_key,
                Kind::Instance,
                format!("the field `{}`", field.response_key),
            );
        }
        let keys: Vec<&str> = fields
            .iter()
            .map(|field| field.response_key.as_str())
            .collect();
        let mut nested: Vec<(String, NormalizationSelection)> = Vec::new();
        let mut parameters: Vec<String> = Vec::new();
        let mut assignments: Vec<String> = Vec::new();
        let mut renders: Vec<String> = Vec::new();
        for field in fields {
            let property = field.response_key.clone();
            let local = local_name(&property, &keys);
            // A field of a plain name binds its value by its own name; `self`
            // binds it by another, which needs the property spelled.
            let bind = if local == escape(&property) {
                local.clone()
            } else {
                format!("{local} = self.{}", escape(&property))
            };
            match &field.kind {
                NormalizationKind::Scalar { base_kind, list } => {
                    let (_, swift_type) = scalar_reader(*base_kind, *list);
                    let _ = writeln!(
                        output,
                        "{inner}public var {}: {swift_type}?",
                        escape(&property)
                    );
                    parameters.push(format!(
                        "{}: {swift_type}? = nil",
                        parameter(&property, &local)
                    ));
                    assignments.push(format!("self.{} = {local}", escape(&property)));
                    renders.push(format!(
                        "if let {bind} {{ fields[\"{property}\"] = Baton.Variable({local}) }}"
                    ));
                }
                NormalizationKind::Linked {
                    plural,
                    selection: child,
                    ..
                } => {
                    let nested_name =
                        scope.nested_type(&property, format!("the builder of `{property}`"));
                    let swift_type = if *plural {
                        format!("[{nested_name}]")
                    } else {
                        nested_name.clone()
                    };
                    let _ = writeln!(
                        output,
                        "{inner}public var {}: {swift_type}?",
                        escape(&property)
                    );
                    parameters.push(format!(
                        "{}: {swift_type}? = nil",
                        parameter(&property, &local)
                    ));
                    assignments.push(format!("self.{} = {local}", escape(&property)));
                    if *plural {
                        renders.push(format!(
                            "if let {bind} {{ fields[\"{property}\"] = .list({local}.map(\\.variable)) }}"
                        ));
                    } else {
                        renders.push(format!(
                            "if let {bind} {{ fields[\"{property}\"] = {local}.variable }}"
                        ));
                    }
                    nested.push((nested_name, child.clone()));
                }
            }
        }
        let _ = writeln!(output, "{inner}public init({}) {{", parameters.join(", "));
        for assignment in &assignments {
            let _ = writeln!(output, "{inner}    {assignment}");
        }
        let _ = writeln!(output, "{inner}}}");
        let _ = writeln!(output, "{inner}public var variable: Baton.Variable {{");
        let _ = writeln!(
            output,
            "{inner}    var fields: [String: Baton.Variable] = [:]"
        );
        for render in &renders {
            let _ = writeln!(output, "{inner}    {render}");
        }
        let _ = writeln!(output, "{inner}    return .object(fields)");
        let _ = writeln!(output, "{inner}}}");
        let mut duplicates = scope.finish();
        for (nested_name, child) in nested {
            output.push('\n');
            let child_path = format!("{path}.{nested_name}");
            duplicates.extend(self.optimistic_builder(
                output,
                &child_path,
                &nested_name,
                &child,
                &inner,
            ));
        }
        let _ = writeln!(output, "{indent}}}");
        duplicates
    }

    fn slot(&mut self, type_name: &str, storage_key: &StorageKeyPlan) -> String {
        let slot = SlotRef::new(type_name, storage_key);
        let expression = slot.expression();
        self.slots.insert(slot);
        self.types.insert(type_name.to_string());
        expression
    }

    /// A new site for a spread with arguments, named by its lens's document
    /// and accessor, and numbered when the document has two of the name.
    fn site(&mut self, owner: &str, accessor: &str) -> String {
        let base = format!("{owner}_{accessor}");
        let mut name = base.clone();
        let mut count = 1;
        while self.sites.contains(&name) {
            count += 1;
            name = format!("{base}_{count}");
        }
        self.sites.insert(name.clone());
        name
    }

    /// The key expression inside a plan: a fixed slot, or the key with
    /// variables an owner renders.
    fn plan_key(&mut self, type_name: &str, storage_key: &StorageKeyPlan) -> String {
        let slot = SlotRef::new(type_name, storage_key);
        let expression = if slot.has_variables() {
            format!(".dynamic({})", slot.path("Slots"))
        } else {
            format!(".fixed({})", slot.path("Slots"))
        };
        self.slots.insert(slot);
        expression
    }
}

/// Writes an accessor: `property` of `swift_type`, reading `body`. Under a
/// guard the accessor is optional and returns nil without a read when the
/// guard fails, so a field a condition left out reports nothing missing.
#[allow(clippy::too_many_arguments)]
fn write_accessor(
    output: &mut String,
    indent: &str,
    property: &str,
    swift_type: String,
    body: String,
    throws: bool,
    condition: Option<&str>,
) {
    let Some(condition) = condition else {
        if throws {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: {swift_type} {{ get throws {{ {body} }} }}"
            );
        } else {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: {swift_type} {{ {body} }}"
            );
        }
        return;
    };
    let optional = if swift_type.ends_with('?') {
        swift_type
    } else {
        format!("{swift_type}?")
    };
    if throws {
        let _ = writeln!(
            output,
            "{indent}@MainActor public var {property}: {optional} {{ get throws {{ guard {condition} else {{ return nil }}; return {body} }} }}"
        );
    } else {
        let _ = writeln!(
            output,
            "{indent}@MainActor public var {property}: {optional} {{ {condition} ? {body} : nil }}"
        );
    }
}

/// What a scalar accessor is made of.
struct ScalarAccessor<'a> {
    property: &'a str,
    base_kind: TypeKind,
    list: bool,
    /// Effective: the schema's, `@required`, or semantic under an error policy.
    non_null: bool,
    required: Option<&'a RequiredPlan>,
    catch: Option<&'a CatchPlan>,
}

/// What a linked accessor is made of.
struct LinkedAccessor<'a> {
    property: &'a str,
    nested: &'a str,
    base_type: &'a str,
    plural: bool,
    non_null: bool,
    bubbles: bool,
    required: Option<&'a RequiredPlan>,
    catch: Option<&'a CatchPlan>,
}

/// What a spread accessor is made of.
struct SpreadAccessor<'a> {
    /// The fragment or operation whose lens holds the spread.
    owner: &'a str,
    accessor: &'a str,
    fragment: &'a str,
    arguments: &'a [crate::pipeline::ArgumentPlan],
    type_condition: &'a str,
    deferred: bool,
    catch: Option<&'a CatchPlan>,
}

/// What a lens declares besides its members' accessors and lenses.
#[derive(Clone, Copy, Default)]
struct LensFacts {
    /// A `@refetchable` fragment's root: `refetchable`.
    refetchable: bool,
    /// A connection's lens: `connection` and the pagination state.
    connection: bool,
    /// A connection's lens that selects `edges { node }`: `nodes`.
    nodes: bool,
}

/// The accessor a member's document spells, and what it is, for messages: a
/// field's response key, or an inline fragment's alias.
fn written_accessor(selection: &SelectionPlan) -> Option<(String, String)> {
    match selection {
        SelectionPlan::Scalar { name, .. } if name == "__typename" => None,
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            let key = alias.as_deref().unwrap_or(name);
            Some((key.to_string(), format!("the field `{key}`")))
        }
        SelectionPlan::Inline {
            alias: Some(alias), ..
        } => Some((alias.clone(), format!("the selection aliased `{alias}`"))),
        _ => None,
    }
}

/// The fragment of a spread whose accessor the compiler names: a spread, or
/// one deferred without an alias.
fn derived_spread(selection: &SelectionPlan) -> Option<&str> {
    match selection {
        SelectionPlan::Spread { fragment, .. } => Some(fragment),
        SelectionPlan::Inline {
            alias: None,
            deferred: Some(_),
            selections,
            ..
        } => match selections.as_slice() {
            [SelectionPlan::Spread { fragment, .. }] => Some(fragment),
            _ => None,
        },
        _ => None,
    }
}

/// One thing a lens reads, after its occurrences merged: a field, a spread
/// or an inline fragment, and the `@include` and `@skip` conditions it is
/// fetched under (empty: always).
struct Member {
    /// The first occurrence; a linked field's or an inline fragment's
    /// selections are those of every occurrence.
    selection: SelectionPlan,
    guards: Vec<Vec<Guard>>,
    /// The accessor's name, unescaped, set by `name_lens` for every member
    /// that has one.
    accessor: Option<String>,
    /// The nested lens a linked field, an aliased inline fragment or a type
    /// condition reads as, set by `name_lens`: the accessors and the checks
    /// that follow take it rather than deriving it again.
    lens: Option<String>,
}

impl Member {
    fn accessor_name(&self) -> &str {
        self.accessor
            .as_deref()
            .expect("`name_lens` names the accessor of every member that has one")
    }

    fn lens_name(&self) -> &str {
        self.lens
            .as_deref()
            .expect("`name_lens` names the nested lens of every member that has one")
    }
}

/// A selection at a lens's own level and the conditions on the way to it.
type Occurrence = (SelectionPlan, Vec<Guard>);

/// What a lens over `selections` reads, each thing once: conditions become
/// guards, an inline fragment every type satisfies folds into the lens, and
/// a field per response key, a spread per fragment and an inline fragment
/// per type condition merge their occurrences. A merged field's children
/// keep the conditions of the occurrence that selected them, when the
/// occurrences' conditions differ.
fn members(selections: &[SelectionPlan]) -> Vec<Member> {
    let mut occurrences: Vec<Occurrence> = Vec::new();
    gather(selections, &[], &mut occurrences);
    let mut groups: Vec<(Option<String>, Vec<Occurrence>)> = Vec::new();
    for (selection, guard) in occurrences {
        let identity = member_identity(&selection);
        match groups
            .iter_mut()
            .find(|(existing, _)| identity.is_some() && *existing == identity)
        {
            Some((_, members)) => members.push((selection, guard)),
            None => groups.push((identity, vec![(selection, guard)])),
        }
    }
    groups
        .into_iter()
        .map(|(_, occurrences)| {
            let guards = decide::any(occurrences.iter().map(|(_, guard)| guard.clone()).collect());
            let differ = occurrences
                .iter()
                .any(|(_, guard)| *guard != occurrences[0].1);
            let mut selection = occurrences[0].0.clone();
            if let SelectionPlan::Linked { selections, .. }
            | SelectionPlan::Inline { selections, .. } = &mut selection
            {
                *selections = occurrences
                    .iter()
                    .flat_map(|(occurrence, guard)| {
                        let children = match occurrence {
                            SelectionPlan::Linked { selections, .. }
                            | SelectionPlan::Inline { selections, .. } => selections.clone(),
                            _ => Vec::new(),
                        };
                        if differ {
                            under(guard, children)
                        } else {
                            children
                        }
                    })
                    .collect();
            }
            Member {
                selection,
                guards,
                accessor: None,
                lens: None,
            }
        })
        .collect()
}

/// The selections at a lens's own level, each with the conditions on the
/// way to it: through conditions, and through inline fragments that fold
/// into the lens.
fn gather(
    selections: &[SelectionPlan],
    guard: &[Guard],
    into: &mut Vec<(SelectionPlan, Vec<Guard>)>,
) {
    for selection in selections {
        match selection {
            SelectionPlan::Condition {
                variable,
                passing,
                selections: child,
            } => {
                let mut inner = guard.to_vec();
                if let Some(variable) = variable {
                    inner.push(Guard {
                        variable: variable.clone(),
                        passing: *passing,
                    });
                }
                gather(child, &inner, into);
            }
            SelectionPlan::Inline {
                condition_class,
                alias: None,
                deferred,
                selections: child,
                ..
            } if !(deferred.is_some()
                && matches!(child.as_slice(), [SelectionPlan::Spread { .. }]))
                && matches!(condition_class, None | Some(ConditionClass::Always)) =>
            {
                gather(child, guard, into)
            }
            other => into.push((other.clone(), guard.to_vec())),
        }
    }
}

/// What makes two occurrences one member; `None` for one that stays apart.
fn member_identity(selection: &SelectionPlan) -> Option<String> {
    match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            Some(format!("field {}", alias.as_deref().unwrap_or(name)))
        }
        SelectionPlan::Spread { fragment, .. } => Some(format!("spread {fragment}")),
        SelectionPlan::Inline {
            type_condition: Some(condition),
            alias: None,
            deferred: None,
            ..
        } => Some(format!("on {condition}")),
        _ => None,
    }
}

/// `selections` under a conjunction of conditions, as nested conditions.
fn under(guard: &[Guard], selections: Vec<SelectionPlan>) -> Vec<SelectionPlan> {
    guard
        .iter()
        .rev()
        .fold(selections, |selections, condition| {
            vec![SelectionPlan::Condition {
                variable: Some(condition.variable.clone()),
                passing: condition.passing,
                selections,
            }]
        })
}

/// Whether a member has field errors its lens collects. `__typename` has
/// none, a `@catch` field keeps its own, and an aliased spread is a masking
/// boundary with its own policy; an aliased selection set is a nested lens
/// whose errors are this lens's.
fn collects_errors(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { name, catch, .. } => name != "__typename" && catch.is_none(),
        SelectionPlan::Linked { catch, .. } => catch.is_none(),
        SelectionPlan::Inline {
            alias: Some(_),
            catch: None,
            selections,
            ..
        } => !matches!(selections.as_slice(), [SelectionPlan::Spread { .. }]),
        _ => false,
    }
}

/// The Swift test of a member's guards, or none when it is always fetched.
fn guard_condition(guards: &[Vec<Guard>]) -> Option<String> {
    if guards.is_empty() {
        return None;
    }
    let alternatives: Vec<String> = guards
        .iter()
        .map(|conjunction| {
            conjunction
                .iter()
                .map(|guard| {
                    format!(
                        "anchor.selects({}, {})",
                        swift_literal(&guard.variable),
                        guard.passing
                    )
                })
                .collect::<Vec<_>>()
                .join(" && ")
        })
        .collect();
    if alternatives.len() == 1 {
        Some(alternatives[0].clone())
    } else {
        Some(format!("({})", alternatives.join(" || ")))
    }
}

/// The members a lens's own checks cover: its fields, and inline fragments
/// it names with an alias. Spreads and lenses on other types check
/// themselves.
fn own_members(members: &[Member]) -> impl Iterator<Item = &Member> {
    members.iter().filter(|member| match &member.selection {
        SelectionPlan::Scalar { .. } | SelectionPlan::Linked { .. } => true,
        SelectionPlan::Inline { alias, .. } => alias.is_some(),
        _ => false,
    })
}

/// Whether a connection's lens gets `nodes`: it selects `edges { node }`
/// and no field `nodes` itself.
fn selects_nodes(selections: &[SelectionPlan]) -> bool {
    let flat = fields_within(selections);
    let has_nodes_field = flat.iter().any(|selection| match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            alias.as_deref().unwrap_or(name) == "nodes"
        }
        _ => false,
    });
    if has_nodes_field {
        return false;
    }
    flat.iter().any(|selection| {
        match selection {
        SelectionPlan::Linked {
            name,
            alias: None,
            selections,
            ..
        } if name == "edges" => fields_within(selections).iter().any(|selection| {
            matches!(selection, SelectionPlan::Linked { name, alias: None, .. } if name == "node")
        }),
        _ => false,
    }
    })
}

/// The name a property's value goes by as a parameter or a local: the
/// property's own, escaped, except for `self`, which as a parameter or a
/// local would hide the instance. It goes by `selfValue`, numbered past the
/// names in `taken`.
fn local_name(property: &str, taken: &[&str]) -> String {
    if property != "self" {
        return escape(property);
    }
    let mut name = "selfValue".to_string();
    let mut number = 2;
    while taken.contains(&name.as_str()) {
        name = format!("selfValue{number}");
        number += 1;
    }
    name
}

/// A parameter labelled by `property` whose value goes by `local`.
fn parameter(property: &str, local: &str) -> String {
    let label = escape(property);
    if label == local {
        label
    } else {
        format!("{label} {local}")
    }
}

fn parameter_list(variables: &[VariablePlan]) -> String {
    let names = variable_names(variables);
    variables
        .iter()
        .map(|variable| {
            let default = if variable.non_null { "" } else { " = nil" };
            format!(
                "{}: {}{}",
                parameter(&variable.name, &local_name(&variable.name, &names)),
                variable_type(variable),
                default
            )
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn variable_names(variables: &[VariablePlan]) -> Vec<&str> {
    variables
        .iter()
        .map(|variable| variable.name.as_str())
        .collect()
}

/// A stored property read inside the value's own methods: by its name, or
/// through `self` for `self`, which alone would name the instance.
fn stored(property: &str) -> String {
    if property == "self" {
        "self.`self`".to_string()
    } else {
        escape(property)
    }
}

/// The fields a reader selection reaches without entering another field:
/// its own, and those inside its inline fragments and conditions.
fn fields_within(selections: &[SelectionPlan]) -> Vec<&SelectionPlan> {
    let mut result = Vec::new();
    for selection in selections {
        match selection {
            SelectionPlan::Inline { selections, .. }
            | SelectionPlan::Condition { selections, .. } => {
                result.extend(fields_within(selections))
            }
            SelectionPlan::Spread { .. } => {}
            other => result.push(other),
        }
    }
    result
}

/// The `guards:` argument of a plan field: none when the field is always
/// fetched.
fn guards_expression(guards: &[Vec<Guard>]) -> String {
    if guards.is_empty() {
        return String::new();
    }
    let alternatives: Vec<String> = guards
        .iter()
        .map(|conjunction| {
            let conditions: Vec<String> = conjunction
                .iter()
                .map(|guard| {
                    format!(
                        ".init({}, passing: {})",
                        swift_literal(&guard.variable),
                        guard.passing
                    )
                })
                .collect();
            format!("[{}]", conditions.join(", "))
        })
        .collect();
    format!(", guards: [{}]", alternatives.join(", "))
}

/// A storage key as the parts the runtime joins: the name, then the
/// arguments as `name:value` in order, each value written as JSON the way the
/// runtime renders a variable (object keys sorted, floats as Swift prints
/// them), and each variable left as a part of its own.
fn key_parts(key: &StorageKeyPlan) -> Vec<KeyPart> {
    let mut parts = Vec::new();
    let mut literal = key.name.clone();
    if !key.arguments.is_empty() {
        literal.push('(');
        for (index, argument) in key.arguments.iter().enumerate() {
            if index > 0 {
                literal.push(',');
            }
            literal.push_str(&argument.name);
            literal.push(':');
            value_parts(&argument.value, &mut literal, &mut parts);
        }
        literal.push(')');
    }
    if !literal.is_empty() {
        parts.push(KeyPart::Literal(literal));
    }
    parts
}

fn value_parts(value: &ArgumentValuePlan, literal: &mut String, parts: &mut Vec<KeyPart>) {
    match value {
        ArgumentValuePlan::Variable(name) => {
            if !literal.is_empty() {
                parts.push(KeyPart::Literal(std::mem::take(literal)));
            }
            parts.push(KeyPart::Variable(name.clone()));
        }
        ArgumentValuePlan::Constant(constant) => literal.push_str(&constant_json(constant)),
        ArgumentValuePlan::List(items) => {
            literal.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    literal.push(',');
                }
                value_parts(item, literal, parts);
            }
            literal.push(']');
        }
        ArgumentValuePlan::Object(fields) => {
            let mut sorted: Vec<&(String, ArgumentValuePlan)> = fields.iter().collect();
            sorted.sort_by(|left, right| left.0.cmp(&right.0));
            literal.push('{');
            for (index, (name, field)) in sorted.into_iter().enumerate() {
                if index > 0 {
                    literal.push(',');
                }
                literal.push_str(&json_string(name));
                literal.push(':');
                value_parts(field, literal, parts);
            }
            literal.push('}');
        }
    }
}

/// The key with `$name` for each variable, for naming its slot.
fn template(parts: &[KeyPart]) -> String {
    parts
        .iter()
        .map(|part| match part {
            KeyPart::Literal(text) => text.clone(),
            KeyPart::Variable(name) => format!("${name}"),
        })
        .collect()
}

/// A constant as JSON, as the runtime renders the same value given as a
/// variable: `Variable.json`.
fn constant_json(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "null".to_string(),
        ConstantPlan::Bool(boolean) => boolean.to_string(),
        ConstantPlan::Int(int) => int.to_string(),
        ConstantPlan::Float(float) => swift_double(*float),
        ConstantPlan::String(text) => json_string(text),
        ConstantPlan::List(items) => format!(
            "[{}]",
            items
                .iter()
                .map(constant_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        ConstantPlan::Object(fields) => {
            let mut sorted: Vec<&(String, ConstantPlan)> = fields.iter().collect();
            sorted.sort_by(|left, right| left.0.cmp(&right.0));
            format!(
                "{{{}}}",
                sorted
                    .into_iter()
                    .map(|(name, value)| format!("{}:{}", json_string(name), constant_json(value)))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
    }
}

/// A double as Swift's `description` prints it: the shortest digits that
/// read back, in exponent form when the exponent is 16 or more or below -4,
/// with `.0` on a whole number otherwise.
fn swift_double(value: f64) -> String {
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific
        .split_once('e')
        .expect("Rust writes an exponent in `{:e}`");
    let exponent: i32 = exponent.parse().expect("the exponent is an integer");
    if !(-4..16).contains(&exponent) {
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{mantissa}e{sign}{:02}", exponent.abs());
    }
    let decimal = format!("{value}");
    if decimal.contains('.') {
        decimal
    } else {
        format!("{decimal}.0")
    }
}

/// A JSON string literal, escaped as `Variable.quote` escapes one.
fn json_string(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            other if (other as u32) < 0x20 => output.push_str(&format!("\\u{:04x}", other as u32)),
            other => output.push(other),
        }
    }
    output.push('"');
    output
}

/// A Swift string literal for text that may contain quotes or backslashes
/// (storage keys carry JSON-rendered arguments).
fn swift_literal(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            other => output.push(other),
        }
    }
    output.push('"');
    output
}

/// A `Baton.Variable` expression for a constant.
fn variable_literal(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => ".null".to_string(),
        ConstantPlan::Bool(boolean) => format!(".bool({boolean})"),
        ConstantPlan::Int(int) => format!(".int({int})"),
        ConstantPlan::Float(float) => format!(".double({float:?})"),
        ConstantPlan::String(text) => format!(".string({})", swift_literal(text)),
        ConstantPlan::List(items) => format!(
            ".list([{}])",
            items
                .iter()
                .map(variable_literal)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ConstantPlan::Object(fields) if fields.is_empty() => ".object([:])".to_string(),
        ConstantPlan::Object(fields) => format!(
            ".object([{}])",
            fields
                .iter()
                .map(|(name, value)| format!(
                    "{}: {}",
                    swift_literal(name),
                    variable_literal(value)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// A constant's text, for the rare constant list of connection ids.
fn constant_text(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "null".to_string(),
        ConstantPlan::Bool(boolean) => boolean.to_string(),
        ConstantPlan::Int(int) => int.to_string(),
        ConstantPlan::Float(float) => float.to_string(),
        ConstantPlan::String(text) => text.clone(),
        ConstantPlan::List(items) => format!(
            "[{}]",
            items
                .iter()
                .map(constant_text)
                .collect::<Vec<_>>()
                .join(",")
        ),
        ConstantPlan::Object(fields) => format!(
            "{{{}}}",
            fields
                .iter()
                .map(|(name, value)| format!("{name}:{}", constant_text(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

/// A spread argument as the parent lens binds it: the parent's variable, or
/// a constant.
fn argument_expression(value: &ArgumentValuePlan) -> String {
    match value {
        ArgumentValuePlan::Variable(name) => format!("anchor.variables[{}]", swift_literal(name)),
        ArgumentValuePlan::Constant(constant) => variable_literal(constant),
        ArgumentValuePlan::List(items) => format!(
            ".list([{}])",
            items
                .iter()
                .map(|item| format!("{} ?? .null", argument_expression(item)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ArgumentValuePlan::Object(fields) => format!(
            ".object([{}])",
            fields
                .iter()
                .map(|(name, field)| format!(
                    "{}: {} ?? .null",
                    swift_literal(name),
                    argument_expression(field)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn scalar_reader(kind: TypeKind, list: bool) -> (&'static str, String) {
    let (reader, swift) = match kind {
        TypeKind::Int => ("int", "Int"),
        TypeKind::Float => ("double", "Double"),
        TypeKind::Boolean => ("bool", "Bool"),
        _ => ("string", "String"),
    };
    if list {
        (
            match reader {
                "int" => "ints",
                "double" => "doubles",
                "bool" => "bools",
                _ => "strings",
            },
            format!("[{swift}]"),
        )
    } else {
        (reader, swift.to_string())
    }
}

fn variable_type(variable: &VariablePlan) -> String {
    let base = match variable.base_kind {
        TypeKind::Int => "Int",
        TypeKind::Float => "Double",
        TypeKind::Boolean => "Bool",
        TypeKind::String | TypeKind::Id | TypeKind::Enum | TypeKind::CustomScalar => "String",
        _ => "Baton.Variable",
    };
    let shape = if variable.list {
        format!("[{base}]")
    } else {
        base.to_string()
    };
    if variable.non_null {
        shape
    } else {
        format!("{shape}?")
    }
}

/// The spreads a lens exposes under derived names: its own, and those inside
/// inline fragments and conditions that flatten into it (an inline fragment
/// on the lens's own type, as `@alias` produces; one on another type is a
/// nested lens with its own table). Spreads under an explicit `@alias(as:)`
/// are named by it and left out.
fn collect_spreads<'a>(selections: &'a [SelectionPlan], type_name: &str, into: &mut Vec<&'a str>) {
    for selection in selections {
        match selection {
            SelectionPlan::Spread { fragment, .. } => into.push(fragment.as_str()),
            SelectionPlan::Inline {
                type_condition,
                alias,
                selections: child,
                ..
            } => {
                if alias.is_some() {
                    continue;
                }
                match type_condition {
                    Some(condition) if condition != type_name => {}
                    _ => collect_spreads(child, type_name, into),
                }
            }
            SelectionPlan::Condition {
                selections: child, ..
            } => collect_spreads(child, type_name, into),
            _ => {}
        }
    }
}

/// Default spread accessor names: the fragment's owner prefix in lower camel
/// case, falling back to the whole name when two spreads would collide.
fn spread_accessor_names(
    selections: &[SelectionPlan],
    type_name: &str,
) -> BTreeMap<String, String> {
    let mut fragments: Vec<&str> = Vec::new();
    collect_spreads(selections, type_name, &mut fragments);
    let mut by_prefix: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for fragment in &fragments {
        let prefix = fragment.split('_').next().unwrap_or(fragment);
        by_prefix
            .entry(lower_camel(prefix))
            .or_default()
            .push(fragment);
    }
    let mut names = BTreeMap::new();
    for (prefix, owners) in by_prefix {
        if owners.len() == 1 {
            names.insert(owners[0].to_string(), prefix);
        } else {
            for owner in owners {
                names.insert(owner.to_string(), lower_camel(owner));
            }
        }
    }
    names
}

#[cfg(test)]
#[path = "tests/emit_tests.rs"]
mod tests;
