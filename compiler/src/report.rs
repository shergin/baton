//! The report `generate` writes for one target: what the compiler compiled,
//! for the people who register operations and review contract changes, and
//! the facts a dependent target's compilation would read. Deterministic:
//! operations and fragments by name, sources relative to the working
//! directory, so two builds over the same sources write the same bytes and
//! the diff of two reports is the contract's change. A report written after
//! the decide pass also holds each lens as the target's language reads it:
//! every accessor's name, the response key it reads and its shape.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::decide::{
    LinkedForm, Program, Read, ReaderPlan, ScalarForm, SlotRef, SpreadForm, TypeTest,
};
use crate::pipeline::{FragmentPlan, OperationKind, Plan, SelectionPlan, TypePlan};

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// The format of the head and the fragments, which a compilation that
    /// reads the report as a base checks.
    pub format: u32,
    /// The schema's digest, as `Types.schemaDigest` names it.
    pub schema_digest: String,
    /// Where the target's generated code is declared: the Swift module
    /// `--module` named, where a dependent target imports its lenses from,
    /// or the Kotlin package of its shared file, which no target that
    /// depends on it may share.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    pub operations: Vec<OperationReport>,
    pub fragments: Vec<FragmentReport>,
}

/// Where a target's generated code is declared: the Swift module, which
/// only its build knows, or the Kotlin package of its shared file, and for
/// Kotlin the package of each fragment's lens, by the fragment's name.
#[derive(Debug, Default)]
pub struct Home {
    pub module: Option<String>,
    pub packages: BTreeMap<String, String>,
}

/// A report's head and its fragments alone: what a dependent target reads
/// of its base, written apart so that a build reruns the dependent only
/// when the base's fragments change, and not with each of its operations.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Fragments<'a> {
    format: u32,
    schema_digest: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    module: Option<&'a str>,
    fragments: Vec<FragmentEntry<'a>>,
}

#[derive(Debug, serde::Serialize)]
struct FragmentEntry<'a> {
    name: &'a str,
    #[serde(rename = "type")]
    type_condition: &'a str,
    source: &'a str,
    text: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    package: Option<&'a str>,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationReport {
    pub name: String,
    pub kind: OperationKind,
    pub source: String,
    /// The id the operation is sent by, under `persistConfig`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub variables: Vec<VariableReport>,
    /// Every fragment the operation reaches, directly or through another.
    pub fragments: Vec<String>,
    /// The text the operation is sent as, or registered under its id; a
    /// client-only query's is the document as the author wrote it.
    pub text: String,
    /// A query of client fields alone, never sent.
    #[serde(skip_serializing_if = "is_false")]
    pub client_only: bool,
    /// The lens its data reads through, once the program is decided.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lens: Option<LensReport>,
}

#[derive(Debug, serde::Serialize)]
pub struct VariableReport {
    pub name: String,
    /// The type as the schema writes it, `[ID!]!` for one.
    #[serde(rename = "type")]
    pub type_: String,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FragmentReport {
    pub name: String,
    #[serde(rename = "type")]
    pub type_condition: String,
    pub source: String,
    /// Every operation that reaches the fragment; none says no operation
    /// spreads it.
    pub operations: Vec<String>,
    /// The definition as the author wrote it, printed before the transforms,
    /// what a dependent target's compilation reads.
    pub text: String,
    /// The Kotlin package the fragment's lens is declared in, when it has
    /// one: where a dependent target imports the lens from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub package: Option<String>,
    /// The fragment's lens, once the program is decided.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lens: Option<LensReport>,
}

/// A lens as the target's language reads it: the GraphQL type it reads and
/// its accessors, in order.
#[derive(Debug, serde::Serialize)]
pub struct LensReport {
    #[serde(rename = "type")]
    pub type_name: String,
    pub accessors: Vec<AccessorReport>,
}

/// One accessor of a lens and the shape it reads as.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessorReport {
    /// The accessor's name, as the target's language spells it unescaped.
    pub name: String,
    /// The response key it reads under; none for a spread or a type
    /// condition, which read their parent's object.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// The schema coordinate of the field it reads, `Type.field`, the
    /// schema's name under an alias; none for a spread, an inline fragment
    /// under `@alias` or a type condition.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coordinate: Option<String>,
    pub read: ReadKind,
    /// Whether it may read absent: a nullable field, a selection under
    /// `@include` or `@skip`, a type condition, a spread something must hold
    /// for.
    #[serde(skip_serializing_if = "is_false")]
    pub optional: bool,
    /// `@catch`: it reads a result of its value or the field errors.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caught: Option<CaughtReport>,
    /// `@required(action: THROW)` or a `@throwOnFieldError` fragment: the
    /// read throws.
    #[serde(skip_serializing_if = "is_false")]
    pub throws: bool,
    /// A plural field.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub list: Option<ListReport>,
    /// The fragment a spread reads.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fragment: Option<String>,
    /// The concrete types a type condition reads for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub types: Option<Vec<String>>,
    /// The nested lens a link, an aliased selection or a type condition
    /// reads.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lens: Option<Box<LensReport>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadKind {
    Scalar,
    Linked,
    Spread,
    Aliased,
    Condition,
}

