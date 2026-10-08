//! Names Kotlin keeps for itself, or that the generated Kotlin declares or
//! spells, held against every position a document's name can take. In each
//! position the compiler either accepts a name and writes Kotlin that
//! compiles, or refuses it with an error at the name. A name a position
//! inside a document accepts is in the corpus, `HostileKotlinDocuments.kt`
//! beside the other hosts, whose golden `scripts/check-kotlin-goldens.sh`
//! compiles; a name it refuses is in the position's table below; a name it
//! accepts though the Kotlin written for it does not compile is a known
//! defect, recorded below with the line Kotlin refuses until it is fixed.
//! The name of a fragment or an operation is a class of the package, which
//! the corpus holds once, so those positions are proved accepted here and
//! compiled by `scripts/hostile-name-sweep-kotlin.py`.
//!
//! The names are read from the rules where the rules list them: the
//! keywords `escape` knows, the lists `kotlin_names.rs` keeps, the names
//! `KotlinNaming` answers the decide pass with and the names `decide`
//! declares in a scope. A name added to one of them fails here until every
//! position holds it.

use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::documents::Document;
use crate::kotlin_names::{
    BUILDER_RESERVED_NAMES, KEYWORDS, KotlinNaming, LENS_RESERVED_NAMES, MEMBER_NAMES,
    RUNTIME_NAMES, STABLE, STANDARD_LIBRARY_FUNCTIONS, STANDARD_LIBRARY_NAMES, TYPE_KEYWORDS,
    UNDECLARED, escape,
};
use crate::naming::{NameError, Naming, Spelled};
use crate::pipeline::{FragmentPlan, OperationPlan, Plan, SelectionPlan};
use crate::{diagnostics, emit, pipeline};

/// The corpus, as the plan names its source.
pub(super) const CORPUS: &str = "compiler/src/tests/hosts/HostileKotlinDocuments.kt";

/// Kotlin's soft and modifier keywords: identifiers everywhere but where
/// they introduce or modify a declaration. Those that start a type are
/// `TYPE_KEYWORDS`, which `escape` escapes.
const SOFT_KEYWORDS: [&str; 46] = [
    "by",
    "catch",
    "constructor",
    "delegate",
    "field",
    "file",
    "finally",
    "get",
    "import",
    "init",
    "param",
    "property",
    "receiver",
    "set",
    "setparam",
    "value",
    "where",
    "abstract",
    "actual",
    "annotation",
    "companion",
    "const",
    "crossinline",
    "data",
    "enum",
    "expect",
    "external",
    "final",
    "infix",
    "inline",
    "inner",
    "internal",
    "lateinit",
    "noinline",
    "open",
    "operator",
    "override",
    "private",
    "protected",
    "public",
    "reified",
    "sealed",
    "tailrec",
    "vararg",
    "context",
    "dynamic",
];

/// What the generated Kotlin declares, binds or calls that no list of the
/// rules holds.
const GENERATED_NAMES: [&str; 28] = [
    // The methods of a lens.
    "refetch",
    "loadNext",
    "loadPrevious",
    // The locals and lambda parameters of generated bodies.
    "child",
    "missing",
    "other",
    "it",
    "element",
    "count",
    // What an operation's companion and a mutation's action declare or call.
    "optimistic",
    "selection",
    "selection0",
    "commit",
    // What a data class, an enum and a collection give.
    "component1",
    "component2",
    "of",
    "scalarText",
    "size",
    "keys",
    "values",
    "entries",
    // The runtime's list of lenses.
    "LensList",
    // The standard library's functions generated code calls on a value.
    "let",
    "takeIf",
    "map",
    "getOrThrow",
    "success",
    "failure",
];

/// The names `decide` matches in a document rather than declares: the
/// fields a connection's `nodes` reads, the field every record has and the
/// field a refetchable fragment's owner is identified by.
const MATCHED_FIELDS: [&str; 4] = ["__typename", "edges", "id", "node"];

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
const CONNECTION_KEY: &str = "the key of a connection";
const REQUIRED: &str = "a field beside the checks of a required field that bubbles to the root";
const ABSTRACT: &str = "a field of a lens on an interface";
const CAUGHT: &str = "an aliased field under `@catch`";
const REQUIRED_FIELD: &str = "an aliased field under `@required`";
const QUERY_VARIABLE: &str = "a variable of a query";
const MUTATION_VARIABLE: &str = "a variable of a mutation";
const SUBSCRIPTION_VARIABLE: &str = "a variable of a subscription";
const FRAGMENT_ARGUMENT: &str = "an argument of a refetchable fragment";
const SPREAD_ARGUMENT: &str = "an argument a spread passes";
const PAYLOAD_SCALAR: &str = "a scalar field of a mutation's payload";
const PAYLOAD_LINKED: &str = "a linked field of a mutation's payload";
const PAYLOAD_PLURAL: &str = "a plural linked field of a mutation's payload";
const VALUE_SCALAR: &str = "a scalar field of an inline fragment's value";
const VALUE_LINKED: &str = "a linked field of an inline fragment's value";
const VALUE_PLURAL: &str = "a plural linked field of an inline fragment's value";
const VALUE_SPREAD: &str = "an aliased spread of a value inside a value";
const FRAGMENT_NAME: &str = "a fragment's name";
const QUERY_NAME: &str = "a query's name";
const MUTATION_NAME: &str = "a mutation's name";
const SUBSCRIPTION_NAME: &str = "a subscription's name";
const REFETCH_QUERY_NAME: &str = "a refetch query's name";
const QUERY_SPREAD: &str = "the name of a fragment a query spreads";
const MUTATION_SPREAD: &str = "the name of a fragment a mutation spreads";
const LENS_SPREADS: &str = "the name of a fragment a lens spreads in every form";
const INLINE_FRAGMENT_NAME: &str = "an inline fragment's name";
const VALUE_SPREAD_NAME: &str = "the name of an inline fragment a value spreads";
const QUERY_VALUE_SPREADS: &str = "the name of an inline fragment a query spreads in every form";
const VALUE_SPREADS: &str = "the name of an inline fragment a value spreads in every form";

