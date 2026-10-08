//! Lenses in Kotlin: a fragment's lens, an operation's `Data` and every
//! lens nested in them, their accessors, the connection and refetch
//! surface, and the checks a lens's companion holds; and an `@inline`
//! fragment's value, a data class read once from the same pieces. Printed
//! from the `ReaderPlan` the decide pass settled, as the Swift lens is.
//!
//! Kotlin has no protocol defaults: a check a lens does not declare is
//! spelled here as the default Swift's protocol gives, `true` or no
//! errors, so the printer asks the lens it names whether it has one.
//!
//! A lens names its own class through its path from the top-level
//! declaration, `Op.Data.Character`, since a lens nested in it may take
//! its name; its own static members it reaches through `Companion`.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use super::super::writer::Writer;
use super::literal::{Converters, jvm_getters, string_literal, type_reference, variable_literal};
use super::shared::connection_member;
use crate::decide::{
    Accessor, AliasGuard, AliasedRead, Binding, BoundArgument, ConditionRead, ConnectionMembers,
    ErrorCheck, ErrorLine, FragmentLens, Guard, Guarded, LinkedForm, LinkedRead, LoadMore,
    Primitive, Read, ReaderPlan, RefetchMembers, SatisfiedCheck, ScalarForm, ScalarRead,
    ScalarShape, Shared, SlotAccess, SpreadForm, SpreadGuard, SpreadRead, TypeTest,
};
use crate::kotlin_names::{enum_type_name, escape, slot_name};
use crate::names::{guard_name, possible_types};
use crate::naming::capitalize;
use crate::pipeline::{ArgumentValuePlan, ConstantPlan};

use super::literal::slot_member;

/// What a lens printer looks up beyond the lens it prints: the converters'
/// types, the fragments a spread names, and the shared file's names.
pub(super) struct Lenses<'a> {
    pub converters: &'a Converters<'a>,
    pub fragments: BTreeMap<&'a str, &'a ReaderPlan>,
    pub shared: &'a Shared,
}

/// The getters a JVM class has beside its properties: a lens's `anchor` and
/// `recordID`, and `getClass`, which every object has.
const LENS_GETTERS: [&str; 3] = ["getAnchor", "getRecordID", "getClass"];

/// What an accessor reads: its Kotlin type and how its getter computes it.
struct Piece {
    kotlin_type: String,
    body: Body,
}

/// A getter's body: one expression, or statements that end in a return.
enum Body {
    Expression(String),
    Statements(Vec<String>),
}

impl Piece {
    fn expression(kotlin_type: String, expression: String) -> Piece {
        Piece {
            kotlin_type,
            body: Body::Expression(expression),
        }
    }
}

/// The type made nullable, once.
fn nullable(kotlin_type: &str) -> String {
    if kotlin_type.ends_with('?') {
        kotlin_type.to_string()
    } else {
        format!("{kotlin_type}?")
    }
}

/// A `Result` of `success`, what a `@catch` reads as.
fn caught(success: &str) -> String {
    format!("Result<{success}>")
}

/// A KDoc comment of one line.
fn kdoc(writer: &mut Writer, text: impl AsRef<str>) {
    writer.line(format!("/** {} */", text.as_ref()));
}

/// The names a lens's own properties take, which hide a class of the same
/// name from its getters, where Kotlin reads a name as the property before
/// the class: a fragment spread, a query a refetch runs, an enum, the
/// standard library's `Result`. Neither the companion nor a nested lens
/// sees the properties, so a getter reaches a hidden class through a
/// reference its companion keeps, `Companion.Name_`.
struct Hidden<'a> {
    names: BTreeSet<&'a str>,
    /// The classes a getter reached through the companion.
    aliases: RefCell<BTreeSet<String>>,
}

impl<'a> Hidden<'a> {
    fn new(names: impl IntoIterator<Item = &'a str>) -> Hidden<'a> {
        Hidden {
            names: names.into_iter().collect(),
            aliases: RefCell::new(BTreeSet::new()),
        }
    }

    /// The class `name` as an expression a getter spells: the class itself,
    /// or the companion's reference to it when a property hides it.
    fn reference(&self, name: &str) -> String {
        if !self.names.contains(name) {
            return escape(name);
        }
        self.aliases.borrow_mut().insert(name.to_string());
        format!("Companion.{}", alias(name))
    }

    /// The companion's references, in order.
    fn aliases(&self) -> Vec<String> {
        self.aliases.borrow().iter().cloned().collect()
    }
}

/// The companion's reference to a hidden class `name`.
fn alias(name: &str) -> String {
    format!("{name}_")
}

impl Lenses<'_> {
    /// A fragment's lens, or its value when it is `@inline`.
    pub(super) fn fragment_text(&self, fragment: &FragmentLens) -> String {
        let mut writer = Writer::new();
        let path = escape(&fragment.name);
        if fragment.inline {
            kdoc(
                &mut writer,
                format!(
                    "Value of `fragment {} on {} @inline`.",
                    fragment.name, fragment.type_condition
                ),
            );
            self.value(&mut writer, &fragment.lens, &path);
        } else {
            kdoc(
                &mut writer,
                format!(
                    "Lens for `fragment {} on {}`.",
                    fragment.name, fragment.type_condition
                ),
            );
            self.lens(&mut writer, &fragment.lens, &path);
        }
        writer.finish()
    }

