//! Lens types: a fragment's lens and every lens nested in a lens, their
//! accessors, the connection and refetch surface, and the `satisfied`,
//! `missingRequiredField`, `fieldErrors` and `isPresent` checks, printed
//! from the `ReaderPlan`.
//!
//! A lens names the runtime's module only in a type, and a fragment or a
//! query only from its context or through a local alias: the pieces in
//! `swift` hold both rules, so a member named like any of them hides it
//! from nothing a body spells. A lens reaches its own static members,
//! `refetchable` and `connection`, as `Self`, which a member named `Self`
//! would hide; the decide pass refuses one where a body spells it.

use super::swift::{
    Computed, LocalAlias, SwiftType, argument_expression, check_head, possible_types_reference,
    scalar_reader, scalar_type, swift_literal, type_reference, variable_literal,
};
use super::writer::Writer;
use crate::decide::{
    Accessor, AliasGuard, AliasedRead, BoundArgument, ConditionRead, ConnectionMembers, ErrorCheck,
    ErrorLine, FragmentLens, Guard, Guarded, LinkedForm, LinkedRead, LoadMore, Read, ReaderPlan,
    RefetchMembers, SatisfiedCheck, ScalarForm, ScalarRead, SlotAccess, SpreadForm, SpreadGuard,
    SpreadRead, TypeTest,
};
use crate::names::capitalize;

pub(super) fn fragment_text(fragment: &FragmentLens) -> String {
    let mut writer = Writer::new();
    writer.doc(format!(
        "Lens for `fragment {} on {}`.",
        fragment.name, fragment.type_condition
    ));
    lens(&mut writer, &fragment.lens);
    writer.blank();
    writer.finish()
}

/// A lens struct and the lenses nested in it.
pub(super) fn lens(writer: &mut Writer, lens: &ReaderPlan) {
    let anchor = SwiftType::runtime("Anchor");
    let head = format!(
        "nonisolated public struct {}: {}",
        SwiftType::named(&lens.name),
        SwiftType::runtime("Lens")
    );
    writer.block(head, |writer| {
        writer.line(format!("@_spi(Generated) public let anchor: {anchor}"));
        writer.line(format!(
            "@_spi(Generated) public init(anchor: {anchor}) {{ self.anchor = anchor }}"
        ));
        writer.line(format!(
            "public static let typeName = {}",
            swift_literal(&lens.type_name)
        ));
        for accessor in &lens.accessors {
            self::accessor(writer, accessor);
        }
        if let Some(refetch) = &lens.refetch {
            refetch_members(writer, refetch);
        }
        if let Some(connection) = &lens.connection {
            connection_members(writer, connection);
        }
        if let Some(entries) = &lens.satisfied {
            satisfied_function(writer, entries);
            if lens.reports_missing {
                missing_required_function(writer, entries);
            }
        }
        if let Some(checks) = &lens.field_errors {
            field_errors_function(writer, checks);
        }
        if let Some(checks) = &lens.is_present {
            is_present_function(writer, checks);
        }
        for child in &lens.nested {
            writer.blank();
            self::lens(writer, child);
        }
    });
}

fn accessor(writer: &mut Writer, accessor: &Accessor) {
    let condition = guard_condition(&accessor.guards);
    let condition = condition.as_deref();
    match &accessor.read {
        Read::Scalar(read) => scalar_accessor(writer, &accessor.name, read, condition),
        Read::Linked(read) => linked_accessor(writer, &accessor.name, read, condition),
        Read::Spread(read) => spread_accessor(writer, &accessor.name, read),
        Read::Aliased(read) => aliased_accessor(writer, &accessor.name, read),
        Read::Condition(read) => condition_accessor(writer, &accessor.name, read, condition),
    }
}

/// A scalar accessor: plain, `@required`, `@catch` or throwing.
fn scalar_accessor(writer: &mut Writer, name: &str, read: &ScalarRead, condition: Option<&str>) {
    let slot = slot_expression(&read.slot);
    let reader = scalar_reader(read.shape);
    let value = scalar_type(read.shape);
    let required_reader = format!("required{}", capitalize(reader));
    let (swift_type, body, throws) = match &read.form {
        ScalarForm::Caught { non_null } => {
            let (value, read) = if *non_null {
                (value, format!("$0.{required_reader}({slot})"))
            } else {
                (value.optional(), format!("$0.{reader}({slot})"))
            };
            (
                value.caught(),
                format!("anchor.caught({slot}) {{ {read} }}"),
                false,
            )
        }
        ScalarForm::Nulled | ScalarForm::Optional => {
            (value.optional(), format!("anchor.{reader}({slot})"), false)
        }
        ScalarForm::Throwing { path } => (
            value,
            format!(
                "try anchor.throwing({slot}, path: {}) {{ $0.{reader}({slot}) }}",
                swift_literal(path)
            ),
            true,
        ),
        ScalarForm::Required => (value, format!("anchor.{required_reader}({slot})"), false),
    };
    Computed::new(name, swift_type)
        .throwing(throws)
        .reads(writer, &body, condition);
}