/// A position a document's name can take, and what the compiler makes of a
/// hostile name there.
struct Position {
    name: &'static str,
    /// The names the corpus gives the position. None for the name of a
    /// fragment or an operation, a class of the package, which the corpus
    /// holds once, and for a connection's key: the names such a position
    /// accepts are proved accepted here, and a class's compiled by the
    /// sweep.
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
    /// the generated Kotlin.
    refused: Vec<(String, String)>,
}

/// Names a position accepts though the Kotlin written for them does not
/// compile, as Kotlin 2.4 says: defects of the compiler, kept here until
/// each is fixed, when its names move to the corpus or to the refusals.
struct Defect {
    positions: &'static [&'static str],
    names: &'static [&'static str],
    /// What the Kotlin written for a position's probe holds, with `HOSTILE`
    /// for the name: the line Kotlin refuses, and the declaration that
    /// makes it refuse it when that is another.
    writes: &'static [&'static str],
    /// What Kotlin says of the line.
    kotlin: &'static str,
}

/// The names a scope of the generated Kotlin declares, and how a refusal
/// calls them.
const ANCHOR: (&str, &str) = ("anchor", "the `anchor` every lens has");
const RECORD_ID: (&str, &str) = ("recordID", "the `recordID` every lens has");
const EQUALS: (&str, &str) = ("equals", "the `equals` every class has");
const HASH_CODE: (&str, &str) = ("hashCode", "the `hashCode` every class has");
const TO_STRING: (&str, &str) = ("toString", "the `toString` every class has");
const LENS_COMPANION: (&str, &str) = ("Companion", "the lens's companion object `Companion`");
const RUNTIME_VARIABLE: (&str, &str) = ("Variable", "the runtime's `Variable`");
const RUNTIME_VARIABLES: (&str, &str) = ("Variables", "the runtime's `Variables`");
const RUNTIME_RESOLUTION: (&str, &str) = ("Resolution", "the runtime's `Resolution`");
const TYPES: (&str, &str) = ("Types", "the shared object `Types`");
const SLOTS: (&str, &str) = ("Slots", "the shared object `Slots`");
const SITES: (&str, &str) = ("Sites", "the shared object `Sites`");
const GUARDS: (&str, &str) = ("Guards", "the shared object `Guards`");
const ABSTRACT_SLOTS: (&str, &str) = ("AbstractSlots", "the shared object `AbstractSlots`");
const VARIABLE: (&str, &str) = ("variable", "the optimistic response's `variable`");
const VARIABLES: (&str, &str) = ("variables", "the operation's `variables`");
const TYPE: (&str, &str) = ("type", "the operation's `type`");
const RESOLUTION: (&str, &str) = ("resolution", "the operation's `resolution`");
const DATA: (&str, &str) = ("Data", "the operation's root lens `Data`");
const OPTIMISTIC_RESPONSE: (&str, &str) =
    ("OptimisticResponse", "the mutation's `OptimisticResponse`");
const OPERATION_COMPANION: (&str, &str) =
    ("Companion", "the operation's companion object `Companion`");

/// What every lens refuses a field: what it declares, and the runtime's
/// types its getters and builders spell.
const LENS: [(&str, &str); 8] = [
    ANCHOR,
    RECORD_ID,
    EQUALS,
    HASH_CODE,
    TO_STRING,
    LENS_COMPANION,
    RUNTIME_VARIABLE,
    RUNTIME_VARIABLES,
];

/// What every operation's value refuses a variable.
const OPERATION: [(&str, &str); 9] = [
    VARIABLES,
    TYPE,
    RUNTIME_VARIABLE,
    RUNTIME_VARIABLES,
    EQUALS,
    HASH_CODE,
    TO_STRING,
    DATA,
    OPERATION_COMPANION,
];

fn owned(names: &[(&str, &str)]) -> Vec<(String, String)> {
    names
        .iter()
        .map(|(name, what)| (name.to_string(), what.to_string()))
        .collect()
}

/// What the package's top level refuses a fragment's or an operation's
/// name: what Kotlin's naming keeps there, the runtime's package and the
/// shared objects every program declares.
fn top_level() -> Vec<(String, String)> {
    let naming = KotlinNaming::default();
    let mut names: Vec<(String, String)> = naming
        .module_names()
        .into_iter()
        .map(|(name, what)| (name.to_string(), what))
        .collect();
    for spelled in [Spelled::Runtime, Spelled::Types, Spelled::Slots] {
        names.push((
            naming.spelling(spelled).to_string(),
            naming.description(spelled),
        ));
    }
    names
}

