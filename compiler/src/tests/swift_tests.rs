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
    let source = "@Fragment(\"fragment A on B { \\(x) }\") var a: A\n@Query(42) var b: B\n@Mutation(\"mutation M { m }\") var m: M\n";
    let (documents, errors) = scan(source);
    assert_eq!(documents.len(), 2);
    assert_eq!(errors.len(), 2);
    assert!(matches!(errors[0], ScanError::EscapeInLiteral { .. }));
    assert!(matches!(
        errors[1],
        ScanError::MissingLiteral {
            marker: Marker::Query,
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
