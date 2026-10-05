//! Names Swift keeps for itself, or that the generated code declares or
//! spells, held against every position a document's name can take. In each
//! position the compiler either accepts a name and writes Swift that
//! compiles, or refuses it with an error at the name. A name a position
//! accepts is in the corpus, `HostileNameDocuments.swift` in the Swift test
//! target, whose golden the Swift build compiles; a name it refuses is in
//! the position's table below; a name it accepts though the Swift written
//! for it does not compile is a known defect, recorded below with the line
//! Swift refuses until it is fixed.
//!
//! The names are read from the rules where the rules list them: the
//! keywords `escape` knows, the reserved lists, the local aliases a body
//! takes and the names `decide` declares in a scope. A name added to one of
//! them fails here until every position holds it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::documents::Document;
use crate::names::{
    BUILDER_RESERVED_NAMES, NameError, RESERVED_TYPE_NAMES, STANDARD_LIBRARY_NAMES, call_label,
    escape,
};
use crate::pipeline::{FragmentPlan, OperationPlan, Plan, SelectionPlan};
use crate::{diagnostics, emit, pipeline};

/// The corpus, as the plan names its source.
pub(super) const CORPUS: &str = "swift/Tests/BatonTests/HostileNameDocuments.swift";

/// Swift's keywords that `escape` does not list. Swift refuses each as the
/// name of a declaration unless it is escaped.
const UNLISTED_KEYWORDS: [&str; 4] = ["rethrows", "fallthrough", "precedencegroup", "_"];

/// Swift's contextual keywords that start an expression or a type, where
/// the generated code puts a document's name: a value, a type, a
/// parameter. The others introduce or modify a declaration, name an
/// accessor or describe an operator, where it puts none.
const CONTEXTUAL_KEYWORDS: [&str; 12] = [
    "async",
    "await",
    "borrowing",
    "consume",
    "consuming",
    "copy",
    "discard",
    "each",
    "isolated",
    "sending",
    "then",
    "unsafe",
];

/// What the generated code declares or spells that no list of the rules
/// holds.
const GENERATED_NAMES: [&str; 29] = [
    // The checks every lens may have, and the methods of a lens.
    "satisfied",
    "missingRequiredField",
    "fieldErrors",
    "isPresent",
    "throwing",
    "caught",
    "refetch",
    "loadNext",
    "loadPrevious",
    // The locals and parameters of generated bodies.
    "bound",
    "errors",
    "child",
    "missing",
    "count",
    "fields",
    "lhs",
    "rhs",
    "hasher",
    // What an operation value and a mutation's action declare or call.
    "hash",
    "commit",
    "callAsFunction",
    "Op",
    // What the runtime's protocols give a generated type.
    "hashValue",
    "phase",
    "isRefreshing",
    "isStale",
    "retry",
    "subscription",
    // The standard library's type of the shared file's sets of types.
    "Set",
];

/// The names `decide` matches in a document rather than declares: the
/// fields a connection's `nodes` reads and the field every record has.
const MATCHED_FIELDS: [&str; 3] = ["__typename", "edges", "node"];

/// The text a probe holds where the hostile name goes.
const HOSTILE: &str = "HOSTILE";

/// The path a probe is compiled under, as its errors name it.
const PROBE: &str = "Probe.graphql";

const SCALAR: &str = "an aliased scalar field";
const LINKED: &str = "an aliased linked field";
const SELECTION: &str = "an aliased selection";
const SPREAD: &str = "an aliased spread";
const BODIES: &str = "a field beside every kind of generated body";
const CONNECTION: &str = "a field of a connection";
const REQUIRED: &str = "a field beside the checks of a required field that bubbles to the root";
const ABSTRACT: &str = "a field of a lens on an interface";
const QUERY_VARIABLE: &str = "a variable of a query";
const MUTATION_VARIABLE: &str = "a variable of a mutation";
const SUBSCRIPTION_VARIABLE: &str = "a variable of a subscription";
const FRAGMENT_ARGUMENT: &str = "an argument of a refetchable fragment";
const PAYLOAD_SCALAR: &str = "a scalar field of a mutation's payload";
const PAYLOAD_LINKED: &str = "a linked field of a mutation's payload";
const FRAGMENT_NAME: &str = "a fragment's name";
const QUERY_NAME: &str = "a query's name";
const MUTATION_NAME: &str = "a mutation's name";
const SUBSCRIPTION_NAME: &str = "a subscription's name";
const REFETCH_QUERY_NAME: &str = "a refetch query's name";

/// A position a document's name can take, and what the compiler makes of a
/// hostile name there.
struct Position {
    name: &'static str,
    /// The names the corpus gives the position. None for the name of a
    /// fragment or an operation, which is a type of the whole test module:
    /// one named like a type its other sources spell would change what they
    /// mean, so the names such a position accepts are proved accepted, not
    /// compiled.
    corpus: Option<fn(&Plan) -> Vec<String>>,
    /// A document with `HOSTILE` where the name goes.
    probe: &'static str,
    /// The text a refusal points at, the first of the probe's, with
    /// `HOSTILE` for the name.
    at: &'static str,
    /// What a refusal calls the name, with `HOSTILE` for it.
    what: &'static str,
    /// What a refusal asks of the document.
    remedy: &'static str,
    /// The names the position refuses, each with what it clashes with in
    /// the generated Swift.
    refused: &'static [(&'static str, &'static str)],
}