    /// A lens class and the lenses nested in it; `path` names the class
    /// from the top level.
    pub(super) fn lens(&self, writer: &mut Writer, plan: &ReaderPlan, path: &str) {
        writer.line("@Stable");
        let head = format!(
            "class {}(override val anchor: Anchor) : Lens",
            escape(&plan.name)
        );
        writer.block(head, |writer| {
            let mut names: Vec<&str> = plan
                .accessors
                .iter()
                .map(|accessor| accessor.name.as_str())
                .collect();
            if let Some(connection) = &plan.connection {
                if connection.nodes.is_some() {
                    names.push("nodes");
                }
                names.extend([
                    "hasNext",
                    "hasPrevious",
                    "isLoadingNext",
                    "isLoadingPrevious",
                    "connectionID",
                ]);
            }
            let hidden = Hidden::new(names.iter().copied());
            let mut getters = jvm_getters(&names, &LENS_GETTERS).into_iter();
            for accessor in &plan.accessors {
                let getter = getters.next().flatten();
                let piece = self.piece(plan, accessor, &hidden, false, "return");
                property(writer, &accessor.name, getter, piece);
            }
            if let Some(connection) = &plan.connection {
                self.connection_members(writer, plan, connection, &hidden, &mut getters);
            }
            if let Some(refetch) = &plan.refetch {
                refetch_function(writer, refetch, &hidden);
            }
            writer.line(format!(
                "override fun equals(other: Any?): Boolean = other is {path} && other.anchor == anchor"
            ));
            writer.line("override fun hashCode(): Int = anchor.hashCode()");
            self.companion(writer, plan, path, "lens", &hidden.aliases());
            for child in &plan.nested {
                writer.blank();
                self.lens(writer, child, &format!("{path}.{}", escape(&child.name)));
            }
        });
    }

    /// The companion of a lens or a value: the refetch descriptor and the
    /// checks, when it has any.
    fn companion(
        &self,
        writer: &mut Writer,
        plan: &ReaderPlan,
        path: &str,
        noun: &str,
        aliases: &[String],
    ) {
        let has_members = plan.refetch.is_some()
            || plan.satisfied.is_some()
            || plan.field_errors.is_some()
            || plan.is_present.is_some()
            || !aliases.is_empty();
        if !has_members {
            return;
        }
        writer.blank();
        writer.block("companion object", |writer| {
            for name in aliases {
                writer.line(format!("private val {} = {}", alias(name), escape(name)));
            }
            if let Some(refetch) = &plan.refetch {
                refetch_descriptor(writer, refetch);
            }
            if let Some(entries) = &plan.satisfied {
                self.satisfied_function(writer, plan, entries);
                if plan.reports_missing {
                    self.missing_required_function(writer, plan, entries);
                }
            }
            if let Some(checks) = &plan.field_errors {
                self.field_errors_function(writer, plan, checks, path, noun);
            }
            if let Some(checks) = &plan.is_present {
                is_present_function(writer, checks);
            }
        });
    }