/// A linked accessor: plain, bubbling, `@required`, `@catch` or throwing,
/// singular or plural.
fn linked_accessor(writer: &mut Writer, name: &str, read: &LinkedRead, condition: Option<&str>) {
    let slot = slot_expression(&read.slot);
    let lens = SwiftType::named(&read.lens);
    let nested = lens.to_string();
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
            lens.list().caught(),
            format!("anchor.caughtRequiredList({slot}, within: {nested}.fieldErrors{keep})"),
            false,
        ),
        LinkedForm::CaughtList { non_null: false } => (
            lens.list().optional().caught(),
            format!("anchor.caughtList({slot}, within: {nested}.fieldErrors{keep})"),
            false,
        ),
        LinkedForm::ThrowingList { path } => (
            lens.list(),
            format!(
                "try anchor.throwingList({slot}, path: {}{keep})",
                swift_literal(path)
            ),
            true,
        ),
        LinkedForm::RequiredList => (
            lens.list(),
            format!("anchor.requiredList({slot}{keep})"),
            false,
        ),
        LinkedForm::List => (
            lens.list().optional(),
            format!("anchor.list({slot}{keep})"),
            false,
        ),
        LinkedForm::Caught { optional } => {
            let (value, read) = if *optional {
                (lens.optional(), format!("$0.linked({slot}){guarded}"))
            } else {
                (
                    lens,
                    format!(
                        "{nested}(anchor: $0.requiredLinked({slot}, type: {}))",
                        type_reference(base_type)
                    ),
                )
            };
            (
                value.caught(),
                format!("anchor.caught({slot}, within: {nested}.fieldErrors) {{ {read} }}"),
                false,
            )
        }
        LinkedForm::Throwing { path } => (
            lens,
            format!(
                "{nested}(anchor: try anchor.throwingLinked({slot}, path: {}, satisfied: {nested}.satisfied))",
                swift_literal(path)
            ),
            true,
        ),
        LinkedForm::Optional => (
            lens.optional(),
            format!("anchor.linked({slot}){guarded}"),
            false,
        ),
        LinkedForm::Required => (
            lens,
            format!(
                "{nested}(anchor: anchor.requiredLinked({slot}, type: {}))",
                type_reference(base_type)
            ),
            false,
        ),
    };
    Computed::new(name, swift_type)
        .throwing(throws)
        .reads(writer, &body, condition);
}

/// A spread's accessor: the fragment's lens over the record, in the scope
/// its arguments bind, optional when anything must hold first. It builds
/// the lens from its own type, as `.init(anchor:)`, and calls the
/// fragment's checks through a local alias.
fn spread_accessor(writer: &mut Writer, name: &str, read: &SpreadRead) {
    let fragment = &read.fragment;
    let alias = LocalAlias::fragment(fragment, &[fragment]);
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
            SpreadGuard::Present => format!("{alias}.isPresent({anchor})"),
            SpreadGuard::Satisfied => format!("{alias}.satisfied({anchor})"),
            SpreadGuard::NoErrors => format!("{alias}.fieldErrors({anchor}).isEmpty"),
        })
        .collect();
    // The body declares the alias only when it calls one of the fragment's
    // checks, and a catch calls `fieldErrors`.
    let checks = read.form == SpreadForm::Caught
        || read.guards.iter().any(|guard| {
            matches!(
                guard,
                SpreadGuard::Present | SpreadGuard::Satisfied | SpreadGuard::NoErrors
            )
        });
    let lens = SwiftType::named(fragment).optional_if(!guards.is_empty());
    let (swift_type, throws) = match read.form {
        SpreadForm::Caught => (lens.caught(), false),
        SpreadForm::Throwing => (lens, true),
        SpreadForm::Plain => (lens, false),
    };
    // A catch reads the errors through what every lens has,
    // `fieldErrors` and `init(anchor:)`: only a fragment with an error
    // policy of its own has `caught`.
    let make = match read.form {
        SpreadForm::Caught => None,
        SpreadForm::Throwing => Some(format!("try .throwing({anchor})")),
        SpreadForm::Plain => Some(format!(".init(anchor: {anchor})")),
    };
    let miss = if read.form == SpreadForm::Caught {
        ".success(nil)"
    } else {
        "nil"
    };
    let property = Computed::new(name, swift_type).throwing(throws);
    if let Some(make) = &make
        && read.binding.is_none()
        && guards.is_empty()
    {
        property.reads(writer, make, None);
        return;
    }
    property.body(writer, |writer| {
        if checks {
            alias.declare(writer);
        }
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
            // The closure states its type: inferred from the literal, the
            // time Swift takes to check it doubles with each argument.
            writer.line(format!(
                "let bound = anchor.binding(Sites.{}) {{ () -> [String: {}] in [{}] }}",
                binding.site,
                SwiftType::runtime("Variable").optional(),
                bindings.join(", ")
            ));
        }
        if !guards.is_empty() {
            writer.line(format!(
                "guard {} else {{ return {miss} }}",
                guards.join(", ")
            ));
        }
        match &make {
            Some(make) => writer.line(format!("return {make}")),
            None => {
                writer.line(format!("let errors = {alias}.fieldErrors({anchor})"));
                writer.line(format!(
                    "return errors.isEmpty ? .success(.init(anchor: {anchor})) : .failure(.init(errors))"
                ));
            }
        }
    });
}