/// Names a position accepts though the Swift written for them does not
/// compile, as Swift 6.3.3 says with warnings as errors: defects of the
/// compiler, kept here until each is fixed, when its names move to the
/// corpus or to the refusals.
struct Defect {
    positions: &'static [&'static str],
    names: Names,
    /// What the Swift written for a position's probe holds, with `HOSTILE`
    /// for the name: the line Swift refuses, and the declaration that makes
    /// it refuse it when that is another.
    writes: &'static [&'static str],
    /// What Swift says of the line.
    swift: &'static str,
}

/// The names of a defect.
enum Names {
    These(&'static [&'static str]),
    /// The keywords `escape` lists but the first, and the second besides.
    KeywordsBut(&'static [&'static str], &'static [&'static str]),
}

impl Names {
    fn resolve(&self) -> Vec<String> {
        match self {
            Names::These(names) => names.iter().map(|name| name.to_string()).collect(),
            Names::KeywordsBut(except, besides) => escaped_keywords()
                .into_iter()
                .filter(|keyword| !except.contains(&keyword.as_str()))
                .chain(besides.iter().map(|name| name.to_string()))
                .collect(),
        }
    }
}

/// The names a scope of the generated Swift declares, and how a refusal
/// calls them.
const ANCHOR: (&str, &str) = ("anchor", "the `anchor` every lens has");
const RECORD_ID: (&str, &str) = ("recordID", "the `recordID` every lens has");
const TYPES: (&str, &str) = ("Types", "the shared enum `Types`");
const SLOTS: (&str, &str) = ("Slots", "the shared enum `Slots`");
const SITES: (&str, &str) = ("Sites", "the shared enum `Sites`");
const ABSTRACT_SLOTS: (&str, &str) = ("AbstractSlots", "the shared enum `AbstractSlots`");
const VARIABLE: (&str, &str) = ("variable", "the optimistic response's `variable`");
const VARIABLES: (&str, &str) = ("variables", "the operation's `variables`");
const RESOLUTION: (&str, &str) = ("resolution", "the operation's `resolution`");
const DATA: (&str, &str) = ("Data", "the operation's root lens `Data`");
const MODULE: (&str, &str) = ("Baton", "the runtime's module `Baton`");

/// What the module's top level refuses a fragment's or an operation's name.
const TOP_LEVEL: [(&str, &str); 15] = [
    ("Any", "Swift's keyword `Any`"),
    ("Self", "Swift's keyword `Self`"),
    ("Swift", "the standard library's module `Swift`"),
    ("MainActor", "the standard library's `MainActor`"),
    ("Result", "the standard library's `Result`"),
    ("Optional", "the standard library's `Optional`"),
    ("String", "the standard library's `String`"),
    ("Int", "the standard library's `Int`"),
    ("Double", "the standard library's `Double`"),
    ("Bool", "the standard library's `Bool`"),
    ("Hasher", "the standard library's `Hasher`"),
    ("Sendable", "the standard library's `Sendable`"),
    MODULE,
    TYPES,
    SLOTS,
];

