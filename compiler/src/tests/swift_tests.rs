use super::*;

const SAMPLE: &str = r#"import Baton

/// A row. The "quotes" in this comment and the @Fragment( here are ignored.
struct CharacterRow {
    let title = "not a @Query(\"document\") either"

    @Fragment("""
        fragment CharacterRow_character on Character {
          name
        }
        """)
    var character: CharacterRow_character

    @Query("query Tiny { character(id: 1) { id } }") private var tiny: TinyQuery
}
"#;

#[test]
fn finds_both_literal_forms_and_the_property_after_each() {
    let (documents, errors) = scan(SAMPLE);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(documents.len(), 2);

    let fragment = &documents[0];
    assert_eq!(fragment.marker, Marker::Fragment);
    assert_eq!(fragment.attribute, Position { line: 7, column: 5 });
    assert_eq!(fragment.start, Position { line: 8, column: 1 });
    assert_eq!(
        fragment.text,
        "        fragment CharacterRow_character on Character {\n          name\n        }"
    );
    assert_eq!(
        fragment.property,
        Some(Property {
            name: "character".into(),
            type_name: "CharacterRow_character".into()
        })
    );

    let query = &documents[1];
    assert_eq!(query.marker, Marker::Query);
    assert_eq!(
        query.start,
        Position {
            line: 14,
            column: 13
        }
    );
    assert_eq!(query.text, "query Tiny { character(id: 1) { id } }");
    assert_eq!(
        query
            .property
            .as_ref()
            .map(|property| property.type_name.as_str()),
        Some("TinyQuery")
    );
}

#[test]
fn text_positions_map_straight_onto_file_positions() {
    let (documents, _) = scan(SAMPLE);
    let fragment = &documents[0];
    // The word `name` is on the second line of the literal, at the same column as in the file.
    let offset = fragment.text.find("name").unwrap();
    let line_in_text = fragment.text[..offset].matches('\n').count() as u32;
    let column_in_text = (offset
        - fragment.text[..offset]
            .rfind('\n')
            .map(|index| index + 1)
            .unwrap_or(0)) as u32
        + 1;
    assert_eq!(fragment.start.line + line_in_text, 9);
    assert_eq!(column_in_text, 11);
    let file_line = SAMPLE.lines().nth(8).unwrap();
    assert_eq!(
        &file_line[(column_in_text as usize - 1)..(column_in_text as usize + 3)],
        "name"
    );
}

#[test]
fn reports_escapes_and_missing_literals_without_stopping() {
    let source = "@Fragment(\"fragment A on B { \\(x) }\") var a: A\n@Subscription(42) var b: B\n@Mutation(\"mutation M { m }\") var m: M\n";
    let (documents, errors) = scan(source);
    assert_eq!(documents.len(), 2);
    assert_eq!(errors.len(), 2);
    assert!(matches!(errors[0], ScanError::EscapeInLiteral { .. }));
    assert!(matches!(
        errors[1],
        ScanError::MissingLiteral {
            marker: Marker::Subscription,
            ..
        }
    ));
}

#[test]
fn ignores_markers_inside_comments_and_strings() {
    let source = "// @Fragment(\"nope\")\n/* @Query(\"\"\"\nnope\n\"\"\") /* nested */ */\nlet s = \"@Mutation(\\\"nope\\\")\"\nlet r = #\"@Subscription(\"nope\")\"#\n";
    let (documents, errors) = scan(source);
    assert!(documents.is_empty(), "{documents:?}");
    assert!(errors.is_empty(), "{errors:?}");
}

#[test]
fn skips_extra_attribute_arguments_before_the_property() {
    let source = "@Query(\"query Q { a }\", fetchPolicy: .storeOrNetwork) var q: Q\n";
    let (documents, errors) = scan(source);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(documents.len(), 1);
    assert_eq!(documents[0].text, "query Q { a }");
    assert_eq!(
        documents[0]
            .property
            .as_ref()
            .map(|property| property.type_name.as_str()),
        Some("Q")
    );
}

#[test]
fn reads_a_qualified_marker_and_raw_literals() {
    let source = "@Baton.Query(#\"query Q { a(b: \"c\") }\"#) var q: Q\n@Fragment(##\"\"\"\n    fragment F on T { \"#\" a }\n    \"\"\"##) var f: F\n";
    let (documents, errors) = scan(source);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(documents.len(), 2);
    assert_eq!(documents[0].marker, Marker::Query);
    assert_eq!(documents[0].text, "query Q { a(b: \"c\") }");
    assert_eq!(
        documents[0].start,
        Position {
            line: 1,
            column: 16
        }
    );
    assert_eq!(documents[1].text, "    fragment F on T { \"#\" a }");
    assert_eq!(documents[1].start, Position { line: 3, column: 1 });
    assert_eq!(
        documents[1]
            .property
            .as_ref()
            .map(|property| property.type_name.as_str()),
        Some("F")
    );
}

#[test]
fn reports_an_escape_in_a_raw_literal_only_with_its_hashes() {
    let source = "@Query(#\"query Q { a(b: \"\\n\") }\"#) var q: Q\n@Query(#\"query R { \\#(x) }\"#) var r: R\n";
    let (documents, errors) = scan(source);
    assert_eq!(documents.len(), 2);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(matches!(errors[0], ScanError::EscapeInLiteral { at } if at.line == 2));
}

#[test]
fn leaves_a_query_whose_first_argument_is_not_a_literal_to_the_other_macro_of_its_name() {
    let source = "@Query(sort: \\Item.name) var items: [Item]\n@Query(filter: #Predicate<Item> { $0.done }) var done: [Item]\n@Query(FetchDescriptor<Item>()) var all: [Item]\n@Query(Item.recent) var recent: [Item]\n";
    let (documents, errors) = scan(source);
    assert!(documents.is_empty(), "{documents:?}");
    assert!(errors.is_empty(), "{errors:?}");
}

#[test]
fn a_marker_no_other_macro_shares_wants_a_literal_labelled_or_not() {
    let source = "@Baton.Query(Item.recent) var q: Q\n@Fragment(sort: \\Item.name) var f: F\n@Mutation(descriptor) var m: M\n";
    let (documents, errors) = scan(source);
    assert!(documents.is_empty(), "{documents:?}");
    let markers: Vec<Marker> = errors
        .iter()
        .map(|error| match error {
            ScanError::MissingLiteral { marker, .. } => *marker,
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(markers, [Marker::Query, Marker::Fragment, Marker::Mutation]);
}
