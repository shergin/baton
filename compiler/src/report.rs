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

use crate::decide::{LinkedForm, Program, Read, ReaderPlan, ScalarForm, SpreadForm, TypeTest};
use crate::pipeline::{FragmentPlan, OperationKind, Plan, SelectionPlan, TypePlan};

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// The schema's digest, as `Types.schemaDigest` names it.
    pub schema_digest: String,
    pub operations: Vec<OperationReport>,
    pub fragments: Vec<FragmentReport>,
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
    /// The text the operation is sent as, or registered under its id.
    pub text: String,
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
    /// what a dependent target's compilation would read.
    pub text: String,
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
            lens: None,
        })
        .collect();
    operations.sort_by(|left, right| left.name.cmp(&right.name));
    let mut fragments: Vec<FragmentReport> = plan
        .fragments
        .iter()
        .map(|fragment| FragmentReport {
            name: fragment.name.clone(),
            type_condition: fragment.type_condition.clone(),
            source: relative(&fragment.source, root),
            operations: reaching
                .get(fragment.name.as_str())
                .map(|operations| operations.iter().cloned().collect())
                .unwrap_or_default(),
            text: fragment.text.clone(),
            lens: None,
        })
        .collect();
    fragments.sort_by(|left, right| left.name.cmp(&right.name));
    Report {
        schema_digest: plan.schema_digest.clone(),
        operations,
        fragments,
    }
}

/// The report as `generate` writes it: pretty JSON ending in a newline,
/// with every lens of `program`.
pub fn text(plan: &Plan, root: &Path, program: &Program) -> String {
    let mut report = report(plan, root);
    with_lenses(&mut report, program);
    let mut text = serde_json::to_string_pretty(&report).unwrap_or_default();
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