fn positions() -> Vec<Position> {
    let field = |name, corpus, probe, refused| Position {
        name,
        corpus: Some(corpus),
        probe,
        at: "HOSTILE:",
        what: "the field `HOSTILE`",
        remedy: "choose another alias",
        refused,
    };
    let selection = |name, corpus, probe, refused| Position {
        name,
        corpus: Some(corpus),
        probe,
        at: "\"HOSTILE\"",
        what: "the selection aliased `HOSTILE`",
        remedy: "choose another alias",
        refused,
    };
    let variable = |name, corpus, probe, at, refused| Position {
        name,
        corpus: Some(corpus),
        probe,
        at,
        what: "the variable `$HOSTILE`",
        remedy: "rename the variable",
        refused,
    };
    let top_level = |name, probe, at, what, remedy| Position {
        name,
        corpus: None,
        probe,
        at,
        what,
        remedy,
        refused: &TOP_LEVEL,
    };
    vec![
        field(
            SCALAR,
            scalar_names,
            "fragment Probe_character on Character { HOSTILE: name }",
            &[ANCHOR, RECORD_ID, SLOTS],
        ),
        field(
            LINKED,
            linked_names,
            "fragment Probe_character on Character { HOSTILE: origin { id } }",
            &[ANCHOR, RECORD_ID, SLOTS],
        ),
        selection(
            SELECTION,
            selection_names,
            r#"fragment Probe_character on Character { ... @alias(as: "HOSTILE") { name } }"#,
            &[ANCHOR, RECORD_ID, SLOTS],
        ),
        selection(
            SPREAD,
            spread_names,
            r#"fragment ProbeTarget_character on Character { name } fragment Probe_character on Character { ... @alias(as: "HOSTILE") { ...ProbeTarget_character } }"#,
            &[ANCHOR, RECORD_ID],
        ),
        field(
            BODIES,
            bodies_names,
            r#"fragment ProbeBound_character on Character @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) { name @include(if: $flag) origin @required(action: NONE) { id } } fragment ProbeDeferred_character on Character { name } fragment ProbeCaught_character on Character { name } fragment Probe_character on Character @refetchable(queryName: "ProbeRefetchQuery") @throwOnFieldError { HOSTILE: name species @required(action: THROW) origin @required(action: NONE) { name @required(action: NONE) } ...ProbeBound_character @arguments(flag: false) ...ProbeDeferred_character @defer ... @alias(as: "caughtSpread") @catch { ...ProbeCaught_character } }"#,
            &[ANCHOR, RECORD_ID, TYPES, SLOTS, SITES],
        ),
        field(
            CONNECTION,
            connection_names,
            r#"fragment Probe_character on Character @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) @refetchable(queryName: "ProbeRefetchQuery") { notes(first: $count, after: $cursor) @connection(key: "Probe_notes") { HOSTILE: totalCount edges { node { id } } } }"#,
            &[
                ANCHOR,
                RECORD_ID,
                ("hasNext", "the connection's `hasNext`"),
                ("hasPrevious", "the connection's `hasPrevious`"),
                ("isLoadingNext", "the connection's `isLoadingNext`"),
                ("isLoadingPrevious", "the connection's `isLoadingPrevious`"),
                ("connectionID", "the connection's `connectionID`"),
                TYPES,
                SLOTS,
            ],
        ),
        field(
            REQUIRED,
            required_names,
            "query Probe { character(id: 1) @required(action: NONE) { HOSTILE: name origin @required(action: NONE) { name @required(action: NONE) } } }",
            &[ANCHOR, RECORD_ID, TYPES, SLOTS],
        ),
        field(
            ABSTRACT,
            abstract_names,
            "fragment Probe_node on Node { HOSTILE: id ... on Character { status } }",
            &[ANCHOR, RECORD_ID, TYPES, SLOTS, ABSTRACT_SLOTS],
        ),
        variable(
            QUERY_VARIABLE,
            query_variable_names,
            "query Probe($HOSTILE: ID!) @throwOnFieldError { charactersByIds(ids: [$HOSTILE]) { id } }",
            "$HOSTILE",
            &[VARIABLES, RESOLUTION, DATA, TYPES, SLOTS, MODULE],
        ),
        variable(
            MUTATION_VARIABLE,
            mutation_variable_names,
            r#"mutation Probe($HOSTILE: Boolean!) { setFavorite(id: "1", favorite: true) @catch { character { id ... @include(if: $HOSTILE) { name } } } }"#,
            "$HOSTILE",
            &[
                ("optimistic", "the action's parameter `optimistic`"),
                VARIABLES,
                DATA,
                ("Action", "the mutation's `Action`"),
                ("OptimisticResponse", "the mutation's `OptimisticResponse`"),
                TYPES,
                SLOTS,
                MODULE,
            ],
        ),
        variable(
            SUBSCRIPTION_VARIABLE,
            subscription_variable_names,
            r#"subscription Probe($HOSTILE: Boolean!) { noteAdded(characterId: "1") @catch { noteEdge { node { id } ... @include(if: $HOSTILE) { cursor } } } }"#,
            "$HOSTILE",
            &[VARIABLES, RESOLUTION, DATA, TYPES, SLOTS, MODULE],
        ),
        variable(
            FRAGMENT_ARGUMENT,
            fragment_argument_names,
            r#"fragment Probe_character on Character @argumentDefinitions(HOSTILE: {type: "Boolean", defaultValue: true}) @refetchable(queryName: "ProbeRefetchQuery") { ... @include(if: $HOSTILE) { name } }"#,
            "HOSTILE:",
            &[VARIABLES, RESOLUTION, DATA, TYPES, SLOTS, SITES, MODULE],
        ),
        field(
            PAYLOAD_SCALAR,
            payload_scalar_names,
            r#"mutation Probe { setFavorite(id: "1", favorite: true) { character { HOSTILE: name } } }"#,
            &[ANCHOR, RECORD_ID, SLOTS, VARIABLE],
        ),
        field(
            PAYLOAD_LINKED,
            payload_linked_names,
            r#"mutation Probe { addNote(characterId: "1", text: "hostile") { HOSTILE: note { id } } }"#,
            &[ANCHOR, RECORD_ID, SLOTS, VARIABLE],
        ),
        top_level(
            FRAGMENT_NAME,
            "fragment HOSTILE on Character { name }",
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
        ),
        top_level(
            QUERY_NAME,
            "query HOSTILE { character(id: 1) { id } }",
            HOSTILE,
            "the query `HOSTILE`",
            "rename the query",
        ),
        top_level(
            MUTATION_NAME,
            r#"mutation HOSTILE { setFavorite(id: "1", favorite: true) { character { id } } }"#,
            HOSTILE,
            "the mutation `HOSTILE`",
            "rename the mutation",
        ),
        top_level(
            SUBSCRIPTION_NAME,
            r#"subscription HOSTILE { noteAdded(characterId: "1") { noteEdge { cursor } } }"#,
            HOSTILE,
            "the subscription `HOSTILE`",
            "rename the subscription",
        ),
        top_level(
            REFETCH_QUERY_NAME,
            r#"fragment Probe_character on Character @refetchable(queryName: "HOSTILE") { name }"#,
            "Probe_character",
            "the refetch query `HOSTILE`",
            "name it otherwise in `@refetchable(queryName:)`",
        ),
    ]
}