/// The success of a `@catch` result: whether its value may be absent.
#[derive(Debug, serde::Serialize)]
pub struct CaughtReport {
    pub optional: bool,
}

/// A plural field's elements: whether one may be absent. A list of links
/// drops its null elements, so only a scalar list has absent ones.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListReport {
    pub optional_elements: bool,
}

fn is_false(value: &bool) -> bool {
    !value
}

/// The report of `plan`, its sources named from `root`.
pub fn report(plan: &Plan, root: &Path) -> Report {
    let reached = reach(plan);
    let mut reaching: BTreeMap<&str, BTreeSet<String>> = BTreeMap::new();
    for (operation, fragments) in &reached {
        for fragment in fragments {
            reaching
                .entry(fragment.as_str())
                .or_default()
                .insert(operation.clone());
        }
    }
    let mut operations: Vec<OperationReport> = plan
        .operations
        .iter()
        .map(|operation| OperationReport {
            name: operation.name.clone(),
            kind: operation.kind,
            source: relative(&operation.source, root),
            id: operation.id.clone(),
            variables: operation
                .variables
                .iter()
                .map(|variable| VariableReport {
                    name: variable.name.clone(),
                    type_: type_text(&variable.type_),
                })
                .collect(),
            fragments: reached
                .get(&operation.name)
                .map(|fragments| fragments.iter().cloned().collect())
                .unwrap_or_default(),
            text: operation.text.clone(),
            client_only: operation.client_only,
            lens: None,
        })
        .collect();
    operations.sort_by(|left, right| left.name.cmp(&right.name));
    // A base's fragments are in the base's report, their home, and an
    // operation's reach names them all the same.
    let mut fragments: Vec<FragmentReport> = plan
        .own_fragments()
        .map(|fragment| FragmentReport {
            name: fragment.name.clone(),
            type_condition: fragment.type_condition.clone(),
            source: relative(&fragment.source, root),
            operations: reaching
                .get(fragment.name.as_str())
                .map(|operations| operations.iter().cloned().collect())
                .unwrap_or_default(),
            text: fragment.text.clone(),
            package: None,
            lens: None,
        })
        .collect();
    fragments.sort_by(|left, right| left.name.cmp(&right.name));
    Report {
        format: crate::base::FORMAT,
        schema_digest: plan.schema_digest.clone(),
        module: None,
        operations,
        fragments,
    }
}

/// States in `report` where the target's lenses are declared.
pub fn with_home(report: &mut Report, home: &Home) {
    report.module = home.module.clone();
    for fragment in &mut report.fragments {
        fragment.package = home.packages.get(&fragment.name).cloned();
    }
}

