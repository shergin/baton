//! Lens types: a fragment's lens and every lens nested in a lens, their
//! accessors, the connection and refetch surface, and the `satisfied`,
//! `fieldErrors` and `isPresent` checks, printed from the `ReaderPlan`.

use std::fmt::Write as _;

use super::swift::{argument_expression, swift_literal, variable_literal};
use crate::decide::{
    Accessor, AliasGuard, AliasedRead, BoundArgument, ConditionRead, ConnectionMembers, ErrorCheck,
    ErrorLine, FragmentLens, Guard, Guarded, LinkedForm, LinkedRead, Read, ReaderPlan,
    RefetchMembers, SatisfiedCheck, ScalarForm, ScalarRead, SlotAccess, SpreadForm, SpreadGuard,
    SpreadRead, TypeTest,
};
use crate::names::{capitalize, escape};

pub(super) fn fragment_text(fragment: &FragmentLens) -> String {
    let mut output = String::new();
    let _ = writeln!(
        output,
        "/// Lens for `fragment {} on {}`.",
        fragment.name, fragment.type_condition
    );
    lens(&mut output, &fragment.lens, "");
    output.push('\n');
    output
}

/// A lens struct and the lenses nested in it.
pub(super) fn lens(output: &mut String, lens: &ReaderPlan, indent: &str) {
    let _ = writeln!(
        output,
        "{indent}nonisolated public struct {}: Baton.Lens {{",
        lens.name
    );
    let _ = writeln!(output, "{indent}    public let anchor: Baton.Anchor");
    let _ = writeln!(
        output,
        "{indent}    public init(anchor: Baton.Anchor) {{ self.anchor = anchor }}"
    );
    let _ = writeln!(
        output,
        "{indent}    public static let typeName = \"{}\"",
        lens.type_name
    );
    let inner = format!("{indent}    ");
    for accessor in &lens.accessors {
        self::accessor(output, accessor, &inner);
    }
    if let Some(refetch) = &lens.refetch {
        refetch_members(output, refetch, &inner);
    }
    if let Some(connection) = &lens.connection {
        connection_members(output, connection, &inner);
    }
    if let Some(entries) = &lens.satisfied {
        satisfied_function(output, entries, &inner);
    }
    if let Some(checks) = &lens.field_errors {
        field_errors_function(output, checks, &inner);
    }
    if let Some(checks) = &lens.is_present {
        is_present_function(output, checks, &inner);
    }
    for child in &lens.nested {
        output.push('\n');
        self::lens(output, child, &inner);
    }
    let _ = writeln!(output, "{indent}}}");
}

fn accessor(output: &mut String, accessor: &Accessor, indent: &str) {
    let condition = guard_condition(&accessor.guards);
    let condition = condition.as_deref();
    match &accessor.read {
        Read::Scalar(read) => scalar_accessor(output, &accessor.name, read, indent, condition),
        Read::Linked(read) => linked_accessor(output, &accessor.name, read, indent, condition),
        Read::Spread(read) => spread_accessor(output, &accessor.name, read, indent),
        Read::Aliased(read) => aliased_accessor(output, &accessor.name, read, indent),
        Read::Condition(read) => {
            condition_accessor(output, &accessor.name, read, indent, condition)
        }
    }
}

/// A scalar accessor: plain, `@required`, `@catch` or throwing.
fn scalar_accessor(
    output: &mut String,
    name: &str,
    read: &ScalarRead,
    indent: &str,
    condition: Option<&str>,
) {
    let slot = slot_expression(&read.slot);
    let property = escape(name);
    let reader = read.reader;
    let swift_type = &read.swift_type;
    let required_reader = format!("required{}", capitalize(reader));
    let (swift_type, body, throws) = match &read.form {
        ScalarForm::Caught { non_null } => {
            let (value_type, read) = if *non_null {
                (swift_type.clone(), format!("$0.{required_reader}({slot})"))
            } else {
                (format!("{swift_type}?"), format!("$0.{reader}({slot})"))
            };
            (
                format!("Result<{value_type}, Baton.FieldErrors>"),
                format!("anchor.caught({slot}) {{ {read} }}"),
                false,
            )
        }
        ScalarForm::Nulled | ScalarForm::Optional => (
            format!("{swift_type}?"),
            format!("anchor.{reader}({slot})"),
            false,
        ),
        ScalarForm::Throwing { path } => (
            swift_type.clone(),
            format!(
                "try anchor.throwing({slot}, path: {}) {{ $0.{reader}({slot}) }}",
                swift_literal(path)
            ),
            true,
        ),
        ScalarForm::Required => (
            swift_type.clone(),
            format!("anchor.{required_reader}({slot})"),
            false,
        ),
    };
    write_accessor(
        output, indent, &property, swift_type, body, throws, condition,
    );
}