fn defects() -> Vec<Defect> {
    const ACCESSORS: &[&str] = &[
        SCALAR,
        LINKED,
        SELECTION,
        SPREAD,
        BODIES,
        CONNECTION,
        REQUIRED,
        ABSTRACT,
        PAYLOAD_SCALAR,
        PAYLOAD_LINKED,
    ];
    const VARIABLES: &[&str] = &[
        QUERY_VARIABLE,
        MUTATION_VARIABLE,
        SUBSCRIPTION_VARIABLE,
        FRAGMENT_ARGUMENT,
    ];
    const UNLISTED: &[&str] = &["rethrows", "fallthrough", "precedencegroup"];
    vec![
        // `escape` does not know these keywords.
        Defect {
            positions: ACCESSORS,
            names: Names::These(UNLISTED),
            writes: &["@MainActor public var HOSTILE: "],
            swift: "keyword 'rethrows' cannot be used as an identifier here",
        },
        Defect {
            positions: ACCESSORS,
            names: Names::These(&["_"]),
            writes: &["@MainActor public var _: "],
            swift: "getter/setter can only be defined for a single variable",
        },
        Defect {
            positions: VARIABLES,
            names: Names::These(UNLISTED),
            writes: &["    public var HOSTILE: "],
            swift: "keyword 'rethrows' cannot be used as an identifier here",
        },
        Defect {
            positions: VARIABLES,
            names: Names::These(&["_"]),
            writes: &["    public var _: "],
            swift: "property declaration does not bind any variables",
        },
        // A member named `Self` hides Swift's `Self` from the expressions
        // of its lens and of every lens nested in it.
        Defect {
            positions: &[BODIES],
            names: Names::These(&["Self"]),
            writes: &[
                "@MainActor public var `Self`: ",
                ".success(Self(anchor: anchor))",
                "try await anchor.refetch(Query.self, Self.refetchable)",
            ],
            swift: "instance member 'Self' cannot be used on type 'Probe_character'",
        },
        Defect {
            positions: &[CONNECTION],
            names: Names::These(&["Self"]),
            writes: &[
                "@MainActor public var `Self`: ",
                "anchor.nodes(Self.connection)",
            ],
            swift: "value of type 'Int' has no member 'connection'",
        },
        // And a variable named `Self` hides it from the lenses nested in its
        // operation.
        Defect {
            positions: &[QUERY_VARIABLE, MUTATION_VARIABLE, SUBSCRIPTION_VARIABLE],
            names: Names::These(&["Self"]),
            writes: &["    public var `Self`: ", ".success(Self(anchor: anchor))"],
            swift: "instance member 'Self' of type 'Probe' cannot be used on instance of nested type 'Probe.Data'",
        },
        // An initializer's parameter named `await` reads as the keyword.
        Defect {
            positions: VARIABLES,
            names: Names::These(&["await"]),
            writes: &["self.await = await"],
            swift: "expected expression after 'await'",
        },
        Defect {
            positions: &[PAYLOAD_SCALAR, PAYLOAD_LINKED],
            names: Names::These(&["await"]),
            writes: &["if let await {"],
            swift: "expected expression after 'await'",
        },
        // A variable's property hides the `hashValue` of `Hashable`.
        Defect {
            positions: VARIABLES,
            names: Names::These(&["hashValue"]),
            writes: &["public var hashValue: ", "Baton.Variable(self.hashValue)"],
            swift: "ambiguous use of 'hashValue'",
        },
        // `call_label` escapes these, which Swift takes bare.
        Defect {
            positions: &[MUTATION_VARIABLE],
            names: Names::These(&["var", "let"]),
            writes: &["Probe(`HOSTILE`: `HOSTILE`)"],
            swift: "keyword 'var' does not need to be escaped in argument list",
        },
        // A builder's field named like the dictionary its `variable` fills.
        Defect {
            positions: &[PAYLOAD_SCALAR, PAYLOAD_LINKED],
            names: Names::These(&["fields"]),
            writes: &[
                "var fields: [String: Baton.Variable] = [:]",
                "if let fields { fields[\"fields\"]",
            ],
            swift: "cannot assign through subscript: 'fields' is a 'let' constant",
        },
        // The name of a fragment or an operation is written unescaped.
        Defect {
            positions: &[FRAGMENT_NAME, QUERY_NAME, SUBSCRIPTION_NAME],
            names: Names::KeywordsBut(
                &["Type", "Protocol", "Any", "Self", "open", "some", "any"],
                &["rethrows", "fallthrough", "precedencegroup", "_"],
            ),
            writes: &["public struct HOSTILE: "],
            swift: "keyword 'class' cannot be used as an identifier here",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::KeywordsBut(
                &["Type", "Protocol", "Any", "Self", "open", "some", "any"],
                &["rethrows", "fallthrough", "precedencegroup", "_"],
            ),
            writes: &["public struct HOSTILE: ", "where Op == HOSTILE {"],
            swift: "keyword 'class' cannot be used as an identifier here",
        },
        Defect {
            positions: &[REFETCH_QUERY_NAME],
            names: Names::KeywordsBut(
                &["Type", "Protocol", "Any", "Self", "open"],
                &["rethrows", "fallthrough", "precedencegroup", "each"],
            ),
            writes: &["typealias Query = HOSTILE"],
            swift: "expected type in type alias declaration",
        },
        Defect {
            positions: &[REFETCH_QUERY_NAME],
            names: Names::These(&["_"]),
            writes: &["public struct _: "],
            swift: "keyword '_' cannot be used as an identifier here",
        },
        // A mutation's action spells its name as a type where a keyword or
        // one of its own names takes the place of the type.
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["some", "any", "each"]),
            writes: &["where Op == HOSTILE {"],
            swift: "expected type",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["async"]),
            writes: &["async throws -> async.Data {"],
            swift: "'async' has already been specified",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["await"]),
            writes: &["async throws -> await.Data {"],
            swift: "expected async specifier; did you mean 'async'?",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["Op"]),
            writes: &["where Op == Op {"],
            swift: "'OptimisticResponse' is not a member type of type 'Op'",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["callAsFunction"]),
            writes: &["try await self.commit(callAsFunction(), optimistic:"],
            swift: "cannot convert value of type 'callAsFunction.Data' to expected argument type 'callAsFunction'",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["commit"]),
            writes: &["try await self.commit(commit(), optimistic:"],
            swift: "use of 'commit' refers to instance method rather than struct 'commit' in module",
        },
        Defect {
            positions: &[MUTATION_NAME],
            names: Names::These(&["optimistic"]),
            writes: &["try await self.commit(optimistic(), optimistic:"],
            swift: "cannot call value of non-function type 'optimistic.OptimisticResponse?'",
        },
    ]
}