fn positions() -> Vec<Position> {
    type Refused<'a> = &'a [(&'static str, &'static str)];
    let lens = |extra: Refused| [&LENS[..], extra].concat();
    let field = |name, corpus, probe, refused: Vec<(&str, &str)>| Position {
        name,
        corpus: Some(corpus),
        probe,
        at: "HOSTILE:",
        what: "the field `HOSTILE`",
        remedy: "choose another alias",
        refused: owned(&refused),
    };
    let selection = |name, corpus, probe, refused: Vec<(&str, &str)>| Position {
        name,
        corpus: Some(corpus),
        probe,
        at: "\"HOSTILE\"",
        what: "the selection aliased `HOSTILE`",
        remedy: "choose another alias",
        refused: owned(&refused),
    };
    let variable = |name, corpus, probe, at, refused: Vec<(&str, &str)>| Position {
        name,
        corpus: Some(corpus),
        probe,
        at,
        what: "the variable `$HOSTILE`",
        remedy: "rename the variable",
        refused: owned(&refused),
    };
    // A fragment's or an operation's name, which the package's top level
    // refuses, and the types of an operation that spreads the fragment.
    let named = |name, probe, at, what, remedy, nested: Refused| Position {
        name,
        corpus: None,
        probe,
        at,
        what,
        remedy,
        refused: [top_level(), owned(nested)].concat(),
    };
    vec![
        field(
            SCALAR,
            scalar_names,
            "fragment Probe_character on Character { HOSTILE: name }",
            lens(&[SLOTS]),
        ),
        field(
            LINKED,
            linked_names,
            "fragment Probe_character on Character { HOSTILE: origin { id } }",
            lens(&[SLOTS]),
        ),
        selection(
            SELECTION,
            selection_names,
            r#"fragment Probe_character on Character { ... @alias(as: "HOSTILE") { name } }"#,
            lens(&[SLOTS]),
        ),
        selection(
            SPREAD,
            spread_names,
            r#"fragment ProbeTarget_character on Character { name } fragment Probe_character on Character { ... @alias(as: "HOSTILE") { ...ProbeTarget_character } }"#,
            lens(&[]),
        ),
        field(
            BODIES,
            bodies_names,
            r#"fragment ProbeBound_character on Character @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) { name @include(if: $flag) origin @required(action: NONE) { id } } fragment ProbeDeferred_character on Character { name } fragment ProbeCaught_character on Character { name } fragment Probe_character on Character @refetchable(queryName: "ProbeRefetchQuery") @throwOnFieldError { HOSTILE: name species @required(action: THROW) origin @required(action: NONE) { name @required(action: NONE) } ...ProbeBound_character @arguments(flag: false) ...ProbeDeferred_character @defer ... @alias(as: "caughtSpread") @catch { ...ProbeCaught_character } }"#,
            lens(&[TYPES, SLOTS, SITES]),
        ),
        field(
            CONNECTION,
            connection_names,
            r#"fragment Probe_character on Character @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) @refetchable(queryName: "ProbeRefetchQuery") { notes(first: $count, after: $cursor) @connection(key: "Probe_notes") { HOSTILE: totalCount edges { node { id } } } }"#,
            lens(&[
                ("hasNext", "the connection's `hasNext`"),
                ("hasPrevious", "the connection's `hasPrevious`"),
                ("isLoadingNext", "the connection's `isLoadingNext`"),
                ("isLoadingPrevious", "the connection's `isLoadingPrevious`"),
                ("connectionID", "the connection's `connectionID`"),
                TYPES,
                SLOTS,
            ]),
        ),
        // A key is written only inside string literals, so the names it
        // accepts are proved accepted, not compiled.
        Position {
            name: CONNECTION_KEY,
            corpus: None,
            probe: r#"fragment Probe_character on Character { notes_HOSTILE: notes(first: 2) @connection(key: "HOSTILE_notes_HOSTILE") { edges { node { id } } } }"#,
            at: "\"HOSTILE_",
            what: "the connection key `HOSTILE`",
            remedy: "choose another key",
            refused: Vec::new(),
        },
        field(
            REQUIRED,
            required_names,
            "query Probe { character(id: 1) @required(action: NONE) { HOSTILE: name origin @required(action: NONE) { name @required(action: NONE) } } }",
            lens(&[TYPES, SLOTS]),
        ),
        field(
            ABSTRACT,
            abstract_names,
            "fragment Probe_node on Node { HOSTILE: id ... on Character { status } }",
            lens(&[TYPES, SLOTS, ABSTRACT_SLOTS]),
        ),
        field(
            CAUGHT,
            caught_names,
            "fragment Probe_character on Character { HOSTILE: name @catch }",
            lens(&[SLOTS]),
        ),
        field(
            REQUIRED_FIELD,
            required_field_names,
            "fragment Probe_character on Character { HOSTILE: name @required(action: LOG) }",
            lens(&[SLOTS]),
        ),
        variable(
            QUERY_VARIABLE,
            query_variable_names,
            "query Probe($HOSTILE: ID!) @throwOnFieldError { charactersByIds(ids: [$HOSTILE]) { id } }",
            "$HOSTILE",
            [&OPERATION[..], &[RESOLUTION, RUNTIME_RESOLUTION]].concat(),
        ),
        variable(
            MUTATION_VARIABLE,
            mutation_variable_names,
            r#"mutation Probe($HOSTILE: Boolean!) { setFavorite(id: "1", favorite: true) @catch { character { id ... @include(if: $HOSTILE) { name } } } }"#,
            "$HOSTILE",
            [&OPERATION[..], &[OPTIMISTIC_RESPONSE]].concat(),
        ),
        variable(
            SUBSCRIPTION_VARIABLE,
            subscription_variable_names,
            r#"subscription Probe($HOSTILE: Boolean!) { noteAdded(characterId: "1") @catch { noteEdge { node { id } ... @include(if: $HOSTILE) { cursor } } } }"#,
            "$HOSTILE",
            [&OPERATION[..], &[RESOLUTION, RUNTIME_RESOLUTION]].concat(),
        ),
        variable(
            FRAGMENT_ARGUMENT,
            fragment_argument_names,
            r#"fragment Probe_character on Character @argumentDefinitions(HOSTILE: {type: "Boolean", defaultValue: true}) @refetchable(queryName: "ProbeRefetchQuery") { ... @include(if: $HOSTILE) { name } }"#,
            "HOSTILE:",
            [&OPERATION[..], &[RESOLUTION, RUNTIME_RESOLUTION]].concat(),
        ),
        // An argument a spread passes is one the spread fragment defines,
        // so it is refused where it is defined.
        variable(
            SPREAD_ARGUMENT,
            spread_argument_names,
            r#"fragment ProbeTarget_character on Character @argumentDefinitions(HOSTILE: {type: "Boolean", defaultValue: true}) @refetchable(queryName: "ProbeRefetchQuery") { ... @include(if: $HOSTILE) { name } } fragment Probe_character on Character { ...ProbeTarget_character @arguments(HOSTILE: false) }"#,
            "HOSTILE:",
            [&OPERATION[..], &[RESOLUTION, RUNTIME_RESOLUTION]].concat(),
        ),
        field(
            PAYLOAD_SCALAR,
            payload_scalar_names,
            r#"mutation Probe { setFavorite(id: "1", favorite: true) { character { HOSTILE: name } } }"#,
            lens(&[SLOTS, VARIABLE]),
        ),
        field(
            PAYLOAD_LINKED,
            payload_linked_names,
            r#"mutation Probe { addNote(characterId: "1", text: "hostile") { HOSTILE: note { id } } }"#,
            lens(&[SLOTS, VARIABLE]),
        ),
        field(
            PAYLOAD_PLURAL,
            payload_plural_names,
            r#"mutation Probe { rename(id: "1", name: "hostile") { character { HOSTILE: episode { id } } } }"#,
            lens(&[SLOTS, VARIABLE]),
        ),
        // A value's properties, beside every body a value can have: the
        // checks of `@throwOnFieldError`, and `isPresent` and `caught` for a
        // deferred and a caught spread of it.
        field(
            VALUE_SCALAR,
            value_scalar_names,
            r#"fragment Probe_character on Character @inline @throwOnFieldError { HOSTILE: name } query ProbeReach { character(id: 1) { ...Probe_character @defer ... @alias(as: "caughtValue") @catch { ...Probe_character } } }"#,
            lens(&[SLOTS]),
        ),
        field(
            VALUE_LINKED,
            value_linked_names,
            r#"fragment Probe_character on Character @inline @throwOnFieldError { HOSTILE: origin { id } } query ProbeReach { character(id: 1) { ...Probe_character @defer ... @alias(as: "caughtValue") @catch { ...Probe_character } } }"#,
            lens(&[SLOTS]),
        ),
        field(
            VALUE_PLURAL,
            value_plural_names,
            r#"fragment Probe_character on Character @inline @throwOnFieldError { HOSTILE: episode { id } } query ProbeReach { character(id: 1) { ...Probe_character @defer ... @alias(as: "caughtValue") @catch { ...Probe_character } } }"#,
            lens(&[SLOTS]),
        ),
        selection(
            VALUE_SPREAD,
            value_spread_names,
            r#"fragment ProbeTarget_character on Character @inline { name } fragment Probe_character on Character @inline @throwOnFieldError { ... @alias(as: "HOSTILE") { ...ProbeTarget_character } } query ProbeReach { character(id: 1) { ...Probe_character @defer ... @alias(as: "caughtValue") @catch { ...Probe_character } } }"#,
            lens(&[]),
        ),
        named(
            FRAGMENT_NAME,
            "fragment HOSTILE on Character { name }",
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[],
        ),
        named(
            QUERY_NAME,
            "query HOSTILE { character(id: 1) { id } }",
            HOSTILE,
            "the query `HOSTILE`",
            "rename the query",
            &[],
        ),
        named(
            MUTATION_NAME,
            r#"mutation HOSTILE { setFavorite(id: "1", favorite: true) { character { id } } }"#,
            HOSTILE,
            "the mutation `HOSTILE`",
            "rename the mutation",
            &[],
        ),
        named(
            SUBSCRIPTION_NAME,
            r#"subscription HOSTILE { noteAdded(characterId: "1") { noteEdge { cursor } } }"#,
            HOSTILE,
            "the subscription `HOSTILE`",
            "rename the subscription",
            &[],
        ),
        named(
            REFETCH_QUERY_NAME,
            r#"fragment Probe_character on Character @refetchable(queryName: "HOSTILE") { name }"#,
            "Probe_character",
            "the refetch query `HOSTILE`",
            "name it otherwise in `@refetchable(queryName:)`",
            &[],
        ),
        named(
            QUERY_SPREAD,
            "fragment HOSTILE on Character { name } query Probe { character(id: 1) { ...HOSTILE } }",
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[],
        ),
        named(
            MUTATION_SPREAD,
            r#"fragment HOSTILE on Character { name } mutation Probe { setFavorite(id: "1", favorite: true) { character { ...HOSTILE } } }"#,
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[OPTIMISTIC_RESPONSE],
        ),
        // Plainly, with arguments, caught under an alias and under `@defer`.
        named(
            LENS_SPREADS,
            r#"fragment HOSTILE on Character @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError { name @include(if: $flag) } fragment ProbeSpreader_character on Character { ... @alias(as: "boundSpread") { ...HOSTILE @arguments(flag: false) } ...HOSTILE ... @alias(as: "caughtSpread") @catch { ...HOSTILE } } query ProbeDeferred { character(id: 1) { ...HOSTILE @defer } }"#,
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[SITES, GUARDS],
        ),
        named(
            INLINE_FRAGMENT_NAME,
            "fragment HOSTILE on Character @inline { name }",
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[],
        ),
        named(
            VALUE_SPREAD_NAME,
            "fragment HOSTILE on Character @inline { name } fragment Probe_character on Character @inline { ...HOSTILE }",
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[],
        ),
        // Plainly, with arguments, under a condition with an alias, caught
        // under an alias and under `@defer`.
        named(
            QUERY_VALUE_SPREADS,
            r#"fragment HOSTILE on Character @inline @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) @throwOnFieldError { name @include(if: $flag) } query Probe($flag: Boolean!) { character(id: 1) { ...HOSTILE ...HOSTILE @arguments(flag: false) @alias(as: "boundValue") ...HOSTILE @include(if: $flag) @alias(as: "conditionalValue") ... @alias(as: "caughtValue") @catch { ...HOSTILE } } } query ProbeDeferred { character(id: 1) { ...HOSTILE @defer } }"#,
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[SITES, GUARDS],
        ),
        // With arguments, under a condition with an alias and caught under
        // an alias, inside a value whose errors include them.
        named(
            VALUE_SPREADS,
            r#"fragment HOSTILE on Character @inline @argumentDefinitions(flag: {type: "Boolean!", defaultValue: true}) { name @include(if: $flag) } fragment Probe_character on Character @inline @throwOnFieldError @argumentDefinitions(withName: {type: "Boolean!", defaultValue: true}) { id ...HOSTILE @arguments(flag: false) @alias(as: "boundValue") ...HOSTILE @include(if: $withName) @alias(as: "conditionalValue") ... @alias(as: "caughtValue") @catch { ...HOSTILE } } query Probe { character(id: 1) { ...Probe_character } }"#,
            HOSTILE,
            "the fragment `HOSTILE`",
            "rename the fragment",
            &[SITES, GUARDS],
        ),
    ]
}