/// An aliased selection's accessor: its nested lens, optional under its
/// guards, a `Result` under `@catch`.
fn aliased_accessor(writer: &mut Writer, name: &str, read: &AliasedRead) {
    let lens = SwiftType::named(&read.lens);
    let nested = lens.to_string();
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
    let condition = (!guards.is_empty()).then(|| guards.join(" && "));
    let (swift_type, expression) = if read.caught {
        (lens.caught(), format!("{nested}.caught(anchor)"))
    } else {
        (lens, format!("{nested}(anchor: anchor)"))
    };
    Computed::new(name, swift_type).reads(writer, &expression, condition.as_deref());
}

/// A type condition's accessor: its nested lens when the record satisfies
/// the condition.
fn condition_accessor(
    writer: &mut Writer,
    name: &str,
    read: &ConditionRead,
    condition: Option<&str>,
) {
    let lens = SwiftType::named(&read.lens);
    let test = type_test(&read.test);
    let test = match condition {
        Some(condition) => format!("{condition} && {test}"),
        None => test,
    };
    let expression = format!("{lens}(anchor: anchor)");
    Computed::new(name, lens).reads(writer, &expression, Some(&test));
}

/// The `@refetchable` surface of a fragment lens: the descriptor of its
/// query and `refetch()`.
fn refetch_members(writer: &mut Writer, refetch: &RefetchMembers) {
    let option = |value: &Option<String>| match value {
        Some(name) => swift_literal(name),
        None => "nil".to_string(),
    };
    writer.doc(format!(
        "How the fragment is fetched again: `{}` with the lens's variables.",
        refetch.operation
    ));
    writer.line(format!(
        "@_spi(Generated) public static let refetchable: {} = .init(variables: [{}], identifier: {}, first: {}, after: {}, last: {}, before: {})",
        SwiftType::runtime("Refetch"),
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
    ));
    writer.doc(format!(
        "Fetches the fragment again through `{}` with its current variables; the records update in place.",
        refetch.operation
    ));
    let query = LocalAlias::query(&refetch.operation, &[&refetch.operation]);
    writer.block("@MainActor public func refetch() async throws", |writer| {
        query.declare(writer);
        writer.line(format!(
            "try await anchor.refetch({query}.self, Self.refetchable)"
        ));
    });
}

