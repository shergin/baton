//! Tests of what a concrete type's lens sees under an abstract selection:
//! the selections of each interface or union condition whose types include
//! its type, under that condition's guards, while the condition keeps its
//! own lens; an aliased or deferred condition stays a selection of its own.

use super::*;

/// The emitted Swift of `text` against the test schema under an empty
/// configuration: the files of its definitions.
fn emitted(text: &str) -> String {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled = compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan)
        .unwrap_or_else(|errors| panic!("the document declares names twice: {errors:?}"));
    output.files.into_values().collect::<Vec<_>>().join("\n")
}

/// The declaration of the first lens named `name` in `swift`, from its
/// opening line to its closing brace, nested lenses included.
fn lens<'a>(swift: &'a str, name: &str) -> &'a str {
    let opening = format!("nonisolated public struct {name}: Baton.Lens {{");
    let start = swift
        .find(&opening)
        .unwrap_or_else(|| panic!("no lens `{name}` in:\n{swift}"));
    let line_start = swift[..start].rfind('\n').map_or(0, |index| index + 1);
    let indent = &swift[line_start..start];
    let closing = format!("\n{indent}}}\n");
    let end = swift[start..]
        .find(&closing)
        .unwrap_or_else(|| panic!("the lens `{name}` does not close in:\n{swift}"));
    &swift[line_start..start + end + closing.len()]
}

const SEARCH: &str = "query Probe($withStatus: Boolean!) { search(name: \"a\") { __typename ... on Named { name } ... on Character { status @include(if: $withStatus) } ... on Episode { episode } } }";

#[test]
fn a_concrete_lens_reads_the_fields_of_an_interface_condition_its_type_satisfies() {
    let swift = emitted(SEARCH);
    let character = lens(&swift, "AsCharacter");
    assert!(
        character.contains("public var status: String? { anchor.owner.selects(Guards.withStatus_true) ? anchor.string(Slots.Character.status) : nil }"),
        "{character}"
    );
    assert!(
        character.contains("public var name: String? { anchor.string(Slots.Character.name) }"),
        "{character}"
    );
}

#[test]
fn a_concrete_lens_of_a_type_outside_the_interface_reads_none_of_its_fields() {
    let swift = emitted(SEARCH);
    let episode = lens(&swift, "AsEpisode");
    assert!(
        episode.contains("public var episode: String? { anchor.string(Slots.Episode.episode) }"),
        "{episode}"
    );
    assert!(!episode.contains("var name"), "{episode}");
}

#[test]
fn the_interface_condition_keeps_its_own_lens() {
    let swift = emitted(SEARCH);
    assert!(
        swift.contains("public var asNamed: AsNamed? { Types.Named_possible.includes(anchor.record.type) ? AsNamed(anchor: anchor) : nil }"),
        "{swift}"
    );
    let named = lens(&swift, "AsNamed");
    assert!(
        named.contains(
            "public var name: String? { anchor.string(AbstractSlots.Named.name.on(anchor.record.type)) }"
        ),
        "{named}"
    );
}

#[test]
fn a_field_a_concrete_lens_takes_from_a_guarded_interface_condition_keeps_its_guard() {
    let swift = emitted(
        "query Probe($flag: Boolean!) { search(name: \"a\") { __typename ... on Named @include(if: $flag) { name } ... on Character { status } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(
        character.contains("public var name: String? { anchor.owner.selects(Guards.flag_true) ? anchor.string(Slots.Character.name) : nil }"),
        "{character}"
    );
    assert!(
        character.contains("public var status: String? { anchor.string(Slots.Character.status) }"),
        "{character}"
    );
}

#[test]
fn a_field_the_concrete_condition_selects_unguarded_stays_unguarded_beside_a_guarded_copy() {
    let swift = emitted(
        "query Probe($flag: Boolean!) { search(name: \"a\") { __typename ... on Named @include(if: $flag) { name } ... on Character { name } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert_eq!(character.matches("var name").count(), 1, "{character}");
    assert!(
        character.contains("public var name: String? { anchor.string(Slots.Character.name) }"),
        "{character}"
    );
}

#[test]
fn a_union_condition_whose_types_exclude_the_concrete_type_adds_nothing_to_its_lens() {
    let swift = emitted(
        "query Probe { node(id: \"1\") { id ... on Note { text } ... on SearchResult { __typename ... on Episode { episode } } } }",
    );
    let note = lens(&swift, "AsNote");
    assert!(
        note.contains("public var text: String? { anchor.string(Slots.Note.text) }"),
        "{note}"
    );
    assert!(!note.contains("episode"), "{note}");
    assert!(!note.contains("asEpisode"), "{note}");
}

#[test]
fn an_interface_condition_whose_types_exclude_the_concrete_type_adds_nothing_to_its_lens() {
    let swift =
        emitted("query Probe { spellings { ... on Episode { id } ... on Spelled { label } } }");
    let episode = lens(&swift, "AsEpisode");
    assert!(!episode.contains("label"), "{episode}");
    assert!(lens(&swift, "AsSpelled").contains("var label"), "{swift}");
}

#[test]
fn an_aliased_interface_condition_is_not_copied_into_a_concrete_lens() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ... on Named @alias(as: \"named\") { name } ... on Character { status } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(!character.contains("var name"), "{character}");
    assert!(!character.contains("var named"), "{character}");
    assert!(
        lens(&swift, "Named").contains("var name"),
        "the aliased condition keeps its lens: {swift}"
    );
}

#[test]
fn a_deferred_spread_on_an_interface_is_not_copied_into_a_concrete_lens() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ...ProbeName @defer @alias ... on Character { status } } } fragment ProbeName on Named { name }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(!character.contains("ProbeName"), "{character}");
    assert!(
        lens(&swift, "ProbeNameLens")
            .contains("guard Fragment.isPresent(anchor) else { return nil }"),
        "{swift}"
    );
}