fn defects() -> Vec<Defect> {
    vec![
        // A lens nested in an operation sees the members of the operation's
        // companion, the plan's selections among them, so a fragment named
        // like one is read as the selection where the lens names the
        // fragment's class. The selections are numbered, so no list of
        // names refuses them; holding them in a scope no lens sees fixes it.
        Defect {
            positions: &[LENS_SPREADS, QUERY_VALUE_SPREADS],
            names: &["selection0"],
            writes: &[
                "private val HOSTILE_ = HOSTILE",
                "private val HOSTILE: Selection by lazy {",
            ],
            kotlin: "unresolved reference 'isPresent' on receiver of type 'Selection'.",
        },
    ]
}

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

/// The fragment `name` and the values numbered after it, which share a
/// position's names: a value's reading constructor is one JVM method.
fn values<'a>(plan: &'a Plan, stem: &str) -> Vec<&'a FragmentPlan> {
    ["", "2", "3"]
        .into_iter()
        .map(|number| fragment(plan, &format!("{stem}{number}_character")))
        .collect()
}

fn scalar_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "KotlinScalars_character").reader, "name")
}

fn linked_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "KotlinLinks_character").reader, "origin")
}

fn selection_names(plan: &Plan) -> Vec<String> {
    inline_aliases(&fragment(plan, "KotlinSelections_character").reader, false)
}

