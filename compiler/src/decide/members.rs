//! What a lens reads: its members, each field, spread and inline fragment
//! of its selection once, with the `@include` and `@skip` conditions it is
//! fetched under; and what the reader asks of a selection.

use std::collections::{BTreeMap, BTreeSet};

use super::lens::TypeTest;
use super::{Guard, any};
use crate::names::lower_camel;
use crate::pipeline::{ConditionClass, SelectionPlan};

/// One thing a lens reads, after its occurrences merged: a field, a spread
/// or an inline fragment, and the `@include` and `@skip` conditions it is
/// fetched under (empty: always).
pub(super) struct Member {
    /// The first occurrence; a linked field's or an inline fragment's
    /// selections are those of every occurrence.
    pub(super) selection: SelectionPlan,
    pub(super) guards: Vec<Vec<Guard>>,
    /// The accessor's name, unescaped, set by `name_lens` for every member
    /// that has one.
    pub(super) accessor: Option<String>,
    /// The nested lens a linked field, an aliased inline fragment or a type
    /// condition reads as, set by `name_lens`: the accessors and the checks
    /// that follow take it rather than deriving it again.
    pub(super) lens: Option<String>,
}

impl Member {
    pub(super) fn accessor_name(&self) -> &str {
        self.accessor
            .as_deref()
            .expect("`name_lens` names the accessor of every member that has one")
    }

    pub(super) fn lens_name(&self) -> &str {
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
pub(super) fn members(selections: &[SelectionPlan]) -> Vec<Member> {
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
            let guards = any(occurrences.iter().map(|(_, guard)| guard.clone()).collect());
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

/// The accessor a member's document spells, and what it is, for messages: a
/// field's response key, or an inline fragment's alias.
pub(super) fn written_accessor(selection: &SelectionPlan) -> Option<(String, String)> {
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
pub(super) fn derived_spread(selection: &SelectionPlan) -> Option<&str> {
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

/// The members a lens's own checks cover: its fields, and inline fragments
/// it names with an alias. Spreads and lenses on other types check
/// themselves.
pub(super) fn own_members(members: &[Member]) -> impl Iterator<Item = &Member> {
    members.iter().filter(|member| match &member.selection {
        SelectionPlan::Scalar { .. } | SelectionPlan::Linked { .. } => true,
        SelectionPlan::Inline { alias, .. } => alias.is_some(),
        _ => false,
    })
}

/// Whether a member has field errors its lens collects. `__typename` has
/// none, a `@catch` field keeps its own, and an aliased spread is a masking
/// boundary with its own policy; an aliased selection set is a nested lens
/// whose errors are this lens's.
pub(super) fn collects_errors(selection: &SelectionPlan) -> bool {
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

/// A type condition some of the parent's types satisfy reads as an
/// optional nested lens: on the one type that can, or through the abstract
/// type's keys when several can. The lens's type and whether it is
/// abstract, and the test of the record.
pub(super) fn condition_lens(
    type_condition: &Option<String>,
    condition_class: &Option<ConditionClass>,
    member: &Member,
) -> Option<(String, bool, TypeTest)> {
    match (type_condition, condition_class) {
        (Some(_), Some(ConditionClass::Concrete(concrete))) => {
            Some((concrete.clone(), false, TypeTest::Is(concrete.clone())))
        }
        (Some(condition), Some(ConditionClass::Set)) => {
            let SelectionPlan::Inline {
                condition_types: Some(types),
                ..
            } = &member.selection
            else {
                unreachable!("a set condition has its possible types");
            };
            Some((
                condition.clone(),
                true,
                TypeTest::InSet {
                    condition: condition.clone(),
                    types: types.clone(),
                },
            ))
        }
        _ => None,
    }
}

/// Whether a connection's lens gets `nodes`: it selects `edges { node }`
/// and no field `nodes` itself.
pub(super) fn selects_nodes(selections: &[SelectionPlan]) -> bool {
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
pub(super) fn spread_accessor_names(
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

/// The fragments spread under `@defer`, anywhere in a selection tree.
pub(super) fn collect_deferred(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
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
pub(super) fn collect_caught(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
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