    /// The lens nested in `plan` named `name`.
    fn nested<'p>(plan: &'p ReaderPlan, name: &str) -> Option<&'p ReaderPlan> {
        plan.nested.iter().find(|child| child.name == name)
    }

    /// `Sub::fieldErrors` for a lens nested in `plan`, or no errors when it
    /// has no check.
    fn within(plan: &ReaderPlan, lens: &str) -> String {
        match Self::nested(plan, lens) {
            Some(child) if child.field_errors.is_none() => "{ emptyList() }".to_string(),
            _ => format!("{}::fieldErrors", escape(lens)),
        }
    }

    /// Whether the nested lens `lens` declares `satisfied`.
    fn has_satisfied(plan: &ReaderPlan, lens: &str) -> bool {
        Self::nested(plan, lens).is_none_or(|child| child.satisfied.is_some())
    }

    /// The fragment `name`'s lens, when the program declares it.
    fn fragment(&self, name: &str) -> Option<&ReaderPlan> {
        self.fragments.get(name).copied()
    }

    /// What an accessor reads, under the conditions it reads under; in a
    /// value's reading constructor a body's statements return with
    /// `returns`.
    fn piece(
        &self,
        plan: &ReaderPlan,
        accessor: &Accessor,
        hidden: &Hidden,
        value: bool,
        returns: &str,
    ) -> Piece {
        let condition = guard_condition(&accessor.guards);
        let (piece, condition) = match &accessor.read {
            Read::Scalar(read) => (self.scalar_piece(read, hidden), condition),
            Read::Linked(read) => (self.linked_piece(plan, read, value), condition),
            Read::Spread(read) => return self.spread_piece(read, hidden, returns),
            Read::Aliased(read) => aliased_piece(plan, read),
            Read::Condition(read) => condition_piece(read, condition),
        };
        let Some(condition) = condition else {
            return piece;
        };
        let Body::Expression(expression) = piece.body else {
            unreachable!("a read under a condition is one expression");
        };
        Piece::expression(
            nullable(&piece.kotlin_type),
            format!("if ({condition}) {expression} else null"),
        )
    }

    /// What a scalar field reads: plain, `@required`, `@catch` or throwing.
    fn scalar_piece(&self, read: &ScalarRead, hidden: &Hidden) -> Piece {
        let slot = slot_expression(&read.slot);
        let value = self.converters.scalar_type(&read.shape);
        if read.shape.primitive.is_mapped() && read.shape.list.is_none() {
            return mapped_piece(read, &slot, value);
        }
        let reader = scalar_reader(&read.shape);
        let argument = reader_argument(&read.shape.primitive, hidden);
        let required = format!("required{}", capitalize(reader));
        match &read.form {
            ScalarForm::Caught { non_null } => {
                let (value, reader) = if *non_null {
                    (value, required)
                } else {
                    (nullable(&value), reader.to_string())
                };
                Piece::expression(
                    caught(&value),
                    format!("anchor.caught({slot}) {{ it.{reader}({slot}{argument}) }}"),
                )
            }
            ScalarForm::Nulled | ScalarForm::Optional => Piece::expression(
                nullable(&value),
                format!("anchor.{reader}({slot}{argument})"),
            ),
            ScalarForm::Throwing { path } => Piece::expression(
                value,
                format!(
                    "anchor.throwing({slot}, {}) {{ it.{reader}({slot}{argument}) }}",
                    string_literal(path)
                ),
            ),
            ScalarForm::Required => {
                Piece::expression(value, format!("anchor.{required}({slot}{argument})"))
            }
        }
    }

    /// What a linked field reads: plain, bubbling, `@required`, `@catch` or
    /// throwing, singular or plural. In a value, a plural link reads as a
    /// list of the nested values.
    fn linked_piece(&self, plan: &ReaderPlan, read: &LinkedRead, value: bool) -> Piece {
        let slot = slot_expression(&read.slot);
        let nested = escape(&read.lens);
        let keep = if read.bubbles {
            format!(", keep = {nested}::satisfied")
        } else {
            String::new()
        };
        let within = Self::within(plan, &read.lens);
        // A lens is built by its constructor's reference; a value by a
        // lambda, since its class has a constructor of its fields too.
        let build = if value {
            format!("{{ {nested}(it) }}")
        } else {
            format!("::{nested}")
        };
        let single = if read.bubbles {
            format!("?.takeIf({nested}::satisfied)?.let(::{nested})")
        } else if value {
            format!("?.let {{ {nested}(it) }}")
        } else {
            format!("?.let(::{nested})")
        };
        let list = format!("List<{nested}>");
        let required_linked = |anchor: &str| {
            format!(
                "{nested}({anchor}.requiredLinked({slot}, {}))",
                type_reference(&read.base_type)
            )
        };
        match &read.form {
            LinkedForm::CaughtList { non_null } => {
                let (kotlin_type, reader) = match (*non_null, value) {
                    (true, false) => (list, "caughtRequiredList"),
                    (false, false) => (nullable(&list), "caughtList"),
                    (true, true) => (list, "caughtRequiredValues"),
                    (false, true) => (nullable(&list), "caughtValues"),
                };
                let expression = if value {
                    format!("anchor.{reader}({slot}, {within}) {build}")
                } else {
                    format!("anchor.{reader}({slot}, {within}, {build}{keep})")
                };
                Piece::expression(caught(&kotlin_type), expression)
            }
            LinkedForm::ThrowingList { path } => {
                debug_assert!(!value, "a value's property reads without throwing");
                Piece::expression(
                    list,
                    format!(
                        "anchor.throwingList({slot}, {}, {build}{keep})",
                        string_literal(path)
                    ),
                )
            }
            LinkedForm::RequiredList => {
                let expression = if value {
                    format!("anchor.requiredValues({slot}) {build}")
                } else {
                    format!("anchor.requiredList({slot}, {build}{keep})")
                };
                Piece::expression(list, expression)
            }
            LinkedForm::List => {
                let expression = if value {
                    format!("anchor.values({slot}) {build}")
                } else {
                    format!("anchor.list({slot}, {build}{keep})")
                };
                Piece::expression(nullable(&list), expression)
            }
            LinkedForm::Caught { optional: true } => Piece::expression(
                caught(&nullable(&nested)),
                format!("anchor.caught({slot}, {within}) {{ it.linked({slot}){single} }}"),
            ),
            LinkedForm::Caught { optional: false } => Piece::expression(
                caught(&nested),
                format!(
                    "anchor.caught({slot}, {within}) {{ {} }}",
                    required_linked("it")
                ),
            ),
            LinkedForm::Throwing { path } => {
                let satisfied = if Self::has_satisfied(plan, &read.lens) {
                    format!("{nested}::satisfied")
                } else {
                    "{ true }".to_string()
                };
                Piece::expression(
                    nested.clone(),
                    format!(
                        "{nested}(anchor.throwingLinked({slot}, {}, {satisfied}))",
                        string_literal(path)
                    ),
                )
            }
            LinkedForm::Optional => {
                Piece::expression(nullable(&nested), format!("anchor.linked({slot}){single}"))
            }
            LinkedForm::Required => Piece::expression(nested.clone(), required_linked("anchor")),
        }
    }

    /// What a spread reads: the fragment's lens or value over the record,
    /// entered, in the scope its arguments bind, nullable when anything must
    /// hold first; a `Result` under `@catch`.
    fn spread_piece(&self, read: &SpreadRead, hidden: &Hidden, returns: &str) -> Piece {
        // The fragment's class is built by its constructor, which a call
        // reaches whatever a property is named; its checks are reached
        // through its companion, which a property can hide.
        let fragment = escape(&read.fragment);
        let checks = || hidden.reference(&read.fragment);
        let lens = self.fragment(&read.fragment);
        let has_errors = lens.is_none_or(|lens| lens.field_errors.is_some());
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
                SpreadGuard::Present => lens
                    .is_none_or(|lens| lens.is_present.is_some())
                    .then(|| format!("{}.isPresent({anchor})", checks())),
                SpreadGuard::Satisfied => lens
                    .is_none_or(|lens| lens.satisfied.is_some())
                    .then(|| format!("{}.satisfied({anchor})", checks())),
                SpreadGuard::NoErrors => {
                    has_errors.then(|| format!("{}.fieldErrors({anchor}).isEmpty()", checks()))
                }
            })
            .collect();
        let optional = !read.guards.is_empty();
        let base = if optional {
            nullable(&fragment)
        } else {
            fragment.clone()
        };
        let kotlin_type = match read.form {
            SpreadForm::Caught => caught(&base),
            SpreadForm::Throwing | SpreadForm::Plain => base,
        };
        let entered = format!("{anchor}.entering()");
        let make = match read.form {
            SpreadForm::Caught => None,
            SpreadForm::Throwing => Some(format!("{}.throwing({entered})", checks())),
            SpreadForm::Plain => Some(format!("{fragment}({entered})")),
        };
        if let Some(make) = &make
            && read.binding.is_none()
            && !optional
        {
            return Piece::expression(kotlin_type, make.clone());
        }
        let result = || hidden.reference("Result");
        let miss = if read.form == SpreadForm::Caught {
            format!("{}.success(null)", result())
        } else {
            "null".to_string()
        };
        let mut statements = Vec::new();
        if let Some(binding) = &read.binding {
            statements.push(binding_line(binding));
        }
        match guards.as_slice() {
            [] => {}
            [only] => statements.push(format!("if (!{}) {returns} {miss}", parenthesized(only))),
            several => {
                statements.push(format!("if (!({})) {returns} {miss}", several.join(" && ")))
            }
        }
        match &make {
            Some(make) => statements.push(format!("{returns} {make}")),
            None if has_errors => {
                let result = result();
                statements.push(format!("val errors = {}.fieldErrors({anchor})", checks()));
                statements.push(format!(
                    "{returns} if (errors.isEmpty()) {result}.success({fragment}({entered})) else {result}.failure(FieldErrors(errors))"
                ));
            }
            None => statements.push(format!(
                "{returns} {}.success({fragment}({entered}))",
                result()
            )),
        }
        Piece {
            kotlin_type,
            body: Body::Statements(statements),
        }
    }

    /// The members of a lens over a `@connection` field: `nodes`, Relay's
    /// state read from the store, and pagination when the fragment is
    /// refetchable.
    fn connection_members(
        &self,
        writer: &mut Writer,
        plan: &ReaderPlan,
        connection: &ConnectionMembers,
        hidden: &Hidden,
        getters: &mut impl Iterator<Item = Option<String>>,
    ) {
        let slots = format!(
            "Slots.{}.{}",
            slot_name(&connection.connection_type),
            connection_member(&connection.connection_type, self.shared)
        );
        if let Some(nodes) = &connection.nodes {
            let edges = escape(&nodes.edges);
            let node = format!("{edges}.{}", escape(&nodes.node));
            let keep = match Self::nested(plan, &nodes.edges)
                .and_then(|edges| Self::nested(edges, &nodes.node))
            {
                Some(child) if nodes.keep && child.satisfied.is_some() => {
                    format!(", keep = {node}::satisfied")
                }
                _ => String::new(),
            };
            kdoc(writer, "The edges' nodes, in order, without nulls.");
            property(
                writer,
                "nodes",
                getters.next().flatten(),
                Piece::expression(
                    format!("List<{node}>"),
                    format!("anchor.nodes({slots}, {{ {node}(it) }}{keep})"),
                ),
            );
        }
        kdoc(
            writer,
            "Whether the server has edges after the last one, from the merged `pageInfo`.",
        );
        for state in [
            "hasNext",
            "hasPrevious",
            "isLoadingNext",
            "isLoadingPrevious",
        ] {
            property(
                writer,
                state,
                getters.next().flatten(),
                Piece::expression("Boolean".to_string(), format!("anchor.{state}({slots})")),
            );
        }
        kdoc(
            writer,
            "Relay's connection id, for the `connections` argument of the edge directives.",
        );
        property(
            writer,
            "connectionID",
            getters.next().flatten(),
            Piece::expression("String".to_string(), "anchor.record.key".to_string()),
        );
        if let Some(load) = &connection.load_next {
            kdoc(
                writer,
                format!(
                    "Fetches the next `count` edges through `{}` and appends them; a no-op while loading or at the end.",
                    load.operation
                ),
            );
            load_more(writer, "loadNext", load, &slots, hidden);
        }
        if let Some(load) = &connection.load_previous {
            kdoc(
                writer,
                format!(
                    "Fetches the previous `count` edges through `{}` and prepends them; a no-op while loading or at the start.",
                    load.operation
                ),
            );
            load_more(writer, "loadPrevious", load, &slots, hidden);
        }
    }

    /// `satisfied`: whether every `@required` field (NONE or LOG) of the
    /// selection is present, recursing into required links.
    fn satisfied_function(
        &self,
        writer: &mut Writer,
        plan: &ReaderPlan,
        entries: &[Guarded<Option<SatisfiedCheck>>],
    ) {
        kdoc(
            writer,
            "Whether every `@required` field is present; the lens is otherwise null to its parent, as Relay bubbles.",
        );
        writer.block("fun satisfied(anchor: Anchor): Boolean", |writer| {
            for entry in entries {
                guarded(writer, &entry.guards, |writer| match &entry.item {
                    Some(SatisfiedCheck::HasValue { slot, path, log }) => {
                        writer.line(format!(
                            "if (!anchor.hasValue({}, {}, log = {log})) return false",
                            slot_expression(slot),
                            string_literal(path)
                        ));
                    }
                    Some(SatisfiedCheck::Converts {
                        slot,
                        path,
                        log,
                        host_type,
                    }) => {
                        writer.line(format!(
                            "if (!anchor.converts({}, {host_type}, {}, log = {log})) return false",
                            slot_expression(slot),
                            string_literal(path)
                        ));
                    }
                    Some(SatisfiedCheck::Linked {
                        slot,
                        lens,
                        path,
                        log,
                    }) => {
                        let satisfied = if Self::has_satisfied(plan, lens) {
                            format!("?.let({}::satisfied) != true", escape(lens))
                        } else {
                            " == null".to_string()
                        };
                        writer.line(format!(
                            "if (anchor.linked({}){satisfied}) return anchor.requiredMissing({}, log = {log})",
                            slot_expression(slot),
                            string_literal(path)
                        ));
                    }
                    None => {}
                });
            }
            writer.line("return true");
        });
    }

    /// `missingRequiredField`: the path of the first `@required` field (NONE
    /// or LOG) of the selection that is missing, recursing into required
    /// links; null when `satisfied` holds. It reads and reports what
    /// `satisfied` does.
    fn missing_required_function(
        &self,
        writer: &mut Writer,
        plan: &ReaderPlan,
        entries: &[Guarded<Option<SatisfiedCheck>>],
    ) {
        kdoc(
            writer,
            "The path of the first `@required` field that is missing, which bubbles to the root.",
        );
        writer.block("fun missingRequiredField(anchor: Anchor): String?", |writer| {
            for entry in entries {
                guarded(writer, &entry.guards, |writer| match &entry.item {
                    Some(SatisfiedCheck::HasValue { slot, path, log }) => {
                        let path = string_literal(path);
                        writer.line(format!(
                            "if (!anchor.hasValue({}, {path}, log = {log})) return {path}",
                            slot_expression(slot)
                        ));
                    }
                    Some(SatisfiedCheck::Converts {
                        slot,
                        path,
                        log,
                        host_type,
                    }) => {
                        let path = string_literal(path);
                        writer.line(format!(
                            "if (!anchor.converts({}, {host_type}, {path}, log = {log})) return {path}",
                            slot_expression(slot)
                        ));
                    }
                    Some(SatisfiedCheck::Linked {
                        slot,
                        lens,
                        path,
                        log,
                    }) => {
                        let path = string_literal(path);
                        // A link that is null, or that a missing field below
                        // it nulls, is reported under its own path, as
                        // `satisfied` reports it.
                        let report = if *log {
                            format!("anchor.requiredMissing({path}, log = true); ")
                        } else {
                            String::new()
                        };
                        let reports = Self::nested(plan, lens).is_none_or(|child| child.reports_missing);
                        writer.block("run", |writer| {
                            writer.line(format!(
                                "val child = anchor.linked({}) ?: run {{ {report}return {path} }}",
                                slot_expression(slot)
                            ));
                            if reports {
                                writer.line(format!(
                                    "val missing = {}.missingRequiredField(child)",
                                    escape(lens)
                                ));
                                writer.line(format!(
                                    "if (missing != null) {{ {report}return missing }}"
                                ));
                            }
                        });
                    }
                    None => {}
                });
            }
            writer.line("return null");
        });
    }

    /// `fieldErrors`, `throwing` and `caught`: the field errors in this
    /// selection, excluding fields caught by their own `@catch`, plus the
    /// `@required(action: THROW)` fields that are null.
    fn field_errors_function(
        &self,
        writer: &mut Writer,
        plan: &ReaderPlan,
        checks: &[ErrorCheck],
        path: &str,
        noun: &str,
    ) {
        kdoc(
            writer,
            "The field errors in this selection, for `@catch` and `@throwOnFieldError`.",
        );
        let head = "fun fieldErrors(anchor: Anchor): List<FieldError>";
        // A selection of spreads alone scans nothing of its own: the spreads
        // keep their fragments' policies.
        if checks.is_empty() {
            writer.line(format!("{head} = emptyList()"));
        } else {
            writer.block(head, |writer| {
                writer.line("val errors = mutableListOf<FieldError>()");
                for check in checks {
                    self.error_check(writer, plan, check);
                }
                writer.line("return errors");
            });
        }
        kdoc(
            writer,
            format!("The {noun}, or the field errors in it as a thrown `FieldErrors`."),
        );
        writer.line(format!(
            "fun throwing(anchor: Anchor): {path} = caught(anchor).getOrThrow()"
        ));
        kdoc(
            writer,
            format!("The {noun}, or the field errors in it as a `Result`."),
        );
        writer.block(
            format!("fun caught(anchor: Anchor): Result<{path}>"),
            |writer| {
                writer.line("val errors = fieldErrors(anchor)");
                writer.line(format!(
                    "return if (errors.isEmpty()) Result.success({path}(anchor)) else Result.failure(FieldErrors(errors))"
                ));
            },
        );
    }

    fn error_check(&self, writer: &mut Writer, plan: &ReaderPlan, check: &ErrorCheck) {
        match check {
            ErrorCheck::Condition { guards, test, lens } => {
                if Self::nested(plan, lens).is_some_and(|child| child.field_errors.is_none()) {
                    return;
                }
                let test = type_test(test);
                let test = match guard_condition(guards) {
                    Some(condition) => format!("{condition} && {test}"),
                    None => test,
                };
                writer.line(format!(
                    "if ({test}) errors.addAll({}.fieldErrors(anchor))",
                    escape(lens)
                ));
            }
            ErrorCheck::Member(lines) => {
                guarded(writer, &lines.guards, |writer| {
                    for line in &lines.item {
                        self.error_line(writer, plan, line);
                    }
                });
            }
        }
    }

    /// One member's part of `fieldErrors`.
    fn error_line(&self, writer: &mut Writer, plan: &ReaderPlan, line: &ErrorLine) {
        match line {
            ErrorLine::Field(slot) => {
                writer.line(format!(
                    "anchor.collectError({}, errors)",
                    slot_expression(slot)
                ));
            }
            ErrorLine::Linked { slot, lens } => {
                writer.line(format!(
                    "anchor.collectErrors({}, {}, errors)",
                    slot_expression(slot),
                    Self::within(plan, lens)
                ));
            }
            ErrorLine::List { slot, lens } => {
                writer.line(format!(
                    "anchor.collectListErrors({}, {}, errors)",
                    slot_expression(slot),
                    Self::within(plan, lens)
                ));
            }
            ErrorLine::Required { slot, path } => {
                writer.line(format!(
                    "anchor.collectRequired({}, {}, errors)",
                    slot_expression(slot),
                    string_literal(path)
                ));
            }
            ErrorLine::Converts {
                slot,
                path,
                host_type,
            } => {
                writer.line(format!(
                    "anchor.collectConversion({}, {host_type}, {}, errors)",
                    slot_expression(slot),
                    string_literal(path)
                ));
            }
            ErrorLine::Nested(lens) => {
                if Self::nested(plan, lens).is_some_and(|child| child.field_errors.is_none()) {
                    return;
                }
                writer.line(format!(
                    "errors.addAll({}.fieldErrors(anchor))",
                    escape(lens)
                ));
            }
            ErrorLine::Spread(read) => self.spread_errors(writer, read),
        }
    }

    /// A spread's part of a value's `fieldErrors`: the errors inside what
    /// it spreads, read in the scope it binds and under its guards. A `run`
    /// keeps the binding to this spread.
    fn spread_errors(&self, writer: &mut Writer, read: &SpreadRead) {
        let lens = self.fragment(&read.fragment);
        if lens.is_some_and(|lens| lens.field_errors.is_none()) {
            return;
        }
        let fragment = escape(&read.fragment);
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
                SpreadGuard::Present => lens
                    .is_none_or(|lens| lens.is_present.is_some())
                    .then(|| format!("{fragment}.isPresent({anchor})")),
                SpreadGuard::Satisfied | SpreadGuard::NoErrors => None,
            })
            .collect();
        let append = format!("errors.addAll({fragment}.fieldErrors({anchor}))");
        let append = if guards.is_empty() {
            append
        } else {
            format!("if ({}) {append}", guards.join(" && "))
        };
        match &read.binding {
            Some(binding) => writer.block("run", |writer| {
                writer.line(binding_line(binding));
                writer.line(append);
            }),
            None => writer.line(append),
        }
    }

    /// An `@inline` fragment's value and the values nested in it: a data
    /// class of what the lens's accessors read, and a constructor that reads
    /// them out of the record, once, at the call.
    pub(super) fn value(&self, writer: &mut Writer, plan: &ReaderPlan, path: &str) {
        debug_assert!(
            plan.refetch.is_none() && plan.connection.is_none() && plan.satisfied.is_none(),
            "an inline fragment is neither refetchable nor a connection and has no required field"
        );
        let names: Vec<&str> = plan
            .accessors
            .iter()
            .map(|accessor| accessor.name.as_str())
            .collect();
        let getters = jvm_getters(&names, &["getClass"]);
        let hidden = Hidden::new(names.iter().copied());
        let pieces: Vec<Piece> = plan
            .accessors
            .iter()
            .map(|accessor| self.piece(plan, accessor, &hidden, true, "return@run"))
            .collect();
        let name = escape(&plan.name);
        let parameters: Vec<String> = plan
            .accessors
            .iter()
            .zip(&getters)
            .zip(&pieces)
            .map(|((accessor, getter), piece)| {
                let annotation = getter
                    .as_ref()
                    .map(|getter| format!("@get:JvmName({}) ", string_literal(getter)))
                    .unwrap_or_default();
                format!(
                    "{annotation}val {}: {}",
                    escape(&accessor.name),
                    piece.kotlin_type
                )
            })
            .collect();
        // A data class needs a property; a value of none is equal to every
        // other.
        if parameters.is_empty() {
            writer.line(format!("class {name}() {{"));
        } else {
            writer.closed_block(format!("data class {name}("), ") {", |writer| {
                for parameter in &parameters {
                    writer.line(format!("{parameter},"));
                }
            });
        }
        writer.indented(|writer| {
            kdoc(
                writer,
                "Reads the fragment's fields out of the record, once, at the call.",
            );
            writer.line("@Generated");
            if pieces.is_empty() {
                writer.line("constructor(anchor: Anchor) : this()");
                writer.line(format!(
                    "override fun equals(other: Any?): Boolean = other is {path}"
                ));
                writer.line("override fun hashCode(): Int = 0");
            } else {
                writer.closed_block("constructor(anchor: Anchor) : this(", ")", |writer| {
                    for piece in &pieces {
                        match &piece.body {
                            Body::Expression(expression) => writer.line(format!("{expression},")),
                            Body::Statements(statements) => {
                                writer.closed_block("run {", "},", |writer| {
                                    for statement in statements {
                                        writer.line(statement);
                                    }
                                });
                            }
                        }
                    }
                });
            }
            self.companion(writer, plan, path, "value", &hidden.aliases());
            for child in &plan.nested {
                writer.blank();
                self.value(writer, child, &format!("{path}.{}", escape(&child.name)));
            }
        });
        writer.line("}");
    }
}

