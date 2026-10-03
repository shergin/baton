//! The decide pass: what the emitters print, decided from the lowered plan.
//!
//! A normalization selection becomes one list of fields per group of concrete
//! types that read the same fields, plus a list for any other type, and each
//! field carries the `@include` and `@skip` conditions it is fetched under as
//! guards. The runtime settles the guards once per set of variables and the
//! variant once per record, then walks plain lists: nothing tests a type
//! condition or a condition per field.

use crate::pipeline::{
    ConnectionPlan, HandlePlan, LookupPlan, SelectionPlan, StorageKeyPlan, TypeKind,
};

/// A selection set on one type, as the normalization walks it.
#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationSelection {
    pub type_name: String,
    pub has_id: bool,
    /// Whether the type is an interface or union: the payload's `__typename`
    /// names each record's type.
    pub is_abstract: bool,
    /// One variant for an object type; for an abstract type, one per group
    /// of concrete types that read the same fields, then the one that
    /// serves every other type.
    pub variants: Vec<NormalizationVariant>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationVariant {
    /// The concrete types this variant serves; `None` serves every other type.
    pub types: Option<Vec<String>>,
    pub fields: Vec<NormalizationField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationField {
    pub response_key: String,
    pub key: StorageKeyPlan,
    /// Alternatives of conjunctions: the field is selected when any
    /// alternative holds. Empty when it is always selected.
    pub guards: Vec<Vec<Guard>>,
    /// The `@defer` label of the part that carries the field.
    pub deferred: Option<String>,
    /// Whether an error on the field is handled by a `@catch`.
    pub caught: bool,
    pub handle: Option<HandlePlan>,
    pub kind: NormalizationKind,
}

/// Built once per compilation and read by the emitter, so the size
/// difference between a scalar and a linked field is of no account.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum NormalizationKind {
    Scalar {
        base_kind: TypeKind,
        list: bool,
    },
    Linked {
        plural: bool,
        lookup: Option<LookupPlan>,
        connection: Option<ConnectionPlan>,
        selection: NormalizationSelection,
    },
}

/// One condition of a guard: the variable and the value that selects.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Guard {
    pub variable: String,
    pub passing: bool,
}

/// The normalization selection of an operation, from its root type.
pub fn normalization(root_type: &str, selections: &[SelectionPlan]) -> NormalizationSelection {
    let mut occurrences = Vec::new();
    collect(selections, root_type, &[], None, None, &mut occurrences);
    decide(root_type, false, false, &[], &occurrences)
}

/// A field as one place in the document selects it: under which conditions,
/// for which of the parent's concrete types, in which deferred part.
#[derive(Clone)]
struct Occurrence<'a> {
    selection: &'a SelectionPlan,
    guard: Vec<Guard>,
    /// `None`: every type the parent admits.
    types: Option<Vec<String>>,
    deferred: Option<String>,
}

/// The fields a selection set selects at its own level, through inline
/// fragments and conditions; spreads were inlined by the compiler already.
fn collect<'a>(
    selections: &'a [SelectionPlan],
    parent_type: &str,
    guard: &[Guard],
    types: Option<&[String]>,
    deferred: Option<&str>,
    into: &mut Vec<Occurrence<'a>>,
) {
    for selection in selections {
        match selection {
            SelectionPlan::Scalar { .. } | SelectionPlan::Linked { .. } => into.push(Occurrence {
                selection,
                guard: guard.to_vec(),
                types: types.map(<[String]>::to_vec),
                deferred: deferred.map(str::to_string),
            }),
            SelectionPlan::Inline {
                type_condition,
                condition_types,
                deferred: label,
                selections: child,
                ..
            } => {
                // A condition on the parent's own type restricts nothing.
                let restriction = match (type_condition, condition_types) {
                    (Some(condition), Some(condition_types)) if condition != parent_type => {
                        Some(match types {
                            Some(types) => types
                                .iter()
                                .filter(|type_name| condition_types.contains(type_name))
                                .cloned()
                                .collect(),
                            None => condition_types.clone(),
                        })
                    }
                    _ => types.map(<[String]>::to_vec),
                };
                collect(
                    child,
                    parent_type,
                    guard,
                    restriction.as_deref(),
                    label.as_deref().or(deferred),
                    into,
                );
            }
            SelectionPlan::Condition {
                variable,
                passing,
                selections: child,
            } => {
                let mut inner = guard.to_vec();
                // A constant condition is settled by Relay's transforms
                // before lowering; what reaches here always holds.
                if let Some(variable) = variable {
                    inner.push(Guard {
                        variable: variable.clone(),
                        passing: *passing,
                    });
                }
                collect(child, parent_type, &inner, types, deferred, into);
            }
            SelectionPlan::Spread { .. } => {}
        }
    }
}