/// The report as `generate` writes it: pretty JSON ending in a newline,
/// with every lens of `program` and where `home` says they are declared.
pub fn text(plan: &Plan, root: &Path, program: &Program, home: &Home) -> String {
    let mut report = report(plan, root);
    with_lenses(&mut report, program);
    with_home(&mut report, home);
    let mut text = serde_json::to_string_pretty(&report).unwrap_or_default();
    text.push('\n');
    text
}

/// The fragments file as `generate --fragments` writes it: the report's
/// head and, of each fragment, what a dependent target reads.
pub fn fragments_text(plan: &Plan, root: &Path, home: &Home) -> String {
    let mut report = report(plan, root);
    with_home(&mut report, home);
    let fragments = Fragments {
        format: report.format,
        schema_digest: &report.schema_digest,
        module: report.module.as_deref(),
        fragments: report
            .fragments
            .iter()
            .map(|fragment| FragmentEntry {
                name: &fragment.name,
                type_condition: &fragment.type_condition,
                source: &fragment.source,
                text: &fragment.text,
                package: fragment.package.as_deref(),
            })
            .collect(),
    };
    let mut text = serde_json::to_string_pretty(&fragments).unwrap_or_default();
    text.push('\n');
    text
}

/// Adds to `report` the lens of every operation and fragment `program`
/// decided.
pub fn with_lenses(report: &mut Report, program: &Program) {
    for operation in &mut report.operations {
        operation.lens = program
            .operations
            .iter()
            .find(|decided| decided.name == operation.name)
            .map(|decided| lens_report(&decided.data));
    }
    for fragment in &mut report.fragments {
        fragment.lens = program
            .fragments
            .iter()
            .find(|decided| decided.name == fragment.name)
            .map(|decided| lens_report(&decided.lens));
    }
}

/// The schema coordinate of the field `slot` stores, `Type.field`.
fn coordinate(slot: &SlotRef) -> String {
    format!("{}.{}", slot.type_name, slot.field)
}

/// A lens and the lenses nested in it, by the shapes the emitters print:
/// guards make an accessor optional, `@catch` makes it a result, and the
/// throwing forms make its read throw. A mapped scalar converts at the
/// read, so `@required` makes it throw rather than read a zero.
fn lens_report(lens: &ReaderPlan) -> LensReport {
    let nested = |name: &str| {
        lens.nested
            .iter()
            .find(|child| child.name == name)
            .map(|child| Box::new(lens_report(child)))
    };
    let accessors = lens
        .accessors
        .iter()
        .map(|accessor| {
            let guarded = !accessor.guards.is_empty();
            let mut report = AccessorReport {
                name: accessor.name.clone(),
                key: accessor.key.clone(),
                coordinate: None,
                read: ReadKind::Scalar,
                optional: guarded,
                caught: None,
                throws: false,
                list: None,
                fragment: None,
                types: None,
                lens: None,
            };
            match &accessor.read {
                Read::Scalar(read) => {
                    report.coordinate = Some(coordinate(&read.slot.slot));
                    report.list = read.shape.list.map(|list| ListReport {
                        optional_elements: !list.non_null,
                    });
                    let mapped = read.shape.primitive.is_mapped() && read.shape.list.is_none();
                    match &read.form {
                        ScalarForm::Caught { non_null } => {
                            report.caught = Some(CaughtReport {
                                optional: !non_null,
                            })
                        }
                        ScalarForm::Nulled | ScalarForm::Optional => report.optional = true,
                        ScalarForm::Throwing { .. } => report.throws = true,
                        ScalarForm::Required => report.throws = mapped,
                    }
                }
                Read::Linked(read) => {
                    report.read = ReadKind::Linked;
                    report.coordinate = Some(coordinate(&read.slot.slot));
                    report.lens = nested(&read.lens);
                    let list = Some(ListReport {
                        optional_elements: false,
                    });
                    match &read.form {
                        LinkedForm::CaughtList { non_null } => {
                            report.list = list;
                            report.caught = Some(CaughtReport {
                                optional: !non_null,
                            });
                        }
                        LinkedForm::ThrowingList { .. } => {
                            report.list = list;
                            report.throws = true;
                        }
                        LinkedForm::RequiredList => report.list = list,
                        LinkedForm::List => {
                            report.list = list;
                            report.optional = true;
                        }
                        LinkedForm::Caught { optional } => {
                            report.caught = Some(CaughtReport {
                                optional: *optional,
                            })
                        }
                        LinkedForm::Throwing { .. } => report.throws = true,
                        LinkedForm::Optional => report.optional = true,
                        LinkedForm::Required => {}
                    }
                }
                Read::Spread(read) => {
                    report.read = ReadKind::Spread;
                    report.fragment = Some(read.fragment.clone());
                    // A spread's conditions are its own guards; the
                    // member's are folded into them.
                    let optional = !read.guards.is_empty();
                    report.optional = false;
                    match read.form {
                        SpreadForm::Caught => report.caught = Some(CaughtReport { optional }),
                        SpreadForm::Throwing => {
                            report.optional = optional;
                            report.throws = true;
                        }
                        SpreadForm::Plain => report.optional = optional,
                    }
                }
                Read::Aliased(read) => {
                    report.read = ReadKind::Aliased;
                    report.lens = nested(&read.lens);
                    report.optional = !read.guards.is_empty();
                    if read.caught {
                        report.caught = Some(CaughtReport { optional: false });
                    }
                }
                Read::Condition(read) => {
                    report.read = ReadKind::Condition;
                    report.lens = nested(&read.lens);
                    report.optional = true;
                    report.types = Some(match &read.test {
                        TypeTest::Is(type_name) => vec![type_name.clone()],
                        TypeTest::InSet { types, .. } => types.clone(),
                    });
                }
            }
            report
        })
        .collect();
    LensReport {
        type_name: lens.type_name.clone(),
        accessors,
    }
}