/// A property whose getter reads `piece`, under its JVM name when it needs
/// one of its own.
fn property(writer: &mut Writer, name: &str, getter: Option<String>, piece: Piece) {
    let annotation = getter
        .map(|getter| format!("@get:JvmName({}) ", string_literal(&getter)))
        .unwrap_or_default();
    let head = format!("{annotation}val {}: {}", escape(name), piece.kotlin_type);
    match piece.body {
        Body::Expression(expression) => writer.line(format!("{head} get() = {expression}")),
        Body::Statements(statements) => {
            writer.line(head);
            writer.indented(|writer| {
                writer.block("get()", |writer| {
                    for statement in &statements {
                        writer.line(statement);
                    }
                });
            });
        }
    }
}

/// What a mapped scalar reads: the conversion can fail, so the accessor is
/// nullable unless a directive says what a failure does. `@required` and
/// `@throwOnFieldError` make it non-null and throwing; `@catch` makes it a
/// `Result` whose failure carries the conversion's error.
fn mapped_piece(read: &ScalarRead, slot: &str, value: String) -> Piece {
    let Primitive::Mapped(converter) = &read.shape.primitive else {
        unreachable!("a mapped piece reads a mapped scalar");
    };
    let path = string_literal(&read.path);
    match &read.form {
        ScalarForm::Caught { non_null: true } => Piece::expression(
            caught(&value),
            format!("anchor.caughtMapped({slot}, {path}, {converter})"),
        ),
        ScalarForm::Caught { non_null: false } => Piece::expression(
            caught(&nullable(&value)),
            format!("anchor.caughtOptionalMapped({slot}, {path}, {converter})"),
        ),
        ScalarForm::Nulled | ScalarForm::Optional => Piece::expression(
            nullable(&value),
            format!("anchor.mapped({slot}, {converter})"),
        ),
        ScalarForm::Throwing { path } => Piece::expression(
            value,
            format!(
                "anchor.throwingMapped({slot}, {}, {converter})",
                string_literal(path)
            ),
        ),
        ScalarForm::Required => Piece::expression(
            value,
            format!("anchor.throwingMapped({slot}, {path}, {converter})"),
        ),
    }
}