/// A selection from the occurrences of its fields. On an abstract type, each
/// concrete type the type admits reads the fields selected on the abstract
/// type and those under type conditions it satisfies; types that read the
/// same list share a variant, and types that read only the abstract type's
/// own fields are served by the variant for every other type.
fn decide(
    type_name: &str,
    has_id: bool,
    is_abstract: bool,
    possible_types: &[String],
    occurrences: &[Occurrence],
) -> NormalizationSelection {
    if !is_abstract {
        let all: Vec<&Occurrence> = occurrences.iter().collect();
        return NormalizationSelection {
            type_name: type_name.to_string(),
            has_id,
            is_abstract,
            variants: vec![NormalizationVariant {
                types: None,
                fields: merge(&all),
            }],
        };
    }
    let own: Vec<&Occurrence> = occurrences
        .iter()
        .filter(|occurrence| occurrence.types.is_none())
        .collect();
    let others = merge(&own);
    let mut groups: Vec<(Vec<String>, Vec<NormalizationField>)> = Vec::new();
    for concrete in possible_types {
        let applicable: Vec<&Occurrence> = occurrences
            .iter()
            .filter(|occurrence| {
                occurrence
                    .types
                    .as_ref()
                    .is_none_or(|types| types.contains(concrete))
            })
            .collect();
        if applicable.len() == own.len() {
            continue;
        }
        let fields = merge(&applicable);
        if fields == others {
            continue;
        }
        match groups.iter_mut().find(|(_, existing)| *existing == fields) {
            Some((types, _)) => types.push(concrete.clone()),
            None => groups.push((vec![concrete.clone()], fields)),
        }
    }
    let mut variants: Vec<NormalizationVariant> = groups
        .into_iter()
        .map(|(types, fields)| NormalizationVariant {
            types: Some(types),
            fields,
        })
        .collect();
    variants.push(NormalizationVariant {
        types: None,
        fields: others,
    });
    NormalizationSelection {
        type_name: type_name.to_string(),
        has_id,
        is_abstract,
        variants,
    }
}

/// One field per response key and deferred part, in the order of first
/// selection, with `__typename` first. Occurrences of a field are selected
/// when any of them is; the child selections of a linked field merge, each
/// child carrying the conditions of the occurrence that selected it when
/// the occurrences differ. Relay's `__isX: __typename` fields record type
/// membership, which the variants already decide, and are dropped.
fn merge(occurrences: &[&Occurrence]) -> Vec<NormalizationField> {
    let mut groups: Vec<(String, Option<String>, Vec<&Occurrence>)> = Vec::new();
    for occurrence in occurrences {
        let response_key = response_key(occurrence.selection);
        if is_type_membership(occurrence.selection) {
            continue;
        }
        match groups
            .iter_mut()
            .find(|(key, deferred, _)| *key == response_key && *deferred == occurrence.deferred)
        {
            Some((_, _, members)) => members.push(occurrence),
            None => groups.push((response_key, occurrence.deferred.clone(), vec![occurrence])),
        }
    }
    let mut fields: Vec<NormalizationField> = groups
        .into_iter()
        .map(|(response_key, deferred, members)| field(response_key, deferred, &members))
        .collect();
    if let Some(position) = fields
        .iter()
        .position(|field| field.response_key == "__typename")
    {
        let typename = fields.remove(position);
        fields.insert(0, typename);
    }
    fields
}

fn field(
    response_key: String,
    deferred: Option<String>,
    members: &[&Occurrence],
) -> NormalizationField {
    let guards = any(members.iter().map(|member| member.guard.clone()).collect());
    let caught = members.iter().all(|member| caught(member.selection));
    let handle = members.iter().find_map(|member| handle(member.selection));
    match members[0].selection {
        SelectionPlan::Scalar {
            storage_key,
            base_kind,
            list,
            ..
        } => NormalizationField {
            response_key,
            key: storage_key.clone(),
            guards,
            deferred,
            caught,
            handle,
            kind: NormalizationKind::Scalar {
                base_kind: *base_kind,
                list: *list,
            },
        },
        SelectionPlan::Linked {
            storage_key,
            base_type,
            plural,
            has_id,
            is_abstract,
            possible_types,
            lookup,
            connection,
            ..
        } => {
            let differ = members
                .iter()
                .any(|member| member.guard != members[0].guard);
            let mut children = Vec::new();
            for member in members {
                let SelectionPlan::Linked { selections, .. } = member.selection else {
                    continue;
                };
                let guard: &[Guard] = if differ { &member.guard } else { &[] };
                collect(selections, base_type, guard, None, None, &mut children);
            }
            NormalizationField {
                response_key,
                key: storage_key.clone(),
                guards,
                deferred,
                caught,
                handle,
                kind: NormalizationKind::Linked {
                    plural: *plural,
                    lookup: lookup.clone(),
                    connection: connection.clone(),
                    selection: decide(base_type, *has_id, *is_abstract, possible_types, &children),
                },
            }
        }
        _ => unreachable!("occurrences are fields"),
    }
}

/// The disjunction of conjunctions, simplified: a conjunction that holds
/// always makes the whole always (empty), a contradictory one is dropped,
/// and repeats go.
fn any(conjunctions: Vec<Vec<Guard>>) -> Vec<Vec<Guard>> {
    let mut alternatives: Vec<Vec<Guard>> = Vec::new();
    for mut conjunction in conjunctions {
        conjunction.sort();
        conjunction.dedup();
        let contradictory = conjunction
            .windows(2)
            .any(|pair| pair[0].variable == pair[1].variable);
        if contradictory {
            continue;
        }
        if conjunction.is_empty() {
            return Vec::new();
        }
        if !alternatives.contains(&conjunction) {
            alternatives.push(conjunction);
        }
    }
    alternatives
}

fn response_key(selection: &SelectionPlan) -> String {
    match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            alias.clone().unwrap_or_else(|| name.clone())
        }
        _ => unreachable!("occurrences are fields"),
    }
}

fn is_type_membership(selection: &SelectionPlan) -> bool {
    matches!(selection, SelectionPlan::Scalar { name, alias: Some(alias), .. }
        if name == "__typename" && alias.starts_with("__is"))
}

fn caught(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { caught, .. } | SelectionPlan::Linked { caught, .. } => *caught,
        _ => false,
    }
}

fn handle(selection: &SelectionPlan) -> Option<HandlePlan> {
    match selection {
        SelectionPlan::Scalar { handle, .. } | SelectionPlan::Linked { handle, .. } => {
            handle.clone()
        }
        _ => None,
    }
}

#[cfg(test)]
#[path = "tests/decide_tests.rs"]
mod tests;
