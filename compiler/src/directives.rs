//! What a document may say: the directives Baton gives a meaning to, where
//! it gives it, and one definition of the marker's own kind per marker.
//! Relay's transforms accept more, and some of it, such as
//! `@relay(plural:)`, compiles and then does nothing; here it is an error
//! at the directive.

use std::collections::{BTreeMap, BTreeSet};

use common::{Diagnostic, Location, SourceLocationKey};
use graphql_syntax::{
    Argument, ConstantValue, Directive, ExecutableDefinition, FragmentDefinition, FragmentSpread,
    List, OperationDefinition, OperationKind, Selection, Value,
};
use intern::Lookup;

use crate::documents::Marker;

/// The directives each place takes. A query also states its cache
/// expiration, the first directive that is not Relay's
/// (`docs/decisions/an-operation-states-its-expiration.md`), and a mutation
/// names the records it deletes, the second
/// (`docs/decisions/a-mutation-names-the-record-it-deletes.md`).
const QUERY: &[&str] = &["throwOnFieldError", "cacheExpiration"];
const MUTATION: &[&str] = &["throwOnFieldError", "deletes"];
const SUBSCRIPTION: &[&str] = &["throwOnFieldError"];
const FRAGMENT: &[&str] = &[
    "argumentDefinitions",
    "refetchable",
    "throwOnFieldError",
    "inline",
];
const FIELD: &[&str] = &[
    "include",
    "skip",
    "required",
    "catch",
    "connection",
    "appendEdge",
    "prependEdge",
    "appendNode",
    "prependNode",
    "deleteEdge",
    "deleteRecord",
    "stream",
    "stream_connection",
];
const INLINE_FRAGMENT: &[&str] = &["include", "skip", "defer", "alias", "catch"];
const SPREAD: &[&str] = &["include", "skip", "defer", "arguments", "alias", "catch"];

/// The errors in one document: directives in places Baton gives them no
/// meaning, and a marker that does not hold exactly one definition of its
/// own kind.
pub fn check(
    definitions: &[ExecutableDefinition],
    key: SourceLocationKey,
    marker: Option<Marker>,
) -> Vec<Diagnostic> {
    let mut errors = Vec::new();
    for definition in definitions {
        match definition {
            ExecutableDefinition::Operation(operation) => {
                let (allowed, place) = match operation.operation_kind() {
                    OperationKind::Query => (QUERY, "a query"),
                    OperationKind::Mutation => (MUTATION, "a mutation"),
                    OperationKind::Subscription => (SUBSCRIPTION, "a subscription"),
                };
                directives(&operation.directives, allowed, place, key, &mut errors);
                walk(&operation.selections.items, key, &mut errors);
            }
            ExecutableDefinition::Fragment(fragment) => {
                directives(
                    &fragment.directives,
                    FRAGMENT,
                    "a fragment definition",
                    key,
                    &mut errors,
                );
                walk(&fragment.selections.items, key, &mut errors);
            }
        }
    }
    if let Some(marker) = marker {
        let own = definitions
            .iter()
            .filter(|definition| kind(definition) == marker)
            .count();
        if own != 1 || definitions.len() != 1 {
            let location = definitions
                .first()
                .map(|definition| match definition {
                    ExecutableDefinition::Operation(operation) => operation.location,
                    ExecutableDefinition::Fragment(fragment) => fragment.location,
                })
                .unwrap_or_else(|| Location::new(key, common::Span::new(0, 0)));
            errors.push(Diagnostic::error(
                format!(
                    "`@{}` holds {} definitions, {own} of them a {}: it takes exactly one {}",
                    marker_name(marker),
                    definitions.len(),
                    kind_name(marker),
                    kind_name(marker)
                ),
                location,
            ));
        }
    }
    errors
}

fn walk(selections: &[Selection], key: SourceLocationKey, errors: &mut Vec<Diagnostic>) {
    for selection in selections {
        match selection {
            Selection::ScalarField(field) => {
                directives(&field.directives, FIELD, "a field", key, errors);
            }
            Selection::LinkedField(field) => {
                directives(&field.directives, FIELD, "a field", key, errors);
                walk(&field.selections.items, key, errors);
            }
            Selection::InlineFragment(fragment) => {
                directives(
                    &fragment.directives,
                    INLINE_FRAGMENT,
                    "an inline fragment",
                    key,
                    errors,
                );
                walk(&fragment.selections.items, key, errors);
            }
            Selection::FragmentSpread(spread) => {
                directives(&spread.directives, SPREAD, "a fragment spread", key, errors);
            }
        }
    }
}