/// What an aliased selection reads, and the condition it reads under.
fn aliased_piece(plan: &ReaderPlan, read: &AliasedRead) -> (Piece, Option<String>) {
    let nested = escape(&read.lens);
    let guards: Vec<String> = read
        .guards
        .iter()
        .filter_map(|guard| match guard {
            AliasGuard::Selects(guards) => guard_condition(guards),
            AliasGuard::Test(test) => Some(type_test(test)),
            AliasGuard::Satisfied => Lenses::has_satisfied(plan, &read.lens)
                .then(|| format!("{nested}.satisfied(anchor)")),
        })
        .collect();
    let condition = (!guards.is_empty()).then(|| guards.join(" && "));
    let piece = if read.caught {
        Piece::expression(caught(&nested), format!("{nested}.caught(anchor)"))
    } else {
        Piece::expression(nested.clone(), format!("{nested}(anchor)"))
    };
    (piece, condition)
}

/// What a type condition reads, and the test it reads under, which joins
/// the member's own condition.
fn condition_piece(read: &ConditionRead, condition: Option<String>) -> (Piece, Option<String>) {
    let nested = escape(&read.lens);
    let test = type_test(&read.test);
    let test = match condition {
        Some(condition) => format!("{condition} && {test}"),
        None => test,
    };
    (
        Piece::expression(nested.clone(), format!("{nested}(anchor)")),
        Some(test),
    )
}