/// The connection surface of a lens over a `@connection` field: Relay's
/// state read from the store, `nodes`, and pagination when the fragment is
/// refetchable.
fn connection_members(writer: &mut Writer, connection: &ConnectionMembers) {
    let boolean = || SwiftType::named("Bool");
    writer.doc(
        "The connection's slots: edges, nodes, cursors and the page info, for the store's merge and the state below.",
    );
    writer.line(format!(
        "@_spi(Generated) public static let connection: {} = .init(connection: {}, edge: {}, pageInfo: {})",
        SwiftType::runtime("ConnectionSlots"),
        type_reference(&connection.connection_type),
        type_reference(&connection.edge_type),
        type_reference(&connection.page_info_type)
    ));
    if let Some(nodes) = &connection.nodes {
        let node = SwiftType::named(&nodes.edges).nested(&nodes.node);
        let keep = if nodes.keep {
            format!(", keep: {node}.satisfied")
        } else {
            String::new()
        };
        writer.doc("The edges' nodes, in order, without nulls.");
        Computed::new("nodes", node.array()).reads(
            writer,
            &format!("anchor.nodes(Self.connection{keep})"),
            None,
        );
    }
    writer.doc("Whether the server has edges after the last one, from the merged `pageInfo`.");
    for state in [
        "hasNext",
        "hasPrevious",
        "isLoadingNext",
        "isLoadingPrevious",
    ] {
        Computed::new(state, boolean()).reads(
            writer,
            &format!("anchor.{state}(Self.connection)"),
            None,
        );
    }
    writer.doc("Relay's connection id, for the `connections` argument of the edge directives.");
    Computed::new("connectionID", SwiftType::named("String")).reads(
        writer,
        "anchor.record.key",
        None,
    );
    if let Some(load) = &connection.load_next {
        writer.doc(format!(
            "Fetches the next `count` edges through `{}` and appends them; a no-op while loading or at the end.",
            load.operation
        ));
        load_more(writer, "loadNext", load);
    }
    if let Some(load) = &connection.load_previous {
        writer.doc(format!(
            "Fetches the previous `count` edges through `{}` and prepends them; a no-op while loading or at the start.",
            load.operation
        ));
        load_more(writer, "loadPrevious", load);
    }
}

/// `loadNext` or `loadPrevious`, named `function`: the fragment's refetch
/// query and descriptor, both named through local aliases, since the
/// connection's lens is nested in the fragment's.
fn load_more(writer: &mut Writer, function: &str, load: &LoadMore) {
    let named = [load.operation.as_str(), load.owner.as_str()];
    let query = LocalAlias::query(&load.operation, &named);
    let fragment = LocalAlias::fragment(&load.owner, &named);
    let default_count = match load.default_count {
        Some(count) => format!(" = {count}"),
        None => String::new(),
    };
    writer.block(
        format!("@MainActor public func {function}(_ count: Int{default_count}) async throws"),
        |writer| {
            query.declare(writer);
            fragment.declare(writer);
            writer.line(format!(
                "try await anchor.{function}({query}.self, Self.connection, {fragment}.refetchable, count: count)"
            ));
        },
    );
}

/// Writes what `body` writes inside `if` the guards select, or as it is
/// when nothing guards it.
fn guarded(writer: &mut Writer, guards: &[Vec<Guard>], body: impl FnOnce(&mut Writer)) {
    match guard_condition(guards) {
        Some(condition) => writer.block(format!("if {condition}"), body),
        None => body(writer),
    }
}

/// `satisfied`: whether every `@required` field (NONE or LOG) of the
/// selection is present, recursing into required links.
fn satisfied_function(writer: &mut Writer, entries: &[Guarded<Option<SatisfiedCheck>>]) {
    writer.doc(
        "Whether every `@required` field is present; the lens is otherwise null to its parent, as Relay bubbles.",
    );
    let head = check_head("satisfied", &SwiftType::named("Bool"), false);
    writer.block(head, |writer| {
        for entry in entries {
            guarded(writer, &entry.guards, |writer| match &entry.item {
                Some(SatisfiedCheck::HasValue { slot, path, log }) => {
                    writer.line(format!(
                        "guard anchor.hasValue({}, path: {}, log: {log}) else {{ return false }}",
                        slot_expression(slot),
                        swift_literal(path)
                    ));
                }
                Some(SatisfiedCheck::Linked {
                    slot,
                    lens,
                    path,
                    log,
                }) => {
                    writer.line(format!(
                        "guard let child = anchor.linked({}), {}.satisfied(child) else {{ return anchor.requiredMissing(path: {}, log: {log}) }}",
                        slot_expression(slot),
                        SwiftType::named(lens),
                        swift_literal(path)
                    ));
                }
                None => {}
            });
        }
        writer.line("return true");
    });
}

/// `missingRequiredField`: the path of the first `@required` field (NONE or
/// LOG) of the selection that is missing, recursing into required links;
/// nil when `satisfied` holds. It reads and reports what `satisfied` does.
fn missing_required_function(writer: &mut Writer, entries: &[Guarded<Option<SatisfiedCheck>>]) {
    writer
        .doc("The path of the first `@required` field that is missing, which bubbles to the root.");
    let head = check_head(
        "missingRequiredField",
        &SwiftType::named("String").optional(),
        false,
    );
    writer.block(head, |writer| {
        for entry in entries {
            guarded(writer, &entry.guards, |writer| match &entry.item {
                Some(SatisfiedCheck::HasValue { slot, path, log }) => {
                    let path = swift_literal(path);
                    writer.line(format!(
                        "guard anchor.hasValue({}, path: {path}, log: {log}) else {{ return {path} }}",
                        slot_expression(slot)
                    ));
                }
                Some(SatisfiedCheck::Linked {
                    slot,
                    lens,
                    path,
                    log,
                }) => {
                    let path = swift_literal(path);
                    // A link that is null, or that a missing field below it
                    // nulls, is reported under its own path, as `satisfied`
                    // reports it.
                    let report = if *log {
                        format!("_ = anchor.requiredMissing(path: {path}, log: true); ")
                    } else {
                        String::new()
                    };
                    writer.line(format!(
                        "guard let child = anchor.linked({}) else {{ {report}return {path} }}",
                        slot_expression(slot)
                    ));
                    writer.line(format!(
                        "if let missing = {}.missingRequiredField(child) {{ {report}return missing }}",
                        SwiftType::named(lens)
                    ));
                }
                None => {}
            });
        }
        writer.line("return nil");
    });
}