fn spread_names(plan: &Plan) -> Vec<String> {
    inline_aliases(&fragment(plan, "KotlinSpreads_character").reader, true)
}

fn bodies_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "KotlinBodies_character").reader, "name")
}

fn connection_names(plan: &Plan) -> Vec<String> {
    let reader = &fragment(plan, "KotlinConnection_character").reader;
    aliases_of(inside(reader, "notes"), "totalCount")
}

fn required_names(plan: &Plan) -> Vec<String> {
    aliases_of(
        inside(&operation(plan, "KotlinRequired").reader, "character"),
        "name",
    )
}

fn abstract_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "KotlinAbstract_node").reader, "id")
}

fn caught_names(plan: &Plan) -> Vec<String> {
    aliases_of(&fragment(plan, "KotlinCaught_character").reader, "name")
}

fn required_field_names(plan: &Plan) -> Vec<String> {
    aliases_of(
        &fragment(plan, "KotlinRequiredFields_character").reader,
        "name",
    )
}

fn variable_names(operation: &OperationPlan) -> Vec<String> {
    operation
        .variables
        .iter()
        .map(|variable| variable.name.clone())
        .collect()
}

fn query_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "KotlinVariables"))
}

fn mutation_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "KotlinMutationVariables"))
}

fn subscription_variable_names(plan: &Plan) -> Vec<String> {
    variable_names(operation(plan, "KotlinSubscriptionVariables"))
}