/// The anchor's reader for a scalar: `string`, `ints`, `nullableInts` for a
/// list whose elements the schema types nullable; `mapped` and its lists
/// for a scalar converted at the read, `enumValue` and its lists for an
/// enum.
fn scalar_reader(shape: &ScalarShape) -> &'static str {
    match (&shape.primitive, shape.list.map(|list| list.non_null)) {
        (Primitive::String, None) => "string",
        (Primitive::Int, None) => "int",
        (Primitive::Double, None) => "double",
        (Primitive::Bool, None) => "bool",
        (Primitive::Mapped(_), None) => "mapped",
        (Primitive::Enum(_), None) => "enumValue",
        (Primitive::String, Some(true)) => "strings",
        (Primitive::Int, Some(true)) => "ints",
        (Primitive::Double, Some(true)) => "doubles",
        (Primitive::Bool, Some(true)) => "bools",
        (Primitive::Mapped(_), Some(true)) => "mappedList",
        (Primitive::Enum(_), Some(true)) => "enumValues",
        (Primitive::String, Some(false)) => "nullableStrings",
        (Primitive::Int, Some(false)) => "nullableInts",
        (Primitive::Double, Some(false)) => "nullableDoubles",
        (Primitive::Bool, Some(false)) => "nullableBools",
        (Primitive::Mapped(_), Some(false)) => "nullableMappedList",
        (Primitive::Enum(_), Some(false)) => "nullableEnumValues",
    }
}