/// A linked accessor: plain, bubbling, `@required`, `@catch` or throwing,
/// singular or plural.
fn linked_accessor(
    output: &mut String,
    name: &str,
    read: &LinkedRead,
    indent: &str,
    condition: Option<&str>,
) {
    let slot = slot_expression(&read.slot);
    let property = escape(name);
    let nested = &read.lens;
    let base_type = &read.base_type;
    let keep = if read.bubbles {
        format!(", keep: {nested}.satisfied")
    } else {
        String::new()
    };
    let guarded = if read.bubbles {
        format!(".flatMap {{ {nested}.satisfied($0) ? {nested}(anchor: $0) : nil }}")
    } else {
        format!(".map({nested}.init(anchor:))")
    };
    let (swift_type, body, throws) = match &read.form {
        LinkedForm::CaughtList { non_null: true } => (
            format!("Result<Baton.List<{nested}>, Baton.FieldErrors>"),
            format!("anchor.caughtRequiredList({slot}, within: {nested}.fieldErrors{keep})"),
            false,
        ),
        LinkedForm::CaughtList { non_null: false } => (
            format!("Result<Baton.List<{nested}>?, Baton.FieldErrors>"),
            format!("anchor.caughtList({slot}, within: {nested}.fieldErrors{keep})"),
            false,
        ),
        LinkedForm::ThrowingList { path } => (
            format!("Baton.List<{nested}>"),
            format!(
                "try anchor.throwingList({slot}, path: {}{keep})",
                swift_literal(path)
            ),
            true,
        ),
        LinkedForm::RequiredList => (
            format!("Baton.List<{nested}>"),
            format!("anchor.requiredList({slot}{keep})"),
            false,
        ),
        LinkedForm::List => (
            format!("Baton.List<{nested}>?"),
            format!("anchor.list({slot}{keep})"),
            false,
        ),
        LinkedForm::Caught { optional } => {
            let (value_type, read) = if *optional {
                (format!("{nested}?"), format!("$0.linked({slot}){guarded}"))
            } else {
                (
                    nested.clone(),
                    format!("{nested}(anchor: $0.requiredLinked({slot}, type: Types.{base_type}))"),
                )
            };
            (
                format!("Result<{value_type}, Baton.FieldErrors>"),
                format!("anchor.caught({slot}, within: {nested}.fieldErrors) {{ {read} }}"),
                false,
            )
        }
        LinkedForm::Throwing { path } => (
            nested.clone(),
            format!(
                "{nested}(anchor: try anchor.throwingLinked({slot}, path: {}, satisfied: {nested}.satisfied))",
                swift_literal(path)
            ),
            true,
        ),
        LinkedForm::Optional => (
            format!("{nested}?"),
            format!("anchor.linked({slot}){guarded}"),
            false,
        ),
        LinkedForm::Required => (
            nested.clone(),
            format!("{nested}(anchor: anchor.requiredLinked({slot}, type: Types.{base_type}))"),
            false,
        ),
    };
    write_accessor(
        output, indent, &property, swift_type, body, throws, condition,
    );
}