/// `fieldErrors`, `throwing` and `caught`: the field errors in this
/// selection, excluding fields caught by their own `@catch`, plus the
/// `@required(action: THROW)` fields that are null.
fn field_errors_function(writer: &mut Writer, checks: &[ErrorCheck]) {
    let errors = SwiftType::runtime("FieldError").array();
    let this = SwiftType::own;
    writer.doc("The field errors in this selection, for `@catch` and `@throwOnFieldError`.");
    writer.block(check_head("fieldErrors", &errors, false), |writer| {
        writer.line(format!("var errors: {errors} = []"));
        for check in checks {
            match check {
                ErrorCheck::Condition { guards, test, lens } => {
                    let test = type_test(test);
                    let test = match guard_condition(guards) {
                        Some(condition) => format!("{condition} && {test}"),
                        None => test,
                    };
                    writer.line(format!(
                        "if {test} {{ errors.append(contentsOf: {}.fieldErrors(anchor)) }}",
                        SwiftType::named(lens)
                    ));
                }
                ErrorCheck::Member(lines) => {
                    guarded(writer, &lines.guards, |writer| {
                        for line in &lines.item {
                            error_line(writer, line);
                        }
                    });
                }
            }
        }
        writer.line("return errors");
    });
    writer.doc("The lens, or the field errors in it as a thrown `FieldErrors`.");
    writer.line(format!(
        "{} {{ try caught(anchor).get() }}",
        check_head("throwing", &this(), true)
    ));
    writer.doc("The lens, or the field errors in it as a `Result`.");
    writer.block(check_head("caught", &this().caught(), false), |writer| {
        writer.line("let errors = fieldErrors(anchor)");
        writer.line(
            "return errors.isEmpty ? .success(.init(anchor: anchor)) : .failure(.init(errors))",
        );
    });
}

/// One member's part of `fieldErrors`.
fn error_line(writer: &mut Writer, line: &ErrorLine) {
    match line {
        ErrorLine::Field(slot) => {
            writer.line(format!(
                "anchor.collectError({}, into: &errors)",
                slot_expression(slot)
            ));
        }
        ErrorLine::Linked { slot, lens } => {
            writer.line(format!(
                "anchor.collectErrors({}, within: {}.fieldErrors, into: &errors)",
                slot_expression(slot),
                SwiftType::named(lens)
            ));
        }
        ErrorLine::List { slot, lens } => {
            writer.line(format!(
                "anchor.collectErrors(list: {}, within: {}.fieldErrors, into: &errors)",
                slot_expression(slot),
                SwiftType::named(lens)
            ));
        }
        ErrorLine::Required { slot, path } => {
            writer.line(format!(
                "anchor.collectRequired({}, path: {}, into: &errors)",
                slot_expression(slot),
                swift_literal(path)
            ));
        }
        ErrorLine::Nested(lens) => {
            writer.line(format!(
                "errors.append(contentsOf: {}.fieldErrors(anchor))",
                SwiftType::named(lens)
            ));
        }
    }
}

/// `isPresent`: whether the fragment's own fields have arrived, for a
/// spread under `@defer`.
fn is_present_function(writer: &mut Writer, checks: &[Guarded<SlotAccess>]) {
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
    let present = if checks.is_empty() {
        "true".to_string()
    } else {
        checks.join(" && ")
    };
    writer.doc("Whether the deferred part that carries this fragment has arrived.");
    writer.line(format!(
        "{} {{ {present} }}",
        check_head("isPresent", &SwiftType::named("Bool"), false)
    ));
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
        TypeTest::Is(type_name) => format!("anchor.record.is({})", type_reference(type_name)),
        TypeTest::InSet { condition, .. } => format!(
            "{}.contains(anchor.record.type)",
            possible_types_reference(condition)
        ),
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