#[test]
fn a_fragment_spread_under_an_interface_condition_is_read_by_the_concrete_lens() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ... on Named { ...ProbeName @alias } ... on Character { status } } } fragment ProbeName on Named { name }",
    );
    let accessor = "public var probeName: ProbeName { .init(anchor: anchor.entering()) }";
    assert!(lens(&swift, "AsCharacter").contains(accessor), "{swift}");
    assert!(lens(&swift, "AsNamed").contains(accessor), "{swift}");
}

#[test]
fn a_type_condition_the_concrete_type_satisfies_folds_into_its_lens_instead_of_nesting() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ... on Character { status } ... on Named { ... on Character { species } } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(
        character
            .contains("public var species: String? { anchor.string(Slots.Character.species) }"),
        "{character}"
    );
    assert!(!character.contains("asCharacter"), "{character}");
    assert_eq!(character.matches("Baton.Lens {").count(), 1, "{character}");
    assert!(
        lens(&swift, "AsNamed").contains("public var asCharacter: AsCharacter?"),
        "the interface condition keeps its own nested lens: {swift}"
    );
}

#[test]
fn a_linked_field_a_folded_condition_selects_again_merges_into_one_lens() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ... on Character { origin { id } } ... on Named { ... on Character { origin { name } } } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert_eq!(character.matches("var origin").count(), 1, "{character}");
    let origin = lens(character, "Origin");
    assert!(
        origin.contains("public var id: String? { anchor.string(Slots.Location.id) }"),
        "{origin}"
    );
    assert!(
        origin.contains("public var name: String? { anchor.string(Slots.Location.name) }"),
        "{origin}"
    );
    assert!(!character.contains("asCharacter"), "{character}");
}

#[test]
fn a_type_condition_the_concrete_type_does_not_satisfy_is_dropped_from_its_lens() {
    let swift = emitted(
        "query Probe { node(id: \"1\") { id ... on Character { status } ... on SearchResult { __typename ... on Episode { episode } } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(!character.contains("asEpisode"), "{character}");
    assert!(!character.contains("episode"), "{character}");
    assert!(
        lens(&swift, "AsSearchResult").contains("public var asEpisode: AsEpisode?"),
        "the union condition keeps its own nested lens: {swift}"
    );
}

#[test]
fn a_type_condition_under_a_guard_folds_into_the_concrete_lens_under_that_guard() {
    let swift = emitted(
        "query Probe($flag: Boolean!) { search(name: \"a\") { __typename ... on Character { status } ... on Named { ... @include(if: $flag) { ... on Character { species } } } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(
        character.contains("public var species: String? { anchor.owner.selects(Guards.flag_true) ? anchor.string(Slots.Character.species) : nil }"),
        "{character}"
    );
    assert!(
        character.contains("public var status: String? { anchor.string(Slots.Character.status) }"),
        "{character}"
    );
    assert!(!character.contains("asCharacter"), "{character}");
}

#[test]
fn an_aliased_type_condition_stays_a_lens_of_its_own_inside_the_concrete_lens() {
    let swift = emitted(
        "query Probe { search(name: \"a\") { __typename ... on Character { status } ... on Named { ... on Character @alias(as: \"self\") { species } } } }",
    );
    let character = lens(&swift, "AsCharacter");
    assert!(
        character.contains("public var `self`: SelfLens? { anchor.record.is(Types.Character) ? SelfLens(anchor: anchor) : nil }"),
        "{character}"
    );
    assert!(
        lens(character, "SelfLens").contains("var species"),
        "{character}"
    );
    assert_eq!(
        character.matches("var species").count(),
        1,
        "species is read only through the alias: {character}"
    );
}