/// A spread's accessor: the fragment's lens over the record, in the scope
/// its arguments bind, optional when anything must hold first.
fn spread_accessor(output: &mut String, name: &str, read: &SpreadRead, indent: &str) {
    let fragment = &read.fragment;
    let anchor = if read.binding.is_some() {
        "bound"
    } else {
        "anchor"
    };
    let guards: Vec<String> = read
        .guards
        .iter()
        .map(|guard| match guard {
            SpreadGuard::Selects(guards) => {
                guard_condition(guards).expect("a spread guard has conditions")
            }
            SpreadGuard::Test(test) => type_test(test),
            SpreadGuard::Present => format!("{fragment}.isPresent({anchor})"),
            SpreadGuard::Satisfied => format!("{fragment}.satisfied({anchor})"),
            SpreadGuard::NoErrors => format!("{fragment}.fieldErrors({anchor}).isEmpty"),
        })
        .collect();
    let accessor = escape(name);
    let optional = !guards.is_empty();
    let (result_type, effect) = match read.form {
        SpreadForm::Caught if optional => (format!("Result<{fragment}?, Baton.FieldErrors>"), ""),
        SpreadForm::Caught => (format!("Result<{fragment}, Baton.FieldErrors>"), ""),
        SpreadForm::Throwing if optional => (format!("{fragment}?"), " get throws"),
        SpreadForm::Throwing => (fragment.to_string(), " get throws"),
        SpreadForm::Plain if optional => (format!("{fragment}?"), ""),
        SpreadForm::Plain => (fragment.to_string(), ""),
    };
    // A catch reads the errors through what every lens has,
    // `fieldErrors` and `init(anchor:)`: only a fragment with an error
    // policy of its own has `caught`.
    let make = match read.form {
        SpreadForm::Caught => None,
        SpreadForm::Throwing => Some(format!("try {fragment}.throwing({anchor})")),
        SpreadForm::Plain => Some(format!("{fragment}(anchor: {anchor})")),
    };
    let miss = if read.form == SpreadForm::Caught {
        ".success(nil)"
    } else {
        "nil"
    };
    if let Some(make) = &make
        && read.binding.is_none()
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
    if let Some(binding) = &read.binding {
        let bindings: Vec<String> = binding
            .arguments
            .iter()
            .map(|(name, value)| {
                let value = match value {
                    BoundArgument::Passed(value) => argument_expression(value),
                    BoundArgument::Default(constant) => variable_literal(constant),
                    BoundArgument::Null => ".null".to_string(),
                };
                format!("{}: {value}", swift_literal(name))
            })
            .collect();
        let _ = writeln!(
            output,
            "{body_indent}let bound = anchor.binding(Sites.{}) {{ [{}] }}",
            binding.site,
            bindings.join(", ")
        );
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

/// An aliased selection's accessor: its nested lens, optional under its
/// guards, a `Result` under `@catch`.
fn aliased_accessor(output: &mut String, name: &str, read: &AliasedRead, indent: &str) {
    let nested = &read.lens;
    let guards: Vec<String> = read
        .guards
        .iter()
        .map(|guard| match guard {
            AliasGuard::Selects(guards) => {
                guard_condition(guards).expect("an alias guard has conditions")
            }
            AliasGuard::Test(test) => type_test(test),
            AliasGuard::Satisfied => format!("{nested}.satisfied(anchor)"),
        })
        .collect();
    let property = escape(name);
    match (read.caught, guards.is_empty()) {
        (true, true) => {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: Result<{nested}, Baton.FieldErrors> {{ {nested}.caught(anchor) }}"
            );
        }
        (true, false) => {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: Result<{nested}, Baton.FieldErrors>? {{ {} ? {nested}.caught(anchor) : nil }}",
                guards.join(" && ")
            );
        }
        (false, true) => {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: {nested} {{ {nested}(anchor: anchor) }}"
            );
        }
        (false, false) => {
            let _ = writeln!(
                output,
                "{indent}@MainActor public var {property}: {nested}? {{ {} ? {nested}(anchor: anchor) : nil }}",
                guards.join(" && ")
            );
        }
    }
}

/// A type condition's accessor: its nested lens when the record satisfies
/// the condition.
fn condition_accessor(
    output: &mut String,
    name: &str,
    read: &ConditionRead,
    indent: &str,
    condition: Option<&str>,
) {
    let nested = &read.lens;
    let test = type_test(&read.test);
    let test = match condition {
        Some(condition) => format!("{condition} && {test}"),
        None => test,
    };
    let _ = writeln!(
        output,
        "{indent}@MainActor public var {}: {nested}? {{ {test} ? {nested}(anchor: anchor) : nil }}",
        escape(name)
    );
}

