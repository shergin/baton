//! What a document may say: the directives Baton gives a meaning to, where
//! it gives it, and one definition of the marker's own kind per marker.
//! Relay's transforms accept more, and some of it, such as
//! `@relay(plural:)`, compiles and then does nothing; here it is an error
//! at the directive.

use common::{Diagnostic, Location, SourceLocationKey};
use graphql_syntax::{Directive, ExecutableDefinition, OperationKind, Selection};
use intern::Lookup;

use crate::swift::Marker;

/// The directives each place takes. A query also states its cache
/// expiration, the one directive that is not Relay's
/// (`docs/decisions/an-operation-states-its-expiration.md`).
const QUERY: &[&str] = &["throwOnFieldError", "cacheExpiration"];
const OPERATION: &[&str] = &["throwOnFieldError"];
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
                    OperationKind::Mutation => (OPERATION, "a mutation"),
                    OperationKind::Subscription => (OPERATION, "a subscription"),
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