/// Defects of a name that hides another the same document chose, outside
/// the table of positions: each with its document, what the Swift written
/// for it holds, and what Swift 6.3.3 says.
const RELATED_DEFECTS: [(&str, &[&str], &str); 2] = [
    // A variable of a mutation named like the mutation takes the place of
    // its type in the action's call.
    (
        r#"mutation Favorite($Favorite: ID!) { setFavorite(id: $Favorite, favorite: true) { character { id } } }"#,
        &["try await self.commit(Favorite(Favorite: Favorite), optimistic:"],
        "cannot call value of non-function type 'String'",
    ),
    // The spread of a fragment named from an underscore takes the empty
    // text before it as its accessor's name.
    (
        "fragment _hidden on Character { name } query Probe { character(id: 1) { ..._hidden } }",
        &["@MainActor public var : _hidden { .init(anchor: anchor) }"],
        "expected pattern",
    ),
];

// The names the corpus gives each position, from its plan.

fn fragment<'a>(plan: &'a Plan, name: &str) -> &'a FragmentPlan {
    plan.fragments
        .iter()
        .find(|fragment| fragment.name == name)
        .unwrap_or_else(|| panic!("the corpus has the fragment `{name}`"))
}

fn operation<'a>(plan: &'a Plan, name: &str) -> &'a OperationPlan {
    plan.operations
        .iter()
        .find(|operation| operation.name == name)
        .unwrap_or_else(|| panic!("the corpus has the operation `{name}`"))
}

/// The selections of the linked field `field` among `selections`.
fn inside<'a>(selections: &'a [SelectionPlan], field: &str) -> &'a [SelectionPlan] {
    selections
        .iter()
        .find_map(|selection| match selection {
            SelectionPlan::Linked {
                name, selections, ..
            } if name == field => Some(selections.as_slice()),
            _ => None,
        })
        .unwrap_or_else(|| panic!("the corpus selects `{field}`"))
}

/// The aliases of the selections of `field` among `selections`.
fn aliases_of(selections: &[SelectionPlan], field: &str) -> Vec<String> {
    selections
        .iter()
        .filter_map(|selection| match selection {
            SelectionPlan::Scalar { name, alias, .. }
            | SelectionPlan::Linked { name, alias, .. }
                if name == field =>
            {
                alias.clone()
            }
            _ => None,
        })
        .collect()
}

/// The aliases of the inline fragments among `selections`: those around
/// one spread when `spreads` holds, the others otherwise.
fn inline_aliases(selections: &[SelectionPlan], spreads: bool) -> Vec<String> {
    selections
        .iter()
        .filter_map(|selection| match selection {
            SelectionPlan::Inline {
                alias: Some(alias),
                selections,
                ..
            } if matches!(selections.as_slice(), [SelectionPlan::Spread { .. }]) == spreads => {
                Some(alias.clone())
            }
            _ => None,
        })
        .collect()
}

fn scalar_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "HostileScalars_character").reader, "name")
}

fn linked_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "HostileLinks_character").reader, "origin")
}

fn selection_names(plan: &Plan) -> Vec<String> {
    inline_aliases(&fragment(plan, "HostileSelections_character").reader, false)
}

fn spread_names(plan: &Plan) -> Vec<String> {
    inline_aliases(&fragment(plan, "HostileSpreads_character").reader, true)
}

fn bodies_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "HostileBodies_character").reader, "name")
}

fn connection_names(plan: &Plan) -> Vec<String> {
    [
        "HostileConnection_character",
        "HostileConnectionNodes_character",
    ]
    .into_iter()
    .flat_map(|name| aliases_of(inside(&fragment(plan, name).reader, "notes"), "totalCount"))
    .collect()
}

fn required_names(plan: &Plan) -> Vec<String> {
    aliases_of(
        inside(&operation(plan, "HostileRequired").reader, "character"),
        "name",
    )
}

fn abstract_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "HostileAbstract_node").reader, "id")
}

fn variable_names(operation: &OperationPlan) -> Vec<String> {
    operation
        .variables
        .iter()
        .map(|variable| variable.name.clone())
        .collect()
}

fn query_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "HostileVariables"))
}

fn mutation_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "HostileMutationVariables"))
}

fn subscription_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "HostileSubscriptionVariables"))
}

fn fragment_argument_names(plan: &Plan) -> Vec<String> {
    plan.fragments
        .iter()
        .filter(|fragment| {
            fragment.name.starts_with("HostileArguments") && fragment.name.ends_with("_character")
        })
        .flat_map(|fragment| {
            fragment
                .arguments
                .iter()
                .map(|argument| argument.name.clone())
        })
        .collect()
}

fn payload_scalar_names(plan: &Plan) -> Vec<String> {
    let payload = &operation(plan, "HostilePayload").reader;
    aliases_of(inside(inside(payload, "setFavorite"), "character"), "name")
}

fn payload_linked_names(plan: &Plan) -> Vec<String> {
    let payload = &operation(plan, "HostilePayload").reader;
    aliases_of(inside(payload, "addNote"), "note")
}

// The names, read from the rules where the rules list them.

/// The string literals of Rust `source`, outside its comments.
fn string_literals(source: &str) -> Vec<String> {
    let characters: Vec<char> = source.chars().collect();
    let mut literals = Vec::new();
    let mut index = 0;
    while index < characters.len() {
        match characters[index] {
            '/' if characters.get(index + 1) == Some(&'/') => {
                while index < characters.len() && characters[index] != '\n' {
                    index += 1;
                }
            }
            // A character literal, which may be a quote, or a lifetime.
            '\'' => {
                if characters.get(index + 1) == Some(&'\\') {
                    index += 2;
                    while index < characters.len() && characters[index] != '\'' {
                        index += 1;
                    }
                } else if characters.get(index + 2) == Some(&'\'') {
                    index += 2;
                }
            }
            '"' => {
                let mut literal = String::new();
                index += 1;
                while index < characters.len() && characters[index] != '"' {
                    if characters[index] == '\\' {
                        literal.push('\\');
                        index += 1;
                    }
                    literal.push(characters[index]);
                    index += 1;
                }
                literals.push(literal);
            }
            _ => {}
        }
        index += 1;
    }
    literals
}