/// The fragments each operation reaches, by the spreads of its reader and of
/// every fragment reached in turn.
pub fn reach(plan: &Plan) -> BTreeMap<String, BTreeSet<String>> {
    let by_name: BTreeMap<&str, &FragmentPlan> = plan
        .fragments
        .iter()
        .map(|fragment| (fragment.name.as_str(), fragment))
        .collect();
    plan.operations
        .iter()
        .map(|operation| {
            let mut reached = BTreeSet::new();
            let mut pending = Vec::new();
            spreads(&operation.reader, &mut pending);
            while let Some(name) = pending.pop() {
                if !reached.insert(name.clone()) {
                    continue;
                }
                if let Some(fragment) = by_name.get(name.as_str()) {
                    spreads(&fragment.reader, &mut pending);
                }
            }
            (operation.name.clone(), reached)
        })
        .collect()
}

/// The fragments `selections` spread, at any depth.
fn spreads(selections: &[SelectionPlan], into: &mut Vec<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Spread { fragment, .. } => into.push(fragment.clone()),
            SelectionPlan::Linked { selections, .. }
            | SelectionPlan::Inline { selections, .. }
            | SelectionPlan::Condition { selections, .. } => spreads(selections, into),
            SelectionPlan::Scalar { .. } => {}
        }
    }
}

/// A type as the schema writes it.
fn type_text(type_: &TypePlan) -> String {
    let bang = |non_null: bool| if non_null { "!" } else { "" };
    match type_ {
        TypePlan::Named { name, non_null, .. } => format!("{name}{}", bang(*non_null)),
        TypePlan::List { element, non_null } => {
            format!("[{}]{}", type_text(element), bang(*non_null))
        }
    }
}

/// `source` relative to `root` when it lies under it, with forward slashes,
/// so the report does not depend on where the checkout sits.
fn relative(source: &str, root: &Path) -> String {
    let path = Path::new(source);
    let relative = path.strip_prefix(root).unwrap_or(path);
    relative
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            std::path::Component::ParentDir => Some("..".to_string()),
            std::path::Component::RootDir => Some(String::new()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
#[path = "tests/report_tests.rs"]
mod tests;