fn directives(
    directives: &[Directive],
    allowed: &[&str],
    place: &str,
    key: SourceLocationKey,
    errors: &mut Vec<Diagnostic>,
) {
    for directive in directives {
        let name = directive.name.value.lookup();
        if allowed.contains(&name) {
            continue;
        }
        let listed = allowed
            .iter()
            .map(|name| format!("`@{name}`"))
            .collect::<Vec<_>>()
            .join(", ");
        errors.push(Diagnostic::error(
            format!("`@{name}` on {place} has no meaning in Baton; {place} takes {listed}"),
            Location::new(key, directive.span),
        ));
    }
}

fn kind(definition: &ExecutableDefinition) -> Marker {
    match definition {
        ExecutableDefinition::Fragment(_) => Marker::Fragment,
        ExecutableDefinition::Operation(operation) => match operation.operation_kind() {
            OperationKind::Query => Marker::Query,
            OperationKind::Mutation => Marker::Mutation,
            OperationKind::Subscription => Marker::Subscription,
        },
    }
}

fn marker_name(marker: Marker) -> &'static str {
    match marker {
        Marker::Fragment => "Fragment",
        Marker::Query => "Query",
        Marker::Mutation => "Mutation",
        Marker::Subscription => "Subscription",
    }
}

fn kind_name(marker: Marker) -> &'static str {
    match marker {
        Marker::Fragment => "fragment",
        Marker::Query => "query",
        Marker::Mutation => "mutation",
        Marker::Subscription => "subscription",
    }
}

#[cfg(test)]
#[path = "tests/directives_tests.rs"]
mod tests;

/// `@deletes(type:id:)` on a mutation, as the author wrote it: the type's
/// name and the variable the record's key is passed as, each with where it
/// was written, for the lowering to check against the schema.
pub struct Deletes {
    pub type_name: String,
    pub type_location: Location,
    pub variable: String,
    pub variable_location: Location,
}

/// Takes every `@deletes` off the mutations in `definitions`, by operation
/// name, after checking its shape: `type` a string and `id` a variable.
/// Whether a field passes the variable is checked by `check_passes` once
/// every document is parsed, since the field may be in a fragment of
/// another document. The directive leaves the syntax here, before Relay's
/// front end builds the operation, because the front end would check the
/// variable against one declared argument type, and the key field's type is
/// each record type's own; the lowering checks what the directive names
/// (`docs/decisions/a-mutation-names-the-record-it-deletes.md`).
pub fn take_deletes(
    definitions: &mut [ExecutableDefinition],
    key: SourceLocationKey,
    errors: &mut Vec<Diagnostic>,
) -> BTreeMap<String, Vec<Deletes>> {
    let mut taken = BTreeMap::new();
    for definition in definitions {
        let ExecutableDefinition::Operation(operation) = definition else {
            continue;
        };
        if !matches!(operation.operation_kind(), OperationKind::Mutation) {
            continue;
        }
        let Some(name) = &operation.name else {
            continue;
        };
        let (deletes, kept): (Vec<Directive>, Vec<Directive>) = operation
            .directives
            .drain(..)
            .partition(|directive| directive.name.value.lookup() == "deletes");
        operation.directives = kept;
        if deletes.is_empty() {
            continue;
        }
        let parsed: Vec<Deletes> = deletes
            .iter()
            .filter_map(|directive| deletes_directive(directive, key, errors))
            .collect();
        taken.insert(name.value.lookup().to_string(), parsed);
    }
    taken
}

/// Checks, once every document is parsed, that each `@deletes` names a
/// variable a field of its mutation passes, through the fragments it
/// spreads, which may live in another document: a server refuses a
/// variable its operation does not use. A directive that fails leaves the
/// map, so the lowering plans nothing for it.
pub fn check_passes(
    deletes: &mut BTreeMap<String, Vec<Deletes>>,
    definitions: &[ExecutableDefinition],
    errors: &mut Vec<Diagnostic>,
) {
    let mut operations: BTreeMap<&str, &OperationDefinition> = BTreeMap::new();
    let mut fragments: BTreeMap<&str, &FragmentDefinition> = BTreeMap::new();
    for definition in definitions {
        match definition {
            ExecutableDefinition::Operation(operation) => {
                if let Some(name) = &operation.name {
                    operations.insert(name.value.lookup(), operation);
                }
            }
            ExecutableDefinition::Fragment(fragment) => {
                fragments.insert(fragment.name.value.lookup(), fragment);
            }
        }
    }
    for (operation_name, directives) in deletes.iter_mut() {
        let Some(operation) = operations.get(operation_name.as_str()) else {
            continue;
        };
        directives.retain(|directive| {
            let mut visited = BTreeSet::new();
            if passes(
                &operation.selections.items,
                &directive.variable,
                &fragments,
                &mut visited,
            ) {
                return true;
            }
            errors.push(Diagnostic::error(
                format!(
                    "`@deletes` names `${}`, which no field of `{operation_name}` passes: a server refuses a variable its operation does not use",
                    directive.variable
                ),
                directive.variable_location,
            ));
            false
        });
    }
}