/// What a reader takes after the slot: an enum's `of`, or a mapped
/// scalar's converter.
fn reader_argument(primitive: &Primitive, hidden: &Hidden) -> String {
    match primitive {
        Primitive::Enum(name) => format!(", {}::of", hidden.reference(&enum_type_name(name))),
        Primitive::Mapped(converter) => format!(", {converter}"),
        _ => String::new(),
    }
}

/// `bound`, the anchor in the scope a spread's arguments bind, once per
/// owner at the spread's site.
fn binding_line(binding: &Binding) -> String {
    let bindings: Vec<String> = binding
        .arguments
        .iter()
        .map(|(name, value)| {
            let value = match value {
                BoundArgument::Passed(value) => argument_expression(value),
                BoundArgument::Default(constant) => variable_literal(constant),
                BoundArgument::Null => variable_literal(&ConstantPlan::Null),
            };
            format!("{} to {value}", string_literal(name))
        })
        .collect();
    format!(
        "val bound = anchor.binding(Sites.{}) {{ mapOf({}) }}",
        binding.site,
        bindings.join(", ")
    )
}

/// A spread argument as the parent lens binds it: the parent's variable,
/// absent when its scope lacks it, or a constant.
fn argument_expression(value: &ArgumentValuePlan) -> String {
    match value {
        ArgumentValuePlan::Variable(name) => {
            format!("anchor.variables[{}]", string_literal(name))
        }
        ArgumentValuePlan::Constant(constant) => variable_literal(constant),
        ArgumentValuePlan::List(items) => format!(
            "Variable.List(listOf({}))",
            items
                .iter()
                .map(argument_element)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ArgumentValuePlan::Object(fields) => format!(
            "Variable.Object(mapOf({}))",
            fields
                .iter()
                .map(|(name, field)| format!(
                    "{} to {}",
                    string_literal(name),
                    argument_element(field)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// An item of a list or a field of an object a spread argument holds: a
/// variable the parent's scope lacks is null there.
fn argument_element(value: &ArgumentValuePlan) -> String {
    match value {
        ArgumentValuePlan::Variable(_) => {
            format!("({} ?: Variable.Null)", argument_expression(value))
        }
        _ => argument_expression(value),
    }
}

/// The `@refetchable` descriptor: the query, its variables and how the
/// owner is fetched again.
fn refetch_descriptor(writer: &mut Writer, refetch: &RefetchMembers) {
    let option = |value: &Option<String>| match value {
        Some(name) => string_literal(name),
        None => "null".to_string(),
    };
    kdoc(
        writer,
        format!(
            "How the fragment is fetched again: `{}` with the lens's variables.",
            refetch.operation
        ),
    );
    writer.line("@Generated");
    writer.line(format!(
        "val refetchable: Refetch = Refetch(variables = listOf({}), identifier = {}, identity = {}, first = {}, after = {}, last = {}, before = {})",
        refetch
            .variables
            .iter()
            .map(|name| string_literal(name))
            .collect::<Vec<_>>()
            .join(", "),
        option(&refetch.identifier),
        refetch
            .identity
            .as_ref()
            .map(slot_expression)
            .unwrap_or_else(|| "null".to_string()),
        option(&refetch.first),
        option(&refetch.after),
        option(&refetch.last),
        option(&refetch.before),
    ));
}

/// `refetch()`: the fragment fetched again through its query.
fn refetch_function(writer: &mut Writer, refetch: &RefetchMembers, hidden: &Hidden) {
    kdoc(
        writer,
        format!(
            "Fetches the fragment again through `{}` with its current variables; the records update in place.",
            refetch.operation
        ),
    );
    writer.line(format!(
        "suspend fun refetch(): Unit = anchor.refetch({}, Companion.refetchable)",
        hidden.reference(&refetch.operation)
    ));
}

/// `loadNext` or `loadPrevious`, named `function`, through the fragment's
/// refetch query and descriptor.
fn load_more(writer: &mut Writer, function: &str, load: &LoadMore, slots: &str, hidden: &Hidden) {
    let default_count = match load.default_count {
        Some(count) => format!(" = {count}"),
        None => String::new(),
    };
    writer.line(format!(
        "suspend fun {function}(count: Int{default_count}): Unit = anchor.{function}({}, {slots}, {}.refetchable, count)",
        hidden.reference(&load.operation),
        hidden.reference(&load.owner)
    ));
}

/// `isPresent`: whether the fragment's own fields have arrived, for a
/// spread under `@defer`.
fn is_present_function(writer: &mut Writer, checks: &[Guarded<SlotAccess>]) {
    let checks: Vec<String> = checks
        .iter()
        .map(|check| {
            let present = format!("anchor.present({})", slot_expression(&check.item));
            match guard_condition(&check.guards) {
                Some(condition) => format!("(!{} || {present})", parenthesized(&condition)),
                None => present,
            }
        })
        .collect();
    let present = if checks.is_empty() {
        "true".to_string()
    } else {
        checks.join(" && ")
    };
    kdoc(
        writer,
        "Whether the deferred part that carries this fragment has arrived.",
    );
    writer.line(format!(
        "fun isPresent(anchor: Anchor): Boolean = {present}"
    ));
}

/// Writes what `body` writes inside `if` the guards select, or as it is
/// when nothing guards it.
fn guarded(writer: &mut Writer, guards: &[Vec<Guard>], body: impl FnOnce(&mut Writer)) {
    match guard_condition(guards) {
        Some(condition) => writer.block(format!("if ({condition})"), body),
        None => body(writer),
    }
}

/// `condition` in parentheses unless it is one call or already in them.
fn parenthesized(condition: &str) -> String {
    let simple =
        !condition.contains(' ') || (condition.starts_with('(') && condition.ends_with(')'));
    if simple {
        condition.to_string()
    } else {
        format!("({condition})")
    }
}

/// A slot as a value: the static slot, or on an interface or union the
/// abstract slot taken on the record's type. A key with variables is
/// resolved by the anchor's owner, once.
fn slot_expression(access: &SlotAccess) -> String {
    let slot = &access.slot;
    let path = |family: &str| {
        format!(
            "{family}.{}.{}",
            slot_name(&slot.type_name),
            slot_member(slot)
        )
    };
    match (access.on_record_type, slot.has_variables()) {
        (false, false) => path("Slots"),
        (false, true) => format!("anchor.owner.slot({})", path("Slots")),
        (true, false) => format!("{}.on(anchor.record.type)", path("AbstractSlots")),
        (true, true) => format!(
            "anchor.owner.slot({}, on = anchor.record.type)",
            path("Slots")
        ),
    }
}

/// The Kotlin test of a record against a type condition.
fn type_test(test: &TypeTest) -> String {
    match test {
        TypeTest::Is(type_name) => {
            format!("anchor.record.type == {}", type_reference(type_name))
        }
        TypeTest::InSet { condition, .. } => format!(
            "Types.{}.includes(anchor.record.type)",
            possible_types(condition)
        ),
    }
}

/// The Kotlin test of a member's guards, or none when it is always fetched.
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