fn is_identifier(text: &str) -> bool {
    let mut characters = text.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && characters.all(|character| character.is_ascii_alphanumeric() || character == '_')
}

/// The string literals of `source` from the line that starts with
/// `declaration` to the end of the array it declares.
fn array_literals(source: &str, declaration: &str) -> Vec<String> {
    let start = source
        .lines()
        .position(|line| line.trim_start().starts_with(declaration))
        .unwrap_or_else(|| panic!("the source declares `{declaration}`"));
    let lines: Vec<&str> = source.lines().skip(start).collect();
    let end = lines
        .iter()
        .position(|line| line.trim_end().ends_with("];"))
        .unwrap_or_else(|| panic!("the array `{declaration}` ends"));
    string_literals(&lines[..=end].join("\n"))
}

/// The keywords `escape` lists, read from its source.
fn escaped_keywords() -> Vec<String> {
    array_literals(include_str!("../names.rs"), "const KEYWORDS: &[&str] = &[")
}

/// The names a generated body gives the fragments and queries it aliases.
fn local_aliases() -> Vec<String> {
    let source = include_str!("../emit/swift.rs");
    let mut names = array_literals(source, "const FRAGMENT_ALIASES");
    names.extend(array_literals(source, "const QUERY_ALIASES"));
    names
}

/// The names `decide` declares in the scopes of lenses, operations,
/// builders and the module, read from its source.
fn scope_names() -> Vec<String> {
    [
        include_str!("../decide/reader.rs"),
        include_str!("../decide/lens.rs"),
        include_str!("../decide/members.rs"),
        include_str!("../decide/checks.rs"),
        include_str!("../decide/operation.rs"),
        include_str!("../decide/collect.rs"),
    ]
    .into_iter()
    .flat_map(string_literals)
    .filter(|literal| is_identifier(literal) && !MATCHED_FIELDS.contains(&literal.as_str()))
    .collect()
}

fn listed(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}

/// Every hostile name once, with what makes it one.
fn hostile_names() -> Vec<(String, &'static str)> {
    let sources = [
        (escaped_keywords(), "a keyword `escape` lists"),
        (
            listed(&UNLISTED_KEYWORDS),
            "a keyword `escape` does not list",
        ),
        (listed(&CONTEXTUAL_KEYWORDS), "a contextual keyword"),
        (
            listed(&RESERVED_TYPE_NAMES),
            "a name of `RESERVED_TYPE_NAMES`",
        ),
        (
            listed(&BUILDER_RESERVED_NAMES),
            "a name of `BUILDER_RESERVED_NAMES`",
        ),
        (
            listed(&STANDARD_LIBRARY_NAMES),
            "a name of `STANDARD_LIBRARY_NAMES`",
        ),
        (local_aliases(), "a local alias of a generated body"),
        (scope_names(), "a name `decide` declares"),
        (listed(&GENERATED_NAMES), "a name the generated code spells"),
    ];
    let mut names: Vec<(String, &'static str)> = Vec::new();
    for (list, why) in sources {
        for name in list {
            if !names.iter().any(|(known, _)| *known == name) {
                names.push((name, why));
            }
        }
    }
    names
}

// Probes: one document compiled alone.

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .to_path_buf()
}

/// What the compiler makes of `text` as the one document of a program: the
/// Swift it writes, or its errors as `batonc` prints them.
fn compile(text: &str) -> Result<emit::Output, Vec<String>> {
    let config_path = repository().join("swift/Tests/BatonTests/baton.json");
    let config = Config::load(&config_path).expect("the test target has a baton.json");
    let schema_path = config.schema_path(&config_path);
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let documents = [Document {
        path: PathBuf::from(PROBE),
        index: 0,
        start: crate::swift::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    }];
    let plan = match pipeline::compile(&schema, &schema_path.to_string_lossy(), &documents, &config)
    {
        Ok(compiled) => compiled.plan,
        Err(errors) => {
            return Err(errors
                .iter()
                .map(|error| diagnostics::render(error, &documents).to_string())
                .collect());
        }
    };
    emit::emit(&plan).map_err(|errors| {
        errors
            .iter()
            .map(|error| match error {
                NameError::Clash(clash) => {
                    diagnostics::at(&clash.origin, &documents, clash.to_string()).to_string()
                }
                NameError::Duplicate(duplicate) => format!("batonc: {duplicate}"),
            })
            .collect()
    })
}

/// The Swift written for `text`, every file of it.
fn swift(output: &emit::Output) -> String {
    let mut text: String = output.files.values().cloned().collect();
    text.push_str(&output.shared);
    text
}

/// `probe` with the document's own names numbered by `index`, so that
/// several probes make one program.
fn numbered(probe: &str, index: usize) -> String {
    probe.replace("Probe", &format!("Probe{index}"))
}