fn fragment_argument_names(plan: &Plan) -> Vec<String> {
    fragment(plan, "KotlinArguments_character")
        .arguments
        .iter()
        .map(|argument| argument.name.clone())
        .collect()
}

fn spread_argument_names(plan: &Plan) -> Vec<String> {
    fragment(plan, "KotlinArgumentSpread_character")
        .reader
        .iter()
        .flat_map(|selection| match selection {
            SelectionPlan::Spread { arguments, .. } => arguments
                .iter()
                .map(|argument| argument.name.clone())
                .collect(),
            _ => Vec::new(),
        })
        .collect()
}

fn payload_scalar_names(plan: &Plan) -> Vec<String> {
    let payload = &operation(plan, "KotlinPayload").reader;
    aliases_of(inside(inside(payload, "setFavorite"), "character"), "name")
}

fn payload_linked_names(plan: &Plan) -> Vec<String> {
    let payload = &operation(plan, "KotlinPayload").reader;
    aliases_of(inside(payload, "addNote"), "note")
}

fn payload_plural_names(plan: &Plan) -> Vec<String> {
    let payload = &operation(plan, "KotlinPayload").reader;
    aliases_of(inside(inside(payload, "rename"), "character"), "episode")
}

fn value_scalar_names(plan: &Plan) -> Vec<String> {
    values(plan, "KotlinInlineScalars")
        .into_iter()
        .flat_map(|value| aliases_of(&value.reader, "name"))
        .collect()
}

fn value_linked_names(plan: &Plan) -> Vec<String> {
    values(plan, "KotlinInlineLinks")
        .into_iter()
        .flat_map(|value| aliases_of(&value.reader, "origin"))
        .collect()
}

fn value_plural_names(plan: &Plan) -> Vec<String> {
    values(plan, "KotlinInlinePlurals")
        .into_iter()
        .flat_map(|value| aliases_of(&value.reader, "episode"))
        .collect()
}

