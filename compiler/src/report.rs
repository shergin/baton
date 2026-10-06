//! The report `generate` writes for one target: what the compiler compiled,
//! for the people who register operations and review contract changes, and
//! the facts a dependent target's compilation would read. Deterministic:
//! operations and fragments by name, sources relative to the working
//! directory, so two builds over the same sources write the same bytes and
//! the diff of two reports is the contract's change.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

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
        })
        .collect();
    fragments.sort_by(|left, right| left.name.cmp(&right.name));
    Report {
        schema_digest: plan.schema_digest.clone(),
        operations,
        fragments,
    }
}

/// The report as `generate` writes it: pretty JSON ending in a newline.
pub fn text(plan: &Plan, root: &Path) -> String {
    let mut text = serde_json::to_string_pretty(&report(plan, root)).unwrap_or_default();
    text.push('\n');
    text
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
