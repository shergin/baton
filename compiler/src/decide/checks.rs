//! The checks a lens may carry: `satisfied` and `missingRequiredField` for
//! the `@required` fields that bubble, `fieldErrors` under an error policy
//! or for a catch, and `isPresent` for a deferred spread.

use super::lens::{
    ErrorCheck, ErrorLine, Guarded, ReaderPlan, SatisfiedCheck, SlotAccess, host_type,
};
use super::members::{Member, collects_errors, condition_lens, own_members};
use crate::naming::Naming;
use crate::pipeline::{RequiredAction, SelectionPlan, TypePlan};

/// Marks `lens` to report the path of its first missing `@required` field,
/// and the lenses its `satisfied` recurses into, which report the paths
/// below it.
pub(super) fn report_missing(lens: &mut ReaderPlan) {
    lens.reports_missing = true;
    let targets: Vec<String> = lens
        .satisfied
        .iter()
        .flatten()
        .filter_map(|entry| match &entry.item {
            Some(SatisfiedCheck::Linked { lens: target, .. }) => Some(target.clone()),
            _ => None,
        })
        .collect();
    for child in &mut lens.nested {
        if targets.contains(&child.name) {
            report_missing(child);
        }
    }
}

/// `satisfied`: whether every `@required` field (NONE or LOG) of the
/// selection is present, recursing into required links. Relay nulls the
/// enclosing object otherwise; here the parent's accessor returns nil. A
/// field a condition left out cannot null the lens.
pub(super) fn satisfied(
    type_name: &str,
    type_is_abstract: bool,
    members: &[Member],
    naming: &dyn Naming,
) -> Vec<Guarded<Option<SatisfiedCheck>>> {
    own_members(members)
        .map(|member| {
            let check = match &member.selection {
                // A mapped scalar is present when its text converts: a value
                // the type cannot hold nulls the lens as a null would.
                SelectionPlan::Scalar {
                    required: Some(required),
                    storage_key,
                    type_:
                        TypePlan::Named {
                            name: scalar,
                            mapped: true,
                            ..
                        },
                    ..
                } if required.action != RequiredAction::Throw => Some(SatisfiedCheck::Converts {
                    slot: SlotAccess::of(type_name, type_is_abstract, storage_key),
                    path: required.path.clone(),
                    log: required.action == RequiredAction::Log,
                    swift_type: host_type(scalar, naming),
                }),
                SelectionPlan::Scalar {
                    required: Some(required),
                    storage_key,
                    ..
                } if required.action != RequiredAction::Throw => Some(SatisfiedCheck::HasValue {
                    slot: SlotAccess::of(type_name, type_is_abstract, storage_key),
                    path: required.path.clone(),
                    log: required.action == RequiredAction::Log,
                }),
                SelectionPlan::Linked {
                    required: Some(required),
                    storage_key,
                    type_,
                    bubbles,
                    ..
                } if required.action != RequiredAction::Throw => {
                    let slot = SlotAccess::of(type_name, type_is_abstract, storage_key);
                    let path = required.path.clone();
                    let log = required.action == RequiredAction::Log;
                    if type_.is_list() || !*bubbles {
                        Some(SatisfiedCheck::HasValue { slot, path, log })
                    } else {
                        Some(SatisfiedCheck::Linked {
                            slot,
                            lens: member.lens_name().to_string(),
                            path,
                            log,
                        })
                    }
                }
                _ => None,
            };
            Guarded {
                guards: member.guards.clone(),
                item: check,
            }
        })
        .collect()
}

/// `fieldErrors`: the field errors in this selection, excluding fields
/// caught by their own `@catch`, plus the `@required(action: THROW)` fields
/// that are null. A field a condition left out has no error to collect.
pub(super) fn field_errors(
    type_name: &str,
    type_is_abstract: bool,
    members: &[Member],
    response_path: &str,
    naming: &dyn Naming,
) -> Vec<ErrorCheck> {
    let mut checks = Vec::new();
    for member in members {
        // A type condition's nested lens: its errors count when the record
        // satisfies the condition.
        if let SelectionPlan::Inline {
            alias: None,
            type_condition,
            condition_class,
            ..
        } = &member.selection
        {
            if let Some((_, _, test)) = condition_lens(type_condition, condition_class, member) {
                checks.push(ErrorCheck::Condition {
                    guards: member.guards.clone(),
                    test,
                    lens: member.lens_name().to_string(),
                });
            }
            continue;
        }
        if !collects_errors(&member.selection) {
            continue;
        }
        let mut lines = Vec::new();
        match &member.selection {
            SelectionPlan::Scalar {
                storage_key,
                required,
                type_,
                name,
                alias,
                ..
            } => {
                let slot = SlotAccess::of(type_name, type_is_abstract, storage_key);
                lines.push(ErrorLine::Field(slot.clone()));
                if let Some(required) = required
                    && required.action == RequiredAction::Throw
                {
                    lines.push(ErrorLine::Required {
                        slot: slot.clone(),
                        path: required.path.clone(),
                    });
                }
                // A mapped scalar whose text does not convert is an error
                // the policy handles, under the field's own path. A list
                // keeps the list rule: an element that does not convert is
                // reported and left out.
                if type_.is_mapped() && !type_.is_list() {
                    lines.push(ErrorLine::Converts {
                        slot,
                        path: format!("{response_path}{}", alias.as_deref().unwrap_or(name)),
                        swift_type: host_type(type_.base_name(), naming),
                    });
                }
            }
            SelectionPlan::Linked {
                storage_key,
                required,
                type_,
                ..
            } => {
                let slot = SlotAccess::of(type_name, type_is_abstract, storage_key);
                let lens = member.lens_name().to_string();
                lines.push(if type_.is_list() {
                    ErrorLine::List {
                        slot: slot.clone(),
                        lens,
                    }
                } else {
                    ErrorLine::Linked {
                        slot: slot.clone(),
                        lens,
                    }
                });
                if let Some(required) = required
                    && required.action == RequiredAction::Throw
                {
                    lines.push(ErrorLine::Required {
                        slot,
                        path: required.path.clone(),
                    });
                }
            }
            SelectionPlan::Inline { alias: Some(_), .. } => {
                lines.push(ErrorLine::Nested(member.lens_name().to_string()));
            }
            _ => {}
        }
        checks.push(ErrorCheck::Member(Guarded {
            guards: member.guards.clone(),
            item: lines,
        }));
    }
    checks
}

/// `isPresent`: whether the fragment's own fields have arrived, for a
/// spread under `@defer`. A field a condition left out is not waited for.
pub(super) fn is_present(
    type_name: &str,
    type_is_abstract: bool,
    members: &[Member],
) -> Vec<Guarded<SlotAccess>> {
    own_members(members)
        .filter_map(|member| {
            let storage_key = match &member.selection {
                SelectionPlan::Scalar {
                    name, storage_key, ..
                } if name != "__typename" => storage_key,
                SelectionPlan::Linked { storage_key, .. } => storage_key,
                _ => return None,
            };
            Some(Guarded {
                guards: member.guards.clone(),
                item: SlotAccess::of(type_name, type_is_abstract, storage_key),
            })
        })
        .collect()
}