/// Writes an accessor: `property` of `swift_type`, reading `body`. Under a
/// guard the accessor is optional and returns nil without a read when the
/// guard fails, so a field a condition left out reports nothing missing.
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

/// The `@refetchable` surface of a fragment lens: the descriptor of its
/// query and `refetch()`.
fn refetch_members(output: &mut String, refetch: &RefetchMembers, indent: &str) {
    let option = |value: &Option<String>| match value {
        Some(name) => swift_literal(name),
        None => "nil".to_string(),
    };
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
        option(&refetch.first),
        option(&refetch.after),
        option(&refetch.last),
        option(&refetch.before),
    );
    let _ = writeln!(
        output,
        "{indent}/// Fetches the fragment again through `{}` with its current variables; the records update in place.",
        refetch.operation
    );
    let _ = writeln!(
        output,
        "{indent}@MainActor public func refetch() async throws {{ try await anchor.refetch({}.self, {}.refetchable) }}",
        refetch.operation, refetch.owner
    );
}

/// The connection surface of a lens over a `@connection` field: Relay's
/// state read from the store, `nodes`, and pagination when the fragment is
/// refetchable.
fn connection_members(output: &mut String, connection: &ConnectionMembers, indent: &str) {
    let _ = writeln!(
        output,
        "{indent}/// The connection's slots: edges, nodes, cursors and the page info, for the store's merge and the state below."
    );
    let _ = writeln!(
        output,
        "{indent}public static let connection = Baton.ConnectionSlots(connection: Types.{}, edge: Types.{}, pageInfo: Types.{})",
        connection.connection_type, connection.edge_type, connection.page_info_type
    );
    if let Some(nodes) = &connection.nodes {
        let (edges, node) = (&nodes.edges, &nodes.node);
        let keep = if nodes.keep {
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
    let default_count = |count: Option<i64>| match count {
        Some(count) => format!(" = {count}"),
        None => String::new(),
    };
    if let Some(load) = &connection.load_next {
        let _ = writeln!(
            output,
            "{indent}/// Fetches the next `count` edges through `{}` and appends them; a no-op while loading or at the end.",
            load.operation
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public func loadNext(_ count: Int{}) async throws {{ try await anchor.loadNext({}.self, Self.connection, {}.refetchable, count: count) }}",
            default_count(load.default_count),
            load.operation,
            load.owner
        );
    }
    if let Some(load) = &connection.load_previous {
        let _ = writeln!(
            output,
            "{indent}/// Fetches the previous `count` edges through `{}` and prepends them; a no-op while loading or at the start.",
            load.operation
        );
        let _ = writeln!(
            output,
            "{indent}@MainActor public func loadPrevious(_ count: Int{}) async throws {{ try await anchor.loadPrevious({}.self, Self.connection, {}.refetchable, count: count) }}",
            default_count(load.default_count),
            load.operation,
            load.owner
        );
    }
}

/// Opens the block a guarded check is written in: the indent its lines
/// take, and the line that closes it, none when nothing guards it.
fn open_guard(output: &mut String, guards: &[Vec<Guard>], indent: &str) -> (String, String) {
    match guard_condition(guards) {
        Some(condition) => {
            let _ = writeln!(output, "{indent}    if {condition} {{");
            (format!("{indent}    "), format!("{indent}    }}"))
        }
        None => (indent.to_string(), String::new()),
    }
}

/// `satisfied`: whether every `@required` field (NONE or LOG) of the
/// selection is present, recursing into required links.
fn satisfied_function(
    output: &mut String,
    entries: &[Guarded<Option<SatisfiedCheck>>],
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
    for entry in entries {
        let (indent, close) = open_guard(output, &entry.guards, indent);
        match &entry.item {
            Some(SatisfiedCheck::HasValue { slot, path, log }) => {
                let _ = writeln!(
                    output,
                    "{indent}    guard anchor.hasValue({}, path: {}, log: {log}) else {{ return false }}",
                    slot_expression(slot),
                    swift_literal(path)
                );
            }
            Some(SatisfiedCheck::Linked {
                slot,
                lens,
                path,
                log,
            }) => {
                let _ = writeln!(
                    output,
                    "{indent}    guard let child = anchor.linked({}), {lens}.satisfied(child) else {{ return anchor.requiredMissing(path: {}, log: {log}) }}",
                    slot_expression(slot),
                    swift_literal(path)
                );
            }
            None => {}
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
fn field_errors_function(output: &mut String, checks: &[ErrorCheck], indent: &str) {
    let _ = writeln!(
        output,
        "{indent}/// The field errors in this selection, for `@catch` and `@throwOnFieldError`."
    );
    let _ = writeln!(
        output,
        "{indent}@MainActor public static func fieldErrors(_ anchor: Baton.Anchor) -> [Baton.FieldError] {{"
    );
    let _ = writeln!(output, "{indent}    var errors: [Baton.FieldError] = []");
    for check in checks {
        match check {
            ErrorCheck::Condition { guards, test, lens } => {
                let test = type_test(test);
                let test = match guard_condition(guards) {
                    Some(condition) => format!("{condition} && {test}"),
                    None => test,
                };
                let _ = writeln!(
                    output,
                    "{indent}    if {test} {{ errors.append(contentsOf: {lens}.fieldErrors(anchor)) }}"
                );
            }
            ErrorCheck::Member(lines) => {
                let (indent, close) = open_guard(output, &lines.guards, indent);
                for line in &lines.item {
                    match line {
                        ErrorLine::Field(slot) => {
                            let _ = writeln!(
                                output,
                                "{indent}    anchor.collectError({}, into: &errors)",
                                slot_expression(slot)
                            );
                        }
                        ErrorLine::Linked { slot, lens } => {
                            let _ = writeln!(
                                output,
                                "{indent}    anchor.collectErrors({}, within: {lens}.fieldErrors, into: &errors)",
                                slot_expression(slot)
                            );
                        }
                        ErrorLine::List { slot, lens } => {
                            let _ = writeln!(
                                output,
                                "{indent}    anchor.collectErrors(list: {}, within: {lens}.fieldErrors, into: &errors)",
                                slot_expression(slot)
                            );
                        }
                        ErrorLine::Required { slot, path } => {
                            let _ = writeln!(
                                output,
                                "{indent}    anchor.collectRequired({}, path: {}, into: &errors)",
                                slot_expression(slot),
                                swift_literal(path)
                            );
                        }
                        ErrorLine::Nested(lens) => {
                            let _ = writeln!(
                                output,
                                "{indent}    errors.append(contentsOf: {lens}.fieldErrors(anchor))"
                            );
                        }
                    }
                }
                if !close.is_empty() {
                    let _ = writeln!(output, "{close}");
                }
            }
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
fn is_present_function(output: &mut String, checks: &[Guarded<SlotAccess>], indent: &str) {
    let checks: Vec<String> = checks
        .iter()
        .map(|check| {
            let present = format!("anchor.present({})", slot_expression(&check.item));
            match guard_condition(&check.guards) {
                Some(condition) => format!("(!({condition}) || {present})"),
                None => present,
            }
        })
        .collect();
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

/// A slot as a value: the static slot, or on an interface or union the
/// abstract slot taken on the record's type. A key with variables is
/// resolved by the anchor's owner, once.
fn slot_expression(access: &SlotAccess) -> String {
    let slot = &access.slot;
    match (access.on_record_type, slot.has_variables()) {
        (false, false) => slot.path("Slots"),
        (false, true) => format!("anchor.owner.slot({})", slot.path("Slots")),
        (true, false) => format!("{}.on(anchor.record.type)", slot.path("AbstractSlots")),
        (true, true) => format!(
            "anchor.owner.slot({}, on: anchor.record.type)",
            slot.path("Slots")
        ),
    }
}

/// The Swift test of a record against a type condition.
fn type_test(test: &TypeTest) -> String {
    match test {
        TypeTest::Is(type_name) => format!("anchor.record.is(Types.{type_name})"),
        TypeTest::InSet { condition, .. } => {
            format!("Types.{condition}_possible.contains(anchor.record.type)")
        }
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
