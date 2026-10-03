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
use crate::pipeline::{
    ArgumentValuePlan, CatchPlan, ConnectionPlan, ConstantPlan, FragmentPlan, HandlePlan,
    LookupPlan, OperationPlan, Plan, RefetchPlan, RequiredPlan, SelectionPlan, StorageKeyPlan,
    TypeKind, VariablePlan,
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

    /// `Character_name`, or `Query_characters_1a2b3c` when the key has arguments.
    fn identifier(&self) -> String {
        if !self.has_arguments {
            return format!("{}_{}", self.type_name, self.field);
        }
        let digest = format!("{:x}", md5::compute(self.template.as_bytes()));
        format!("{}_{}_{}", self.type_name, self.field, &digest[..6])
    }

    /// The Swift expression that yields the slot.
    fn expression(&self) -> String {
        if self.has_variables() {
            format!("Slots.{}(anchor.variables)", self.identifier())
        } else {
            format!("Slots.{}", self.identifier())
        }
    }
}

/// What a spread accessor needs to know about the fragment it produces.
#[derive(Clone, Copy, Default)]
struct FragmentFlags {
    bubbles: bool,
    throws: bool,
}

struct Emitter {
    slots: BTreeSet<SlotRef>,
    types: BTreeSet<String>,
    /// Every fragment's `@argumentDefinitions`, for binding spreads.
    fragment_arguments: BTreeMap<String, Vec<VariablePlan>>,
    fragment_flags: BTreeMap<String, FragmentFlags>,
    /// Fragments spread with `@defer` somewhere: their lenses get `isPresent`.
    deferred_fragments: BTreeSet<String>,
}

/// What the lenses of one document share: the fragment's `@refetchable` data
/// (reached from a nested connection lens through the fragment's name), and
/// the error policy the types follow.
#[derive(Clone, Copy)]
struct Context<'a> {
    owner: &'a str,
    refetch: Option<&'a RefetchPlan>,
    arguments: &'a [VariablePlan],
    /// `@throwOnFieldError` on the document.
    throws: bool,
    /// Inside a `@catch` field or aliased inline fragment.
    within_catch: bool,
}