#[test]
fn every_hostile_name_is_in_the_corpus_or_refused_or_a_known_defect_in_every_position() {
    let plan = super::compile_swift_tests();
    let names = hostile_names();
    let defects = defects();
    let mut problems = Vec::new();
    for position in positions() {
        let corpus = position.corpus.map(|names| names(&plan));
        let known: Vec<String> = defects
            .iter()
            .filter(|defect| defect.positions.contains(&position.name))
            .flat_map(|defect| defect.names.resolve())
            .collect();
        for (name, _) in position.refused {
            if !names.iter().any(|(known, _)| known == name) {
                problems.push(format!(
                    "{}: `{name}` is refused but is no hostile name",
                    position.name
                ));
            }
        }
        for name in corpus.iter().flatten().chain(&known) {
            if !names.iter().any(|(known, _)| known == name) {
                problems.push(format!(
                    "{}: `{name}` is in the corpus or a defect but is no hostile name",
                    position.name
                ));
            }
        }
        for (name, why) in &names {
            let refused = position.refused.iter().any(|(refused, _)| refused == name);
            let defect = known.contains(name);
            let places = match &corpus {
                Some(corpus) => {
                    usize::from(refused) + usize::from(defect) + usize::from(corpus.contains(name))
                }
                // Every name neither refused nor a defect is accepted, as
                // `a_top_level_name_neither_refused_nor_a_defect_is_accepted`
                // proves.
                None => {
                    usize::from(refused) + usize::from(defect) + usize::from(!refused && !defect)
                }
            };
            if places != 1 {
                problems.push(format!(
                    "{}: `{name}`, {why}, is in {places} of the corpus, the refusals and the known defects; write it in the corpus or record why it is not",
                    position.name
                ));
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn a_refused_name_is_an_error_at_the_name_that_says_what_it_clashes_with_and_what_to_do() {
    let mut problems = Vec::new();
    for position in positions() {
        for (name, clashes) in position.refused {
            let probe = position.probe.replace(HOSTILE, name);
            let at = position.at.replace(HOSTILE, name);
            let column = probe
                .find(&at)
                .expect("the probe holds what a refusal points at")
                + 1;
            let expected = format!(
                "{PROBE}:1:{column}: error: {} clashes with {clashes} in the generated Swift; {}",
                position.what.replace(HOSTILE, name),
                position.remedy
            );
            match compile(&probe) {
                Ok(_) => problems.push(format!("{}: `{name}` is accepted", position.name)),
                Err(errors) if errors == [expected.clone()] => {}
                Err(errors) => problems.push(format!(
                    "{}: `{name}` is refused with\n  {}\nnot\n  {expected}",
                    position.name,
                    errors.join("\n  ")
                )),
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn a_top_level_name_neither_refused_nor_a_defect_is_accepted() {
    let names = hostile_names();
    let defects = defects();
    for position in positions()
        .into_iter()
        .filter(|position| position.corpus.is_none())
    {
        let known: Vec<String> = defects
            .iter()
            .filter(|defect| defect.positions.contains(&position.name))
            .flat_map(|defect| defect.names.resolve())
            .collect();
        let accepted: Vec<&str> = names
            .iter()
            .map(|(name, _)| name.as_str())
            .filter(|name| {
                !known.iter().any(|known| known == name)
                    && !position.refused.iter().any(|(refused, _)| refused == name)
            })
            .collect();
        let program: Vec<String> = accepted
            .iter()
            .enumerate()
            .map(|(index, name)| numbered(position.probe, index).replace(HOSTILE, name))
            .collect();
        if let Err(errors) = compile(&program.join("\n")) {
            panic!(
                "{}: the names it holds accepted are refused:\n{}",
                position.name,
                errors.join("\n")
            );
        }
    }
}

#[test]
fn a_known_defect_is_still_accepted_and_still_writes_the_swift_recorded_for_it() {
    let positions = positions();
    let mut problems = Vec::new();
    for defect in defects() {
        for name in defect.positions {
            let position = positions
                .iter()
                .find(|position| position.name == *name)
                .unwrap_or_else(|| panic!("a defect names the unknown position `{name}`"));
            let names = defect.names.resolve();
            // The names of a position make one program, and each writes its
            // own lines.
            let program: Vec<String> = names
                .iter()
                .enumerate()
                .map(|(index, name)| numbered(position.probe, index).replace(HOSTILE, name))
                .collect();
            let written = match compile(&program.join("\n")) {
                Ok(output) => swift(&output),
                Err(errors) => {
                    problems.push(format!(
                        "{}: a known defect is refused now; move its names to the refusals:\n  {}",
                        position.name,
                        errors.join("\n  ")
                    ));
                    continue;
                }
            };
            for (index, hostile) in names.iter().enumerate() {
                for line in defect.writes {
                    let line = numbered(line, index).replace(HOSTILE, hostile);
                    if !written.contains(&line) {
                        problems.push(format!(
                            "{}: `{hostile}` no longer writes `{line}`, for which Swift said \"{}\"; if its Swift compiles now, move it to the corpus",
                            position.name, defect.swift
                        ));
                    }
                }
            }
        }
    }
    for (document, writes, swift_says) in RELATED_DEFECTS {
        match compile(document) {
            Ok(output) => {
                let written = swift(&output);
                for line in writes {
                    if !written.contains(line) {
                        problems.push(format!(
                            "`{document}` no longer writes `{line}`, for which Swift said \"{swift_says}\""
                        ));
                    }
                }
            }
            Err(errors) => problems.push(format!(
                "`{document}` is refused now:\n  {}",
                errors.join("\n  ")
            )),
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn the_names_read_from_the_rules_are_the_ones_the_rules_apply() {
    let keywords = escaped_keywords();
    for keyword in &keywords {
        assert_eq!(
            escape(keyword),
            format!("`{keyword}`"),
            "`{keyword}` is read as a keyword `escape` lists"
        );
    }
    // Every name `names.rs` spells that `escape` escapes was read as one of
    // its keywords, so the reading misses none.
    for literal in string_literals(include_str!("../names.rs")) {
        if is_identifier(&literal) && escape(&literal) != literal {
            assert!(
                keywords.contains(&literal),
                "`escape` escapes `{literal}`, which was not read as one of its keywords"
            );
        }
    }
    for (name, _) in hostile_names() {
        if call_label(&name) != name {
            assert!(
                keywords.contains(&name),
                "`call_label` escapes `{name}`, which `escape` does not"
            );
        }
    }
    // Every local alias the generated code declares was read as one.
    let aliases = local_aliases();
    assert_eq!(aliases.len(), 6, "{aliases:?}");
    let mut declared = BTreeSet::new();
    for (file, text) in super::emit_swift_tests() {
        for line in text.lines() {
            let Some(rest) = line.trim_start().strip_prefix("typealias ") else {
                continue;
            };
            let alias = rest.split(' ').next().unwrap_or_default().to_string();
            assert!(
                aliases.contains(&alias),
                "{file} declares the local alias `{alias}`, which was not read as one"
            );
            declared.insert(alias);
        }
    }
    for alias in ["Fragment", "Spread", "Query"] {
        assert!(
            declared.contains(alias),
            "no body of the test target declares the local alias `{alias}`: {declared:?}"
        );
    }
    let scopes = scope_names();
    for name in ["anchor", "variables", "variable", "schemaDigest", "Data"] {
        assert!(
            scopes.iter().any(|known| known == name),
            "`{name}` was not read as a name `decide` declares: {scopes:?}"
        );
    }
}

/// What a line of generated Swift declares or binds that the generated
/// code chose: a property or local with an initializer, a local alias, a
/// computed property off the main actor, and a method with its parameters.
/// An initializer's and an action's parameters are the document's.
fn generated_declarations(line: &str) -> Vec<String> {
    let mut names = Vec::new();
    let trimmed = line.trim_start();
    if trimmed.starts_with("//") {
        return names;
    }
    for keyword in ["let ", "var "] {
        let mut rest = trimmed;
        while let Some(found) = rest.find(keyword) {
            let before = rest[..found].chars().next_back();
            rest = &rest[found + keyword.len()..];
            if before.is_some_and(|character| character.is_alphanumeric() || character == '_') {
                continue;
            }
            let name: String = rest
                .chars()
                .take_while(|character| character.is_alphanumeric() || *character == '_')
                .collect();
            let after = &rest[name.len()..];
            let initialized = match (after.find(" = "), after.find('{')) {
                (Some(equals), Some(brace)) => equals < brace,
                (Some(_), None) => true,
                (None, _) => false,
            };
            let computed = !trimmed.starts_with("@MainActor")
                && keyword == "var "
                && after.starts_with(':')
                && after.trim_end().ends_with('{');
            if !name.is_empty() && (initialized || computed) {
                names.push(name);
            }
        }
    }
    if let Some(rest) = trimmed.strip_prefix("typealias ") {
        names.push(rest.split(' ').next().unwrap_or_default().to_string());
    }
    if let Some(found) = trimmed.find("func ") {
        let rest = &trimmed[found + "func ".len()..];
        let name = rest.split(['(', ' ']).next().unwrap_or_default();
        if name != "callAsFunction" {
            if is_identifier(name) {
                names.push(name.to_string());
            }
            let parameters = rest
                .split_once('(')
                .and_then(|(_, rest)| rest.split_once(')'))
                .map(|(parameters, _)| parameters)
                .unwrap_or_default();
            for parameter in parameters.split(", ").filter(|text| !text.is_empty()) {
                let (head, _) = parameter.split_once(':').unwrap_or((parameter, ""));
                if let Some(local) = head.split(' ').next_back()
                    && local != "_"
                {
                    names.push(local.to_string());
                }
            }
        }
    }
    names
}

#[test]
fn every_name_the_generated_code_declares_or_binds_is_a_hostile_name() {
    let names = hostile_names();
    let mut problems = BTreeSet::new();
    let mut found = BTreeSet::new();
    for (file, text) in super::emit_swift_tests() {
        if file == "Baton.baton.swift" {
            continue;
        }
        // An operation's text is the document's, between its delimiters.
        let mut in_text = false;
        for line in text.lines() {
            if line.contains("\"\"\"") {
                in_text = !in_text;
                if !in_text {
                    continue;
                }
            }
            if in_text && !line.contains("\"\"\"") {
                continue;
            }
            for name in generated_declarations(line) {
                // A name numbered past another of its own, as `selfValue2`.
                let base = name.trim_end_matches(|character: char| character.is_ascii_digit());
                found.insert(base.to_string());
                if !names
                    .iter()
                    .any(|(known, _)| known == &name || known == base)
                {
                    problems.insert(format!(
                        "{file} declares `{name}`, which is no hostile name: add it to `GENERATED_NAMES` and to every position"
                    ));
                }
            }
        }
    }
    assert!(
        problems.is_empty(),
        "{}",
        problems.into_iter().collect::<Vec<_>>().join("\n")
    );
    // What every kind of body declares, so the reading misses none of them.
    for name in [
        "anchor",
        "bound",
        "errors",
        "child",
        "missing",
        "count",
        "fields",
        "selfValue",
        "lhs",
        "rhs",
        "hasher",
        "Fragment",
        "Query",
        "typeName",
        "resolution",
        "variables",
        "variable",
        "refetch",
        "loadNext",
        "fieldErrors",
    ] {
        assert!(
            found.contains(name),
            "the generated code declares `{name}`, which its reading missed: {found:?}"
        );
    }
}
