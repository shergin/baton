//! Lens types: a fragment's lens and every lens nested in a lens, their
//! accessors, the connection and refetch surface, and the `satisfied`,
//! `missingRequiredField`, `fieldErrors` and `isPresent` checks, printed
//! from the `ReaderPlan`. What an accessor reads is a piece the value
//! printer shares: an `@inline` fragment's value reads the same
//! expressions once, into stored properties.
//!
//! A lens names the runtime's module only in a type, and a fragment or a
//! query only from its context or through a local alias: the pieces in
//! `swift` hold both rules, so a member named like any of them hides it
//! from nothing a body spells. A lens reaches its own static members,
//! `refetchable` and `connection`, as `Self`, which a member named `Self`
//! would hide; the decide pass refuses one where a body spells it.

use super::swift::{
    Computed, LocalAlias, SwiftType, argument_expression, check_head, possible_types_reference,
    scalar_reader, scalar_type, slot_path, swift_literal, type_reference, variable_literal,
};
use super::writer::Writer;
use crate::decide::{
    Accessor, AliasGuard, AliasedRead, Binding, BoundArgument, ConditionRead, ConnectionMembers,
    ErrorCheck, ErrorLine, FragmentLens, Guard, Guarded, LinkedForm, LinkedRead, LoadMore, Read,
    ReaderPlan, RefetchMembers, SatisfiedCheck, ScalarForm, ScalarRead, SlotAccess, SpreadForm,
    SpreadGuard, SpreadRead, TypeTest,
};
use crate::names::guard_name;
use crate::naming::capitalize;

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
            field_errors_function(writer, checks, "lens");
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

/// What an accessor reads: the type it reads as, the expression, and
/// whether the expression throws.
pub(super) struct Piece {
    pub(super) swift_type: SwiftType,
    pub(super) expression: String,
    pub(super) throws: bool,
}

impl Piece {
    fn new(swift_type: SwiftType, expression: String, throws: bool) -> Piece {
        Piece {
            swift_type,
            expression,
            throws,
        }
    }
}

/// A scalar accessor: plain, `@required`, `@catch` or throwing.
fn scalar_accessor(writer: &mut Writer, name: &str, read: &ScalarRead, condition: Option<&str>) {
    let piece = scalar_piece(read);
    Computed::new(name, piece.swift_type)
        .throwing(piece.throws)
        .reads(writer, &piece.expression, condition);
}

/// What a scalar field reads: plain, `@required`, `@catch` or throwing.
pub(super) fn scalar_piece(read: &ScalarRead) -> Piece {
    let slot = slot_expression(&read.slot);
    let reader = scalar_reader(&read.shape);
    let value = scalar_type(&read.shape);
    if read.shape.primitive.is_mapped() && read.shape.list.is_none() {
        return mapped_piece(read, slot, value);
    }
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
    Piece::new(swift_type, body, throws)
}

/// What a mapped scalar reads: the conversion can fail, so the accessor is
/// optional unless a directive says what a failure does. `@required` and
/// `@throwOnFieldError` make it non-optional and throwing, since a value
/// that does not convert has no zero to read as; `@catch` makes it a
/// `Result` whose failure carries the conversion's error.
fn mapped_piece(read: &ScalarRead, slot: String, value: SwiftType) -> Piece {
    let path = swift_literal(&read.path);
    let (swift_type, body, throws) = match &read.form {
        ScalarForm::Caught { non_null: true } => (
            value.caught(),
            format!("anchor.caughtMapped({slot}, path: {path})"),
            false,
        ),
        ScalarForm::Caught { non_null: false } => (
            value.optional().caught(),
            format!("anchor.caughtOptionalMapped({slot}, path: {path})"),
            false,
        ),
        ScalarForm::Nulled | ScalarForm::Optional => {
            (value.optional(), format!("anchor.mapped({slot})"), false)
        }
        ScalarForm::Throwing { path } => (
            value,
            format!(
                "try anchor.throwingMapped({slot}, path: {})",
                swift_literal(path)
            ),
            true,
        ),
        ScalarForm::Required => (
            value,
            format!("try anchor.throwingMapped({slot}, path: {path})"),
            true,
        ),
    };
    Piece::new(swift_type, body, throws)
}