fn value_spread_names(plan: &Plan) -> Vec<String> {
    values(plan, "KotlinInlineSpreads")
        .into_iter()
        .flat_map(|value| inline_aliases(&value.reader, true))
        .collect()
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

/// What the shared objects, an input object and an enum keep, which
/// `kotlin_names.rs` lists privately.
fn spelled_lists() -> Vec<String> {
    let source = include_str!("../kotlin_names.rs");
    [
        "const TYPES_SPELLED",
        "const SLOTS_SPELLED",
        "const INPUT_SPELLED",
        "const ENUM_SPELLED",
    ]
    .into_iter()
    .flat_map(|declaration| array_literals(source, declaration))
    .collect()
}

/// The names `KotlinNaming` answers the decide pass with: the spellings of
/// the generated families and what an operation's value and every lens
/// declare, read from its source.
fn naming_names() -> Vec<String> {
    let source = include_str!("../kotlin_names.rs");
    let start = source
        .find("    fn spelling(")
        .expect("`KotlinNaming` answers `spelling`");
    let end = source
        .find("#[cfg(test)]")
        .expect("`kotlin_names.rs` ends with its tests");
    string_literals(&source[start..end])
        .into_iter()
        .filter(|literal| is_identifier(literal))
        .collect()
}

/// The names `decide` declares in the scopes of lenses, operations and
/// builders, read from its source.
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
    let stable = STABLE.rsplit('.').next().unwrap_or(STABLE);
    let sources = [
        (listed(&KEYWORDS), "a keyword `escape` lists"),
        (listed(&["_"]), "a name of underscores alone"),
        (listed(&TYPE_KEYWORDS), "a soft keyword that starts a type"),
        (listed(&SOFT_KEYWORDS), "a soft or modifier keyword"),
        (listed(&RUNTIME_NAMES), "a name of `RUNTIME_NAMES`"),
        (
            listed(&STANDARD_LIBRARY_NAMES),
            "a name of `STANDARD_LIBRARY_NAMES`",
        ),
        (
            listed(&STANDARD_LIBRARY_FUNCTIONS),
            "a name of `STANDARD_LIBRARY_FUNCTIONS`",
        ),
        (
            MEMBER_NAMES
                .iter()
                .map(|(name, _)| name.to_string())
                .collect(),
            "a name of `MEMBER_NAMES`",
        ),
        (
            listed(&LENS_RESERVED_NAMES),
            "a name of `LENS_RESERVED_NAMES`",
        ),
        (
            listed(&BUILDER_RESERVED_NAMES),
            "a name of `BUILDER_RESERVED_NAMES`",
        ),
        (
            spelled_lists(),
            "a name a shared object, an input or an enum keeps",
        ),
        (
            listed(&[UNDECLARED, stable]),
            "a name the generated code declares",
        ),
        (naming_names(), "a name `KotlinNaming` answers with"),
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

/// What the compiler makes of `text` as the one document of a program: the
/// Kotlin it writes, or its errors as `batonc` prints them.
fn compile(text: &str) -> Result<emit::Output, Vec<String>> {
    let config = super::kotlin_tests_config();
    let config_path = super::repository().join("swift/Tests/BatonTests/baton.json");
    let schema_path = config.schema_path(&config_path);
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let documents = [Document {
        path: PathBuf::from(PROBE),
        index: 0,
        start: crate::documents::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    }];
    let extensions = super::schema_extensions(&config, &config_path);
    let plan = match pipeline::compile(
        &schema,
        &schema_path.to_string_lossy(),
        &extensions,
        &documents,
        &config,
    ) {
        Ok(compiled) => compiled.plan,
        Err(errors) => {
            return Err(errors
                .iter()
                .map(|error| diagnostics::render(error, &documents).to_string())
                .collect());
        }
    };
    crate::emit::kotlin::kotlin(&plan, &config, Default::default()).map_err(|errors| {
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

/// The Kotlin written for `text`, every file of it.
fn kotlin(output: &emit::Output) -> String {
    let mut text: String = output.files.values().cloned().collect();
    text.push_str(&output.shared);
    text
}

/// `probe` with the document's own names numbered by `index`, so that
/// several probes make one program.
fn numbered(probe: &str, index: usize) -> String {
    probe.replace("Probe", &format!("Probe{index}"))
}

/// The names a defect records for `position`.
fn known_defects(defects: &[Defect], position: &str) -> Vec<String> {
    defects
        .iter()
        .filter(|defect| defect.positions.contains(&position))
        .flat_map(|defect| defect.names.iter().map(|name| name.to_string()))
        .collect()
}

#[test]
fn every_kotlin_hostile_name_is_in_the_corpus_or_refused_or_a_known_defect_in_every_position() {
    let (plan, _) = super::compile_kotlin_tests();
    let names = hostile_names();
    let defects = defects();
    let mut problems = Vec::new();
    for position in positions() {
        let corpus = position.corpus.map(|names| names(&plan));
        let known = known_defects(&defects, position.name);
        for (name, _) in &position.refused {
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
                // `a_kotlin_top_level_name_neither_refused_nor_a_defect_is_accepted`
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
fn a_name_refused_in_kotlin_is_an_error_at_the_name_that_says_what_it_clashes_with_and_what_to_do()
{
    let mut problems = Vec::new();
    for position in positions() {
        for (name, clashes) in &position.refused {
            let probe = position.probe.replace(HOSTILE, name);
            let at = position.at.replace(HOSTILE, name);
            let column = probe
                .find(&at)
                .expect("the probe holds what a refusal points at")
                + 1;
            let what = position.what.replace(HOSTILE, name);
            let expected = format!(
                "{PROBE}:1:{column}: error: {what} clashes with {clashes} in the generated Kotlin; {}",
                position.remedy
            );
            // A name can clash with two declarations of a scope; each error
            // is at the name and says what to do.
            let at_the_name = format!("{PROBE}:1:{column}: error: {what} clashes with ");
            match compile(&probe) {
                Ok(_) => problems.push(format!("{}: `{name}` is accepted", position.name)),
                Err(errors)
                    if errors.contains(&expected)
                        && errors.iter().all(|error| {
                            error.starts_with(&at_the_name)
                                && error.ends_with(&format!(
                                    " in the generated Kotlin; {}",
                                    position.remedy
                                ))
                        }) => {}
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
fn a_kotlin_top_level_name_neither_refused_nor_a_defect_is_accepted() {
    let names = hostile_names();
    let defects = defects();
    for position in positions()
        .into_iter()
        .filter(|position| position.corpus.is_none())
    {
        let known = known_defects(&defects, position.name);
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
fn a_known_kotlin_defect_is_still_accepted_and_still_writes_the_kotlin_recorded_for_it() {
    let positions = positions();
    let mut problems = Vec::new();
    for defect in defects() {
        for name in defect.positions {
            let position = positions
                .iter()
                .find(|position| position.name == *name)
                .unwrap_or_else(|| panic!("a defect names the unknown position `{name}`"));
            let names = defect.names;
            // The names of a position make one program, and each writes its
            // own lines.
            let program: Vec<String> = names
                .iter()
                .enumerate()
                .map(|(index, name)| numbered(position.probe, index).replace(HOSTILE, name))
                .collect();
            let written = match compile(&program.join("\n")) {
                Ok(output) => kotlin(&output),
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
                            "{}: `{hostile}` no longer writes `{line}`, for which Kotlin said \"{}\"; if its Kotlin compiles now, move it to the corpus",
                            position.name, defect.kotlin
                        ));
                    }
                }
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn the_kotlin_names_read_from_the_rules_are_the_ones_the_rules_apply() {
    for keyword in KEYWORDS.iter().chain(&TYPE_KEYWORDS).chain(&["_"]) {
        assert_eq!(
            escape(keyword),
            format!("`{keyword}`"),
            "`{keyword}` is read as a name `escape` escapes"
        );
    }
    // Every other hostile name is an identifier as it is.
    for (name, _) in hostile_names() {
        if escape(&name) != name {
            assert!(
                KEYWORDS.contains(&name.as_str())
                    || TYPE_KEYWORDS.contains(&name.as_str())
                    || name == "_",
                "`escape` escapes `{name}`, which was not read as one of its keywords"
            );
        }
    }
    let naming = naming_names();
    for name in [
        "Types",
        "Companion",
        "Data",
        "variables",
        "resolution",
        "anchor",
        "recordID",
    ] {
        assert!(
            naming.iter().any(|known| known == name),
            "`{name}` was not read as a name `KotlinNaming` answers with: {naming:?}"
        );
    }
    let spelled = spelled_lists();
    for name in ["schemaDigest", "DynamicKey", "copy", "GeneratedEnum"] {
        assert!(
            spelled.iter().any(|known| known == name),
            "`{name}` was not read from the lists `kotlin_names.rs` keeps: {spelled:?}"
        );
    }
}

/// What a line of generated Kotlin declares or binds that the generated
/// code chose: an override, a function and its parameters, a property or a
/// local with an initializer, a selection of a plan, a lambda's parameter,
/// and a property after a KDoc line, which a lens's own members have and a
/// document's accessors do not. A class's constructor's and an action's
/// parameters are the document's, and so is a companion's reference to a
/// class a property hides.
fn generated_declarations(line: &str, after_kdoc: bool) -> Vec<String> {
    let mut names = Vec::new();
    let trimmed = line.trim_start();
    let trimmed = trimmed
        .strip_prefix("@Generated ")
        .unwrap_or(trimmed)
        .trim_start();
    if trimmed.starts_with("//")
        || trimmed.starts_with("/**")
        || trimmed.starts_with("class ")
        || trimmed.starts_with("data class ")
        || trimmed.starts_with("import ")
    {
        return names;
    }
    let identifier = |text: &str| -> String {
        text.chars()
            .take_while(|character| character.is_alphanumeric() || *character == '_')
            .collect()
    };
    for keyword in ["override val ", "override var ", "override fun "] {
        if let Some(rest) = trimmed.strip_prefix(keyword) {
            names.push(identifier(rest));
        }
    }
    if let Some(found) = trimmed.find("fun ") {
        let rest = &trimmed[found + "fun ".len()..];
        let head = rest.split('(').next().unwrap_or_default();
        let name = head.rsplit('.').next().unwrap_or_default();
        if is_identifier(name) {
            names.push(name.to_string());
        }
        let parameters = rest
            .split_once('(')
            .and_then(|(_, rest)| rest.split_once(')'))
            .map(|(parameters, _)| parameters)
            .unwrap_or_default();
        let parameters: Vec<&str> = parameters
            .split(", ")
            .filter(|text| !text.is_empty())
            .collect();
        // An action's parameters are the mutation's variables but the last,
        // the optimistic response.
        let chosen = if name == "invoke" {
            &parameters[parameters.len().saturating_sub(1)..]
        } else {
            &parameters[..]
        };
        for parameter in chosen {
            let local = parameter.split(':').next().unwrap_or_default().trim();
            if is_identifier(local) {
                names.push(local.to_string());
            }
        }
    }
    for keyword in ["val ", "var "] {
        let mut rest = trimmed;
        while let Some(found) = rest.find(keyword) {
            let before = rest[..found].chars().next_back();
            rest = &rest[found + keyword.len()..];
            if before.is_some_and(|character| character.is_alphanumeric() || character == '_') {
                continue;
            }
            let name = identifier(rest);
            let after = &rest[name.len()..];
            let alias = trimmed.starts_with("private val ")
                && after.starts_with(" = ")
                && is_identifier(after[" = ".len()..].trim_matches('`'));
            let declared = after.starts_with(" = ")
                || after.contains(" by lazy")
                || (after_kdoc && after.starts_with(':'));
            if !name.is_empty() && declared && !alias {
                names.push(name);
            }
        }
    }
    let mut rest = trimmed;
    while let Some(found) = rest.find(" ->") {
        let head = &rest[..found];
        if let Some(open) = head.rfind("{ ") {
            let name = &head[open + 2..];
            if is_identifier(name) {
                names.push(name.to_string());
            }
        }
        rest = &rest[found + " ->".len()..];
    }
    names
}

#[test]
fn every_name_the_generated_kotlin_declares_or_binds_is_a_hostile_name() {
    let names = hostile_names();
    let mut problems = BTreeSet::new();
    let mut found = BTreeSet::new();
    for (file, text) in super::emit_kotlin_tests() {
        if file == "Baton.baton.kt" {
            continue;
        }
        let mut after_kdoc = false;
        for line in text.lines() {
            // A document's text is a string the declarations do not read.
            let line = match line.find("Document.Text(") {
                Some(start) => &line[..start],
                None => line,
            };
            for name in generated_declarations(line, after_kdoc) {
                // A name numbered past another of its own, as `selection12`.
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
            after_kdoc =
                line.trim_start().starts_with("/**") || (after_kdoc && line.trim() == "@Generated");
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
        "other",
        "element",
        "variables",
        "variable",
        "payload",
        "resolution",
        "type",
        "name",
        "document",
        "plan",
        "selection",
        "data",
        "equals",
        "hashCode",
        "invoke",
        "optimistic",
        "satisfied",
        "missingRequiredField",
        "fieldErrors",
        "throwing",
        "caught",
        "isPresent",
        "refetchable",
        "refetch",
        "loadNext",
        "nodes",
        "hasNext",
        "connectionID",
        "count",
    ] {
        assert!(
            found.contains(name),
            "the generated Kotlin declares `{name}`, which its reading missed: {found:?}"
        );
    }
}