impl Context<'_> {
    /// Semantic non-null types apply, and lenses scan for field errors.
    fn handles_errors(&self) -> bool {
        self.throws || self.within_catch
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

pub fn emit(plan: &Plan) -> Output {
    let mut deferred_fragments = BTreeSet::new();
    for fragment in &plan.fragments {
        collect_deferred(&fragment.reader, &mut deferred_fragments);
    }
    for operation in &plan.operations {
        collect_deferred(&operation.reader, &mut deferred_fragments);
    }
    let mut emitter = Emitter {
        slots: BTreeSet::new(),
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
        deferred_fragments,
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
    Output {
        shared: emitter.shared(),
        files,
    }
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

impl Emitter {
    fn shared(&self) -> String {
        let mut output = String::new();
        output.push_str(HEADER);
        output.push('\n');
        output
            .push_str("/// Interned schema types used by this module's documents.\nnonisolated enum Types {\n");
        for type_name in &self.types {
            let _ = writeln!(
                output,
                "    static let {type_name} = Baton.Registry.type(\"{type_name}\")"
            );
        }
        output.push_str(
            "}\n\n/// Interned storage keys used by this module's documents.\nnonisolated enum Slots {\n",
        );
        for slot in &self.slots {
            if slot.has_variables() {
                let _ = writeln!(
                    output,
                    "    static func {}(_ variables: Baton.Variables) -> Baton.Slot {{\n        Baton.Registry.slot(Types.{}, {})\n    }}",
                    slot.identifier(),
                    slot.type_name,
                    key_expression(&slot.parts, "variables")
                );
            } else {
                let _ = writeln!(
                    output,
                    "    static let {} = Baton.Registry.slot(Types.{}, {})",
                    slot.identifier(),
                    slot.type_name,
                    swift_literal(&slot.template)
                );
            }
        }
        output.push_str("}\n");
        output
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
            refetch: fragment.refetch.as_ref(),
            arguments: &fragment.arguments,
            throws: fragment.throws_on_field_error,
            within_catch: false,
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
        let _ = writeln!(
            output,
            "nonisolated public struct {}: Baton.Operation {{",
            operation.name
        );
        for variable in &operation.variables {
            let _ = writeln!(
                output,
                "    public var {}: {}",
                variable.name,
                variable_type(variable)
            );
        }
        let _ = writeln!(
            output,
            "    public var resolution: Baton.OperationHandle<Self>? = nil\n"
        );
        let parameters = parameter_list(&operation.variables);
        let _ = writeln!(output, "    public init({parameters}) {{");
        for variable in &operation.variables {
            let _ = writeln!(output, "        self.{0} = {0}", variable.name);
        }
        output.push_str("    }\n\n");
        let _ = writeln!(
            output,
            "    public static let name = \"{}\"",
            operation.name
        );
        let _ = writeln!(
            output,
            "    public static let kind = Baton.OperationKind.{}",
            operation.kind
        );
        let _ = writeln!(
            output,
            "    public static let persistedID = \"{}\"",
            operation.id
        );
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
            operation.text.trim_end()
        );
        output.push_str("    public var variables: Baton.Variables {\n        Baton.Variables([");
        if operation.variables.is_empty() {
            output.push(':');
        } else {
            let entries: Vec<String> = operation
                .variables
                .iter()
                .map(|variable| format!("\"{0}\": Baton.Variable({0})", variable.name))
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
                .map(|variable| format!("lhs.{0} == rhs.{0}", variable.name))
                .collect();
            let _ = writeln!(output, "        {}", comparisons.join(" && "));
        }
        output.push_str("    }\n\n    public func hash(into hasher: inout Hasher) {\n");
        for variable in &operation.variables {
            let _ = writeln!(output, "        hasher.combine({})", variable.name);
        }
        output.push_str("    }\n\n");

        // The normalization plan, as static data.
        let normalization = decide::normalization(&operation.root_type, &operation.normalization);
        output.push_str("    public static let plan = Baton.Plan(root: ");
        self.selection_plan(&mut output, &normalization, 2);
        output.push_str(")\n\n");

        // The root lens.
        let context = Context {
            owner: &operation.name,
            refetch: None,
            arguments: &operation.variables,
            throws: operation.throws_on_field_error,
            within_catch: false,
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
            self.optimistic_builder(&mut output, "OptimisticResponse", &normalization, "    ");
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
                .map(|variable| format!("{0}: {0}", variable.name))
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
        let mut spread_names = spread_accessor_names(selections, type_name);
        self.accessors(
            output,
            type_name,
            type_is_abstract,
            selections,
            &inner,
            &mut nested,
            &mut spread_names,
            context,
        );
        if is_fragment_root && let Some(refetch) = context.refetch {
            self.refetch_members(output, refetch, context, &inner);
        }
        if let Some(connection) = connection {
            self.connection_members(output, connection, type_name, selections, context, &inner);
        }
        if bubbles {
            self.satisfied_function(output, type_name, type_is_abstract, selections, &inner);
        }
        if context.handles_errors() {
            self.field_errors_function(output, type_name, type_is_abstract, selections, &inner);
        }
        if is_fragment_root && self.deferred_fragments.contains(name) {
            self.is_present_function(output, type_name, type_is_abstract, selections, &inner);
        }
        for child in nested {
            output.push('\n');
            let child_context = Context {
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
        selections: &[SelectionPlan],
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
        if let Some((edges, node, node_bubbles)) = edge_node_properties(selections) {
            let filter = if node_bubbles {
                format!(
                    ".filter({}.{}.satisfied)",
                    capitalize(&edges),
                    capitalize(&node)
                )
            } else {
                String::new()
            };
            let _ = writeln!(
                output,
                "{indent}/// The edges' nodes, in order, without nulls."
            );
            let _ = writeln!(
                output,
                "{indent}@MainActor public var nodes: [{edges}.{node}] {{ anchor.nodes(Self.connection){filter}.map({edges}.{node}.init(anchor:)) }}",
                edges = capitalize(&edges),
                node = capitalize(&node)
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

    /// `satisfied`: whether every `@required` field (NONE or LOG) of the
    /// selection is present, recursing into required links. Relay nulls the
    /// enclosing object otherwise; here the parent's accessor returns nil.
    fn satisfied_function(
        &mut self,
        output: &mut String,
        type_name: &str,
        type_is_abstract: bool,
        selections: &[SelectionPlan],
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
        for (selection, _) in own_fields(selections, type_name) {
            match selection {
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
                    lookup,
                    bubbles,
                    alias,
                    name,
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
                        let nested = capitalize(alias.as_deref().unwrap_or(name));
                        let lookup_argument = lookup
                            .as_ref()
                            .map(|lookup| format!(", lookup: {}", lookup_expression(lookup)))
                            .unwrap_or_default();
                        let _ = writeln!(
                            output,
                            "{indent}    guard let child = anchor.linked({slot}{lookup_argument}), {nested}.satisfied(child) else {{ return anchor.requiredMissing(path: {}, log: {}) }}",
                            swift_literal(&required.path),
                            required.action == "LOG"
                        );
                    }
                }
                _ => {}
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
        selections: &[SelectionPlan],
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
        for (selection, _) in own_fields(selections, type_name) {
            match selection {
                SelectionPlan::Scalar {
                    name,
                    storage_key,
                    catch,
                    required,
                    ..
                } => {
                    if name == "__typename" || catch.is_some() {
                        continue;
                    }
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
                    name,
                    alias,
                    storage_key,
                    catch,
                    required,
                    plural,
                    ..
                } => {
                    if catch.is_some() {
                        continue;
                    }
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    let nested = capitalize(alias.as_deref().unwrap_or(name));
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
                SelectionPlan::Inline {
                    alias: Some(alias),
                    catch: None,
                    selections: child,
                    ..
                } => {
                    // An aliased spread is a masking boundary with its own policy;
                    // an aliased selection set is a nested lens of this one.
                    if matches!(child.as_slice(), [SelectionPlan::Spread { .. }]) {
                        continue;
                    }
                    let _ = writeln!(
                        output,
                        "{indent}    errors.append(contentsOf: {}.fieldErrors(anchor))",
                        capitalize(alias)
                    );
                }
                _ => {}
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
        selections: &[SelectionPlan],
        indent: &str,
    ) {
        let mut checks: Vec<String> = Vec::new();
        for (selection, _) in own_fields(selections, type_name) {
            match selection {
                SelectionPlan::Scalar {
                    name, storage_key, ..
                } if name != "__typename" => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    checks.push(format!("anchor.present({slot})"));
                }
                SelectionPlan::Linked { storage_key, .. } => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    checks.push(format!("anchor.present({slot})"));
                }
                _ => {}
            }
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
        selections: &[SelectionPlan],
        indent: &str,
        nested: &mut Vec<Nested>,
        spread_names: &mut BTreeMap<String, String>,
        context: Context<'_>,
    ) {
        for selection in selections {
            match selection {
                SelectionPlan::Scalar {
                    name,
                    alias,
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
                            property: alias.as_deref().unwrap_or(name),
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
                    );
                }
                SelectionPlan::Linked {
                    name,
                    alias,
                    base_type,
                    non_null,
                    semantic_non_null,
                    plural,
                    is_abstract,
                    storage_key,
                    lookup,
                    connection,
                    required,
                    catch,
                    bubbles,
                    selections: child,
                    ..
                } => {
                    let property = alias.clone().unwrap_or_else(|| name.clone());
                    let nested_name = unique_nested_name(&property, nested);
                    self.types.insert(base_type.clone());
                    self.linked_accessor(
                        output,
                        LinkedAccessor {
                            property: &property,
                            nested: &nested_name,
                            base_type,
                            plural: *plural,
                            non_null: *non_null
                                || required.is_some()
                                || (*semantic_non_null && context.handles_errors()),
                            bubbles: *bubbles,
                            required: required.as_ref(),
                            catch: catch.as_ref(),
                            lookup: lookup.as_ref(),
                        },
                        type_name,
                        type_is_abstract,
                        storage_key,
                        indent,
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
                    let accessor = spread_names
                        .get(fragment)
                        .cloned()
                        .unwrap_or_else(|| lower_camel(fragment));
                    self.spread_accessor(
                        output,
                        SpreadAccessor {
                            accessor: &accessor,
                            fragment,
                            arguments,
                            type_condition,
                            deferred: false,
                            catch: None,
                        },
                        type_name,
                        type_is_abstract,
                        indent,
                    );
                }
                SelectionPlan::Inline {
                    type_condition,
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
                        let default_name = spread_names
                            .get(fragment)
                            .cloned()
                            .unwrap_or_else(|| lower_camel(fragment));
                        self.spread_accessor(
                            output,
                            SpreadAccessor {
                                accessor: alias.as_deref().unwrap_or(&default_name),
                                fragment,
                                arguments,
                                type_condition: spread_condition,
                                deferred: deferred.is_some(),
                                catch: catch.as_ref(),
                            },
                            type_name,
                            type_is_abstract,
                            indent,
                        );
                        continue;
                    }
                    if let Some(alias) = alias {
                        // `@alias(as:)` on other selections: a nested lens.
                        let nested_name = unique_nested_name(alias, nested);
                        let condition_type = type_condition.as_deref().unwrap_or(type_name);
                        let conditional = type_condition
                            .as_deref()
                            .is_some_and(|condition| condition != type_name);
                        if conditional {
                            self.types.insert(condition_type.to_string());
                        }
                        let mut guards: Vec<String> = Vec::new();
                        if conditional {
                            guards.push(format!("anchor.record.is(Types.{condition_type})"));
                        }
                        if *bubbles {
                            guards.push(format!("{nested_name}.satisfied(anchor)"));
                        }
                        match catch.as_ref().map(|catch| catch.to.as_str()) {
                            Some("RESULT") => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {}: Result<{nested_name}, Baton.FieldErrors> {{ {nested_name}.caught(anchor) }}",
                                    escape(alias)
                                );
                            }
                            _ if guards.is_empty() => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {}: {nested_name} {{ {nested_name}(anchor: anchor) }}",
                                    escape(alias)
                                );
                            }
                            _ => {
                                let _ = writeln!(
                                    output,
                                    "{indent}@MainActor public var {}: {nested_name}? {{ {} ? {nested_name}(anchor: anchor) : nil }}",
                                    escape(alias),
                                    guards.join(" && ")
                                );
                            }
                        }
                        nested.push(Nested {
                            name: nested_name,
                            type_name: condition_type.to_string(),
                            is_abstract: false,
                            selections: child.clone(),
                            connection: None,
                            bubbles: *bubbles,
                            within_catch: catch.is_some(),
                        });
                        continue;
                    }
                    match type_condition {
                        Some(condition) if condition != type_name => {
                            let nested_name = format!("As{condition}");
                            self.types.insert(condition.clone());
                            let _ = writeln!(
                                output,
                                "{indent}@MainActor public var as{condition}: {nested_name}? {{ anchor.record.is(Types.{condition}) ? {nested_name}(anchor: anchor) : nil }}"
                            );
                            nested.push(Nested {
                                name: nested_name,
                                type_name: condition.clone(),
                                is_abstract: false,
                                selections: child.clone(),
                                connection: None,
                                bubbles: false,
                                within_catch: false,
                            });
                        }
                        _ => self.accessors(
                            output,
                            type_name,
                            type_is_abstract,
                            child,
                            indent,
                            nested,
                            spread_names,
                            context,
                        ),
                    }
                }
                SelectionPlan::Condition {
                    selections: child, ..
                } => {
                    // `@include` / `@skip`: read as if present; a skipped field reads as missing.
                    self.accessors(
                        output,
                        type_name,
                        type_is_abstract,
                        child,
                        indent,
                        nested,
                        spread_names,
                        context,
                    );
                }
            }
        }
    }

    /// A scalar accessor: plain, `@required`, `@catch` or throwing.
    fn scalar_accessor(
        &mut self,
        output: &mut String,
        field: ScalarAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
        indent: &str,
    ) {
        let argument = self.read_argument(type_name, type_is_abstract, storage_key);
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
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: Result<{value_type}, Baton.FieldErrors> {{ anchor.caught({slot}) {{ {read} }} }}"
                );
            }
            (Some("NULL"), _) => {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {swift_type}? {{ anchor.{reader}({argument}) }}"
                );
            }
            (_, Some("THROW")) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                let path =
                    swift_literal(&field.required.map(|r| r.path.clone()).unwrap_or_default());
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {swift_type} {{ get throws {{ try anchor.throwing({slot}, path: {path}) {{ $0.{reader}({argument}) }} }} }}"
                );
            }
            _ if field.non_null => {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {swift_type} {{ anchor.{required_reader}({argument}) }}"
                );
            }
            _ => {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {swift_type}? {{ anchor.{reader}({argument}) }}"
                );
            }
        }
    }

    /// A linked accessor: plain, bubbling, `@required`, `@catch` or throwing,
    /// singular or plural.
    fn linked_accessor(
        &mut self,
        output: &mut String,
        field: LinkedAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
        indent: &str,
    ) {
        let argument = self.read_argument(type_name, type_is_abstract, storage_key);
        let property = escape(field.property);
        let nested = field.nested;
        let base_type = field.base_type;
        let lookup_argument = field
            .lookup
            .map(|lookup| format!(", lookup: {}", lookup_expression(lookup)))
            .unwrap_or_default();
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
                        let _ = writeln!(
                            output,
                            "{indent}@MainActor public var {property}: Result<Baton.List<{nested}>, Baton.FieldErrors> {{ anchor.caughtRequiredList({slot}, within: {nested}.fieldErrors{keep}) }}"
                        );
                    } else {
                        let _ = writeln!(
                            output,
                            "{indent}@MainActor public var {property}: Result<Baton.List<{nested}>?, Baton.FieldErrors> {{ anchor.caughtList({slot}, within: {nested}.fieldErrors{keep}) }}"
                        );
                    }
                }
                (_, Some("THROW")) => {
                    let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                    let _ = writeln!(
                        output,
                        "{indent}@MainActor public var {property}: Baton.List<{nested}> {{ get throws {{ try anchor.throwingList({slot}, path: {path}{keep}) }} }}"
                    );
                }
                _ if field.non_null && catch_to != Some("NULL") => {
                    let _ = writeln!(
                        output,
                        "{indent}@MainActor public var {property}: Baton.List<{nested}> {{ anchor.requiredList({argument}{keep}) }}"
                    );
                }
                _ => {
                    let _ = writeln!(
                        output,
                        "{indent}@MainActor public var {property}: Baton.List<{nested}>? {{ anchor.list({argument}{keep}) }}"
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
                        format!("$0.linked({argument}{lookup_argument}){guarded}"),
                    )
                } else {
                    (
                        nested.to_string(),
                        format!(
                            "{nested}(anchor: $0.requiredLinked({argument}, type: Types.{base_type}{lookup_argument}))"
                        ),
                    )
                };
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: Result<{value_type}, Baton.FieldErrors> {{ anchor.caught({slot}, within: {nested}.fieldErrors) {{ {read} }} }}"
                );
            }
            (_, Some("THROW")) => {
                let slot = self.slot_expression(type_name, type_is_abstract, storage_key);
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {nested} {{ get throws {{ {nested}(anchor: try anchor.throwingLinked({slot}{lookup_argument}, path: {path}, satisfied: {nested}.satisfied)) }} }}"
                );
            }
            _ if optional => {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {nested}? {{ anchor.linked({argument}{lookup_argument}){guarded} }}"
                );
            }
            _ => {
                let _ = writeln!(
                    output,
                    "{indent}@MainActor public var {property}: {nested} {{ {nested}(anchor: anchor.requiredLinked({argument}, type: Types.{base_type}{lookup_argument})) }}"
                );
            }
        }
    }

    /// A spread's accessor. The child's scope is the parent's variables with
    /// the fragment's `@argumentDefinitions` bound: the passed argument, else
    /// the default, else null. The accessor is optional when the type may not
    /// match, the spread is deferred, or the fragment's required fields can
    /// null it; it throws when the fragment has `@throwOnFieldError`; it is a
    /// `Result` under `@catch`.
    fn spread_accessor(
        &mut self,
        output: &mut String,
        spread: SpreadAccessor<'_>,
        type_name: &str,
        type_is_abstract: bool,
        indent: &str,
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
            Some(format!("anchor.binding([{}])", bindings.join(", ")))
        };
        let conditional = type_is_abstract && spread.type_condition != type_name;
        if conditional {
            self.types.insert(spread.type_condition.to_string());
        }
        let anchor = if bound.is_some() { "bound" } else { "anchor" };
        let mut guards: Vec<String> = Vec::new();
        if conditional {
            guards.push(format!("anchor.record.is(Types.{})", spread.type_condition));
        }
        if spread.deferred {
            guards.push(format!("{fragment}.isPresent({anchor})"));
        }
        if flags.bubbles {
            guards.push(format!("{fragment}.satisfied({anchor})"));
        }
        let accessor = escape(spread.accessor);
        let optional = !guards.is_empty();
        let catches = spread.catch.is_some_and(|catch| catch.to == "RESULT");
        let (result_type, effect) = match (catches, flags.throws) {
            (true, _) if optional => (format!("Result<{fragment}?, Baton.FieldErrors>"), ""),
            (true, _) => (format!("Result<{fragment}, Baton.FieldErrors>"), ""),
            (false, true) if optional => (format!("{fragment}?"), " get throws"),
            (false, true) => (fragment.to_string(), " get throws"),
            (false, false) if optional => (format!("{fragment}?"), ""),
            (false, false) => (fragment.to_string(), ""),
        };
        let make = if catches {
            if optional {
                format!("{fragment}.caught({anchor}).map {{ Optional($0) }}")
            } else {
                format!("{fragment}.caught({anchor})")
            }
        } else if flags.throws {
            format!("try {fragment}.throwing({anchor})")
        } else {
            format!("{fragment}(anchor: {anchor})")
        };
        let miss = if catches { ".success(nil)" } else { "nil" };
        if bound.is_none() && guards.is_empty() {
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
        let _ = writeln!(output, "{body_indent}return {make}");
        if !effect.is_empty() {
            let _ = writeln!(output, "{indent}    }}");
        }
        let _ = writeln!(output, "{indent}}}");
    }

    /// The argument a lens accessor passes: a static slot on a concrete type, or
    /// a storage key resolved against the record's own type when the selection
    /// is on an interface or union.
    fn read_argument(
        &mut self,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
    ) -> String {
        if type_is_abstract {
            self.types.insert(type_name.to_string());
            format!(
                "key: {}",
                key_expression(&key_parts(storage_key), "anchor.variables")
            )
        } else {
            self.slot(type_name, storage_key)
        }
    }

    /// A slot as a value: the static slot, or the key resolved against the
    /// record's type for abstract selections. For the readers that take a slot
    /// and more.
    fn slot_expression(
        &mut self,
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
    ) -> String {
        if type_is_abstract {
            self.types.insert(type_name.to_string());
            format!(
                "anchor.slot(key: {})",
                key_expression(&key_parts(storage_key), "anchor.variables")
            )
        } else {
            self.slot(type_name, storage_key)
        }
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
                    let lookup_argument = lookup
                        .as_ref()
                        .map(|lookup| format!(", lookup: {}", lookup_expression(lookup)))
                        .unwrap_or_default();
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
    /// per selection set, every field optional, rendering to JSON.
    fn optimistic_builder(
        &mut self,
        output: &mut String,
        name: &str,
        selection: &NormalizationSelection,
        indent: &str,
    ) {
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
        let mut nested: Vec<(String, NormalizationSelection)> = Vec::new();
        let mut parameters: Vec<String> = Vec::new();
        let mut assignments: Vec<String> = Vec::new();
        let mut renders: Vec<String> = Vec::new();
        for field in fields {
            let property = field.response_key.clone();
            match &field.kind {
                NormalizationKind::Scalar { base_kind, list } => {
                    let (_, swift_type) = scalar_reader(*base_kind, *list);
                    let _ = writeln!(
                        output,
                        "{inner}public var {}: {swift_type}?",
                        escape(&property)
                    );
                    parameters.push(format!("{}: {swift_type}? = nil", escape(&property)));
                    assignments.push(format!("self.{0} = {0}", escape(&property)));
                    renders.push(format!(
                        "if let {0} {{ fields[\"{1}\"] = Baton.Variable({0}) }}",
                        escape(&property),
                        property
                    ));
                }
                NormalizationKind::Linked {
                    plural,
                    selection: child,
                    ..
                } => {
                    let mut nested_name = capitalize(&property);
                    let mut counter = 2;
                    while nested.iter().any(|(existing, _)| existing == &nested_name) {
                        nested_name = format!("{}{counter}", capitalize(&property));
                        counter += 1;
                    }
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
                    parameters.push(format!("{}: {swift_type}? = nil", escape(&property)));
                    assignments.push(format!("self.{0} = {0}", escape(&property)));
                    if *plural {
                        renders.push(format!(
                            "if let {0} {{ fields[\"{1}\"] = .list({0}.map(\\.variable)) }}",
                            escape(&property),
                            property
                        ));
                    } else {
                        renders.push(format!(
                            "if let {0} {{ fields[\"{1}\"] = {0}.variable }}",
                            escape(&property),
                            property
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
        for (nested_name, child) in nested {
            output.push('\n');
            self.optimistic_builder(output, &nested_name, &child, &inner);
        }
        let _ = writeln!(output, "{indent}}}");
    }

    fn slot(&mut self, type_name: &str, storage_key: &StorageKeyPlan) -> String {
        let slot = SlotRef::new(type_name, storage_key);
        let expression = slot.expression();
        self.slots.insert(slot);
        self.types.insert(type_name.to_string());
        expression
    }

    /// The key expression inside a plan: a fixed slot, or the parts a key
    /// with variables is built from.
    fn plan_key(&mut self, type_name: &str, storage_key: &StorageKeyPlan) -> String {
        let slot = SlotRef::new(type_name, storage_key);
        let expression = if slot.has_variables() {
            let parts = slot
                .parts
                .iter()
                .map(|part| match part {
                    KeyPart::Literal(text) => format!(".literal({})", swift_literal(text)),
                    KeyPart::Variable(name) => format!(".variable({})", swift_literal(name)),
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!(".dynamic([{parts}])")
        } else {
            format!(".fixed(Slots.{})", slot.identifier())
        };
        self.slots.insert(slot);
        expression
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
    lookup: Option<&'a LookupPlan>,
}

/// What a spread accessor is made of.
struct SpreadAccessor<'a> {
    accessor: &'a str,
    fragment: &'a str,
    arguments: &'a [crate::pipeline::ArgumentPlan],
    type_condition: &'a str,
    deferred: bool,
    catch: Option<&'a CatchPlan>,
}

/// The selections a lens reads directly: its own fields, those of inline
/// fragments on its type without an alias, and those of conditions; aliased
/// inline fragments come along as themselves, so the caller can name their
/// lens.
fn own_fields<'a>(
    selections: &'a [SelectionPlan],
    type_name: &str,
) -> Vec<(&'a SelectionPlan, Option<&'a str>)> {
    let mut result = Vec::new();
    for selection in selections {
        match selection {
            SelectionPlan::Inline {
                type_condition,
                alias: None,
                selections: child,
                deferred,
                ..
            } => match type_condition {
                Some(condition) if condition != type_name => {}
                _ => result.extend(
                    own_fields(child, type_name)
                        .into_iter()
                        .map(|(inner, label)| (inner, label.or(deferred.as_deref()))),
                ),
            },
            SelectionPlan::Condition {
                selections: child, ..
            } => result.extend(own_fields(child, type_name)),
            SelectionPlan::Spread { .. } => {}
            other => result.push((other, None)),
        }
    }
    result
}

/// The response keys of the `edges` field and of its `node`, and whether the
/// node's required children can null it, when the connection selects them
/// and does not select a `nodes` field itself.
fn edge_node_properties(selections: &[SelectionPlan]) -> Option<(String, String, bool)> {
    let flat = fields_within(selections);
    let has_nodes_field = flat.iter().any(|selection| match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            alias.as_deref().unwrap_or(name) == "nodes"
        }
        _ => false,
    });
    if has_nodes_field {
        return None;
    }
    let edges = flat.iter().find_map(|selection| match selection {
        SelectionPlan::Linked {
            name,
            alias,
            selections,
            ..
        } if name == "edges" && alias.is_none() => Some((name.clone(), selections)),
        _ => None,
    })?;
    let node = fields_within(edges.1)
        .iter()
        .find_map(|selection| match selection {
            SelectionPlan::Linked {
                name,
                alias,
                bubbles,
                ..
            } if name == "node" && alias.is_none() => Some((name.clone(), *bubbles)),
            _ => None,
        })?;
    Some((edges.0, node.0, node.1))
}

fn parameter_list(variables: &[VariablePlan]) -> String {
    variables
        .iter()
        .map(|variable| {
            let default = if variable.non_null { "" } else { " = nil" };
            format!("{}: {}{}", variable.name, variable_type(variable), default)
        })
        .collect::<Vec<_>>()
        .join(", ")
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

/// A Swift expression that builds the key from `variables`.
fn key_expression(parts: &[KeyPart], variables: &str) -> String {
    parts
        .iter()
        .map(|part| match part {
            KeyPart::Literal(text) => swift_literal(text),
            KeyPart::Variable(name) => format!("{variables}.render({})", swift_literal(name)),
        })
        .collect::<Vec<_>>()
        .join(" + ")
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

/// The lookup: the entity type (or none, for an id across types) and the
/// argument's value, a variable or a constant written as a record key writes
/// it: a string as itself, anything else as JSON.
fn lookup_expression(lookup: &LookupPlan) -> String {
    let type_expression = match &lookup.type_name {
        Some(type_name) => format!("Types.{type_name}"),
        None => "nil".to_string(),
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
    format!("Baton.Lookup(type: {type_expression}, key: {key})")
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

fn unique_nested_name(property: &str, nested: &[Nested]) -> String {
    let base = capitalize(property);
    let mut candidate = base.clone();
    let mut counter = 2;
    while nested.iter().any(|child| child.name == candidate) {
        candidate = format!("{base}{counter}");
        counter += 1;
    }
    candidate
}

fn capitalize(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn lower_camel(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_lowercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// Escapes a property name that is a Swift keyword.
fn escape(name: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "Type",
        "Protocol",
        "self",
        "Self",
        "init",
        "deinit",
        "subscript",
        "class",
        "struct",
        "enum",
        "func",
        "var",
        "let",
        "import",
        "extension",
        "operator",
        "static",
        "default",
        "case",
        "switch",
        "if",
        "else",
        "for",
        "in",
        "while",
        "repeat",
        "return",
        "break",
        "continue",
        "where",
        "is",
        "as",
        "try",
        "throw",
        "throws",
        "guard",
        "defer",
        "do",
        "catch",
        "true",
        "false",
        "nil",
        "super",
        "internal",
        "private",
        "public",
        "fileprivate",
        "open",
        "inout",
        "typealias",
        "associatedtype",
        "protocol",
        "some",
        "any",
    ];
    if KEYWORDS.contains(&name) {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

#[cfg(test)]
#[path = "tests/emit_tests.rs"]
mod tests;