/// A linked accessor: plain, bubbling, `@required`, `@catch` or throwing,
/// singular or plural.
fn linked_accessor(writer: &mut Writer, name: &str, read: &LinkedRead, condition: Option<&str>) {
    let piece = linked_piece(read, false);
    Computed::new(name, piece.swift_type)
        .throwing(piece.throws)
        .reads(writer, &piece.expression, condition);
}

/// What a linked field reads: plain, bubbling, `@required`, `@catch` or
/// throwing, singular or plural. In a value, a plural link reads as an
/// array of the nested values, and a nested value is built in a closure,
/// since its initializer reads on the main actor.
pub(super) fn linked_piece(read: &LinkedRead, value: bool) -> Piece {
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
    } else if value {
        format!(".map {{ {nested}(anchor: $0) }}")
    } else {
        format!(".map({nested}.init(anchor:))")
    };
    let (list_type, list_reader, build) = if value {
        (
            lens.clone().array(),
            "Values",
            format!(" {{ {nested}(anchor: $0) }}"),
        )
    } else {
        (lens.clone().list(), "List", String::new())
    };
    let (swift_type, body, throws) = match &read.form {
        LinkedForm::CaughtList { non_null: true } => (
            list_type.caught(),
            format!(
                "anchor.caughtRequired{list_reader}({slot}, within: {nested}.fieldErrors{keep}){build}"
            ),
            false,
        ),
        LinkedForm::CaughtList { non_null: false } => (
            list_type.optional().caught(),
            format!(
                "anchor.caught{list_reader}({slot}, within: {nested}.fieldErrors{keep}){build}"
            ),
            false,
        ),
        LinkedForm::ThrowingList { path } => (
            list_type,
            format!(
                "try anchor.throwing{list_reader}({slot}, path: {}{keep}){build}",
                swift_literal(path)
            ),
            true,
        ),
        LinkedForm::RequiredList => (
            list_type,
            format!("anchor.required{list_reader}({slot}{keep}){build}"),
            false,
        ),
        LinkedForm::List => (
            list_type.optional(),
            format!(
                "anchor.{}({slot}{keep}){build}",
                if value { "values" } else { "list" }
            ),
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
    Piece::new(swift_type, body, throws)
}

/// What a spread reads: one expression when nothing guards it and nothing
/// is bound, else the statements of a body that ends in a return.
pub(super) struct SpreadPiece {
    pub(super) swift_type: SwiftType,
    pub(super) throws: bool,
    pub(super) expression: Option<String>,
    pub(super) statements: Vec<String>,
}

/// A spread's accessor: the fragment's lens over the record, in the scope
/// its arguments bind, optional when anything must hold first. It builds
/// the lens from its own type, as `.init(anchor:)`, and calls the
/// fragment's checks through a local alias.
fn spread_accessor(writer: &mut Writer, name: &str, read: &SpreadRead) {
    let piece = spread_piece(read);
    let property = Computed::new(name, piece.swift_type).throwing(piece.throws);
    match &piece.expression {
        Some(expression) => property.reads(writer, expression, None),
        None => property.body(writer, |writer| {
            for statement in &piece.statements {
                writer.line(statement);
            }
        }),
    }
}

/// What a spread reads. The same text builds the fragment's lens or its
/// value: both are made from their own type, as `.init(anchor:)`.
pub(super) fn spread_piece(read: &SpreadRead) -> SpreadPiece {
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
    // A spread enters its fragment: the record becomes the anchor's origin,
    // which a connection below it paginates by.
    let make = match read.form {
        SpreadForm::Caught => None,
        SpreadForm::Throwing => Some(format!("try .throwing({anchor}.entering())")),
        SpreadForm::Plain => Some(format!(".init(anchor: {anchor}.entering())")),
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
        return SpreadPiece {
            swift_type,
            throws,
            expression: Some(make.clone()),
            statements: Vec::new(),
        };
    }
    let mut statements = Vec::new();
    {
        let writer = &mut statements;
        if checks {
            writer.push(alias.declaration());
        }
        if let Some(binding) = &read.binding {
            writer.push(binding_line(binding));
        }
        if !guards.is_empty() {
            writer.push(format!(
                "guard {} else {{ return {miss} }}",
                guards.join(", ")
            ));
        }
        match &make {
            Some(make) => writer.push(format!("return {make}")),
            None => {
                writer.push(format!("let errors = {alias}.fieldErrors({anchor})"));
                writer.push(format!(
                    "return errors.isEmpty ? .success(.init(anchor: {anchor}.entering())) : .failure(.init(errors))"
                ));
            }
        }
    }
    SpreadPiece {
        swift_type,
        throws,
        expression: None,
        statements,
    }
}

/// `bound`, the anchor in the scope a spread's arguments bind, once per
/// owner at the spread's site.
fn binding_line(binding: &Binding) -> String {
    let bindings: Vec<String> = binding
        .arguments
        .iter()
        .map(|(name, value): &(String, BoundArgument)| {
            let value = match value {
                BoundArgument::Passed(value) => argument_expression(value),
                BoundArgument::Default(constant) => variable_literal(constant),
                BoundArgument::Null => ".null".to_string(),
            };
            format!("{}: {value}", swift_literal(name))
        })
        .collect();
    // The closure states its type: inferred from the literal, the time
    // Swift takes to check it doubles with each argument.
    format!(
        "let bound = anchor.binding(Sites.{}) {{ () -> [String: {}] in [{}] }}",
        binding.site,
        SwiftType::runtime("Variable").optional(),
        bindings.join(", ")
    )
}

/// An aliased selection's accessor: its nested lens, optional under its
/// guards, a `Result` under `@catch`.
fn aliased_accessor(writer: &mut Writer, name: &str, read: &AliasedRead) {
    let (piece, condition) = aliased_piece(read);
    Computed::new(name, piece.swift_type).reads(writer, &piece.expression, condition.as_deref());
}

/// What an aliased selection reads, and the condition it reads under.
pub(super) fn aliased_piece(read: &AliasedRead) -> (Piece, Option<String>) {
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
    (Piece::new(swift_type, expression, false), condition)
}

/// A type condition's accessor: its nested lens when the record satisfies
/// the condition.
fn condition_accessor(
    writer: &mut Writer,
    name: &str,
    read: &ConditionRead,
    condition: Option<&str>,
) {
    let (piece, test) = condition_piece(read, condition);
    Computed::new(name, piece.swift_type).reads(writer, &piece.expression, Some(&test));
}

/// What a type condition reads, and the test it reads under, which joins
/// the member's own condition.
pub(super) fn condition_piece(read: &ConditionRead, condition: Option<&str>) -> (Piece, String) {
    let lens = SwiftType::named(&read.lens);
    let test = type_test(&read.test);
    let test = match condition {
        Some(condition) => format!("{condition} && {test}"),
        None => test,
    };
    let expression = format!("{lens}(anchor: anchor)");
    (Piece::new(lens, expression, false), test)
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
        "@_spi(Generated) public static let refetchable: {} = .init(variables: [{}], identifier: {}, identity: {}, first: {}, after: {}, last: {}, before: {})",
        SwiftType::runtime("Refetch"),
        refetch
            .variables
            .iter()
            .map(|name| swift_literal(name))
            .collect::<Vec<_>>()
            .join(", "),
        option(&refetch.identifier),
        refetch
            .identity
            .as_ref()
            .map(slot_expression)
            .unwrap_or_else(|| "nil".to_string()),
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
                Some(SatisfiedCheck::Converts {
                    slot,
                    path,
                    log,
                    host_type,
                }) => {
                    writer.line(format!(
                        "guard anchor.converts({}, to: {host_type}.self, path: {}, log: {log}) else {{ return false }}",
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
                Some(SatisfiedCheck::Converts {
                    slot,
                    path,
                    log,
                    host_type,
                }) => {
                    let path = swift_literal(path);
                    writer.line(format!(
                        "guard anchor.converts({}, to: {host_type}.self, path: {path}, log: {log}) else {{ return {path} }}",
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
/// `@required(action: THROW)` fields that are null. `noun` is what the type
/// is, a lens or a value, for the documentation.
pub(super) fn field_errors_function(writer: &mut Writer, checks: &[ErrorCheck], noun: &str) {
    let errors = SwiftType::runtime("FieldError").array();
    let this = SwiftType::own;
    writer.doc("The field errors in this selection, for `@catch` and `@throwOnFieldError`.");
    let head = check_head("fieldErrors", &errors, false);
    // A selection of spreads alone scans nothing of its own: the spreads
    // keep their fragments' policies.
    if checks.is_empty() {
        writer.line(format!("{head} {{ [] }}"));
    } else {
        field_errors_body(writer, head, checks, &errors);
    }
    writer.doc(format!(
        "The {noun}, or the field errors in it as a thrown `FieldErrors`."
    ));
    writer.line(format!(
        "{} {{ try caught(anchor).get() }}",
        check_head("throwing", &this(), true)
    ));
    writer.doc(format!(
        "The {noun}, or the field errors in it as a `Result`."
    ));
    writer.block(check_head("caught", &this().caught(), false), |writer| {
        writer.line("let errors = fieldErrors(anchor)");
        writer.line(
            "return errors.isEmpty ? .success(.init(anchor: anchor)) : .failure(.init(errors))",
        );
    });
}

fn field_errors_body(writer: &mut Writer, head: String, checks: &[ErrorCheck], errors: &SwiftType) {
    writer.block(head, |writer| {
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
        ErrorLine::Converts {
            slot,
            path,
            host_type,
        } => {
            writer.line(format!(
                "anchor.collectConversion({}, to: {host_type}.self, path: {}, into: &errors)",
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
        ErrorLine::Spread(read) => {
            // A `do` keeps the alias and the binding to this spread, since
            // the body collects for every spread of the value.
            let alias = LocalAlias::fragment(&read.fragment, &[&read.fragment]);
            let anchor = if read.binding.is_some() {
                "bound"
            } else {
                "anchor"
            };
            let guards: Vec<String> = read
                .guards
                .iter()
                .filter_map(|guard| match guard {
                    SpreadGuard::Selects(guards) => guard_condition(guards),
                    SpreadGuard::Test(test) => Some(type_test(test)),
                    SpreadGuard::Present => Some(format!("{alias}.isPresent({anchor})")),
                    SpreadGuard::Satisfied | SpreadGuard::NoErrors => None,
                })
                .collect();
            writer.block("do", |writer| {
                alias.declare(writer);
                if let Some(binding) = &read.binding {
                    writer.line(binding_line(binding));
                }
                let append = format!("errors.append(contentsOf: {alias}.fieldErrors({anchor}))");
                if guards.is_empty() {
                    writer.line(append);
                } else {
                    writer.line(format!("if {} {{ {append} }}", guards.join(" && ")));
                }
            });
        }
    }
}

/// `isPresent`: whether the fragment's own fields have arrived, for a
/// spread under `@defer`.
pub(super) fn is_present_function(writer: &mut Writer, checks: &[Guarded<SlotAccess>]) {
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
pub(super) fn slot_expression(access: &SlotAccess) -> String {
    let slot = &access.slot;
    match (access.on_record_type, slot.has_variables()) {
        (false, false) => slot_path("Slots", slot),
        (false, true) => format!("anchor.owner.slot({})", slot_path("Slots", slot)),
        (true, false) => format!(
            "{}.on(anchor.record.type)",
            slot_path("AbstractSlots", slot)
        ),
        (true, true) => format!(
            "anchor.owner.slot({}, on: anchor.record.type)",
            slot_path("Slots", slot)
        ),
    }
}

/// The Swift test of a record against a type condition.
fn type_test(test: &TypeTest) -> String {
    match test {
        TypeTest::Is(type_name) => format!("anchor.record.is({})", type_reference(type_name)),
        TypeTest::InSet { condition, .. } => format!(
            "{}.includes(anchor.record.type)",
            possible_types_reference(condition)
        ),
    }
}

/// The Swift test of a member's guards, or none when it is always fetched.
pub(super) fn guard_condition(guards: &[Vec<Guard>]) -> Option<String> {
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
                        "anchor.owner.selects(Guards.{})",
                        guard_name(&guard.variable, guard.passing)
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