/// One `@deletes`, checked for its shape.
fn deletes_directive(
    directive: &Directive,
    key: SourceLocationKey,
    errors: &mut Vec<Diagnostic>,
) -> Option<Deletes> {
    let arguments: &[Argument] = directive
        .arguments
        .as_ref()
        .map(|list| list.items.as_slice())
        .unwrap_or(&[]);
    let mut type_name = None;
    let mut variable = None;
    let mut malformed = arguments.len() != 2;
    for argument in arguments {
        match (argument.name.value.lookup(), &argument.value) {
            ("type", Value::Constant(ConstantValue::String(string))) => {
                type_name = Some((
                    string.value.lookup().to_string(),
                    Location::new(key, string.token.span),
                ));
            }
            ("id", Value::Variable(identifier)) => {
                variable = Some((
                    identifier.name.lookup().to_string(),
                    Location::new(key, identifier.span),
                ));
            }
            _ => malformed = true,
        }
    }
    let ((type_name, type_location), (variable, variable_location)) = match (type_name, variable) {
        (Some(type_name), Some(variable)) if !malformed => (type_name, variable),
        _ => {
            errors.push(Diagnostic::error(
                "`@deletes` takes `type`, the name of the record's type, and `id`, the variable the record's key is passed as",
                Location::new(key, directive.span),
            ));
            return None;
        }
    };
    Some(Deletes {
        type_name,
        type_location,
        variable,
        variable_location,
    })
}

/// Whether a field, a spread or an inline fragment under `selections`
/// passes the variable in an argument, at any depth, following each spread
/// into its fragment's body.
fn passes(
    selections: &[Selection],
    variable: &str,
    fragments: &BTreeMap<&str, &FragmentDefinition>,
    visited: &mut BTreeSet<String>,
) -> bool {
    selections.iter().any(|selection| match selection {
        Selection::ScalarField(field) => {
            arguments_pass(&field.arguments, variable)
                || directives_pass(&field.directives, variable)
        }
        Selection::LinkedField(field) => {
            arguments_pass(&field.arguments, variable)
                || directives_pass(&field.directives, variable)
                || passes(&field.selections.items, variable, fragments, visited)
        }
        Selection::InlineFragment(fragment) => {
            directives_pass(&fragment.directives, variable)
                || passes(&fragment.selections.items, variable, fragments, visited)
        }
        Selection::FragmentSpread(spread) => {
            arguments_pass(&spread.arguments, variable)
                || directives_pass(&spread.directives, variable)
                || spread_passes(spread, variable, fragments, visited)
        }
    })
}

/// Whether the spread fragment's body passes the operation's variable: not
/// when the fragment declares an argument of that name, which shadows it
/// inside the body, and each fragment is walked once.
fn spread_passes(
    spread: &FragmentSpread,
    variable: &str,
    fragments: &BTreeMap<&str, &FragmentDefinition>,
    visited: &mut BTreeSet<String>,
) -> bool {
    let name = spread.name.value.lookup();
    let Some(fragment) = fragments.get(name) else {
        return false;
    };
    if declares_argument(fragment, variable) || !visited.insert(name.to_string()) {
        return false;
    }
    passes(&fragment.selections.items, variable, fragments, visited)
}

/// Whether the fragment declares `variable` as an argument of its own, by
/// `@argumentDefinitions` or by a variable definition on the fragment.
fn declares_argument(fragment: &FragmentDefinition, variable: &str) -> bool {
    let by_directive = fragment
        .directives
        .iter()
        .filter(|directive| directive.name.value.lookup() == "argumentDefinitions")
        .any(|directive| {
            directive.arguments.as_ref().is_some_and(|list| {
                list.items
                    .iter()
                    .any(|argument| argument.name.value.lookup() == variable)
            })
        });
    let by_definition = fragment.variable_definitions.as_ref().is_some_and(|list| {
        list.items
            .iter()
            .any(|definition| definition.name.name.lookup() == variable)
    });
    by_directive || by_definition
}

fn directives_pass(directives: &[Directive], variable: &str) -> bool {
    directives
        .iter()
        .any(|directive| arguments_pass(&directive.arguments, variable))
}

fn arguments_pass(arguments: &Option<List<Argument>>, variable: &str) -> bool {
    arguments.as_ref().is_some_and(|list| {
        list.items
            .iter()
            .any(|argument| value_passes(&argument.value, variable))
    })
}

fn value_passes(value: &Value, variable: &str) -> bool {
    match value {
        Value::Variable(identifier) => identifier.name.lookup() == variable,
        Value::List(list) => list.items.iter().any(|item| value_passes(item, variable)),
        Value::Object(fields) => fields
            .items
            .iter()
            .any(|field| value_passes(&field.value, variable)),
        Value::Constant(_) => false,
    }
}
