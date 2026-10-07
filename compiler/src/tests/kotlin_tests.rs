//! Tests of the Kotlin host: the markers found in each form of string
//! literal, the value each form reads as, the `$$` a document with a
//! variable needs, and the positions a document's text maps back to.

use super::*;

/// The fixture host: the four markers, one in each form of string literal.
const FIXTURE: &str = include_str!("hosts/NotesScreen.kt");

fn scanned(source: &str) -> Vec<EmbeddedDocument> {
    let (documents, errors) = scan(source);
    assert!(errors.is_empty(), "{errors:?}");
    documents
}

#[test]
fn the_fixture_holds_one_document_per_marker_in_each_string_form() {
    let documents = scanned(FIXTURE);
    let markers: Vec<Marker> = documents.iter().map(|document| document.marker).collect();
    assert_eq!(
        markers,
        [
            Marker::Fragment,
            Marker::Query,
            Marker::Mutation,
            Marker::Subscription
        ]
    );
    assert!(
        documents
            .iter()
            .all(|document| document.package.as_deref() == Some("com.example.notes"))
    );
}

#[test]
fn a_plain_string_reads_as_its_value_with_the_escapes_decoded() {
    let fragment = &scanned(FIXTURE)[0];
    assert_eq!(
        fragment.text,
        "fragment NoteRow_note on Note {\n  id\n  text\n}"
    );
    assert_eq!(
        fragment.attribute,
        Position {
            line: 14,
            column: 1
        }
    );
    assert_eq!(
        fragment.start,
        Position {
            line: 14,
            column: 12
        }
    );
}

#[test]
fn a_raw_string_reads_dedented_without_its_blank_first_and_last_lines() {
    let query = &scanned(FIXTURE)[1];
    assert_eq!(
        query.text,
        "query NotesScreenQuery {\n  character(id: \"1\") {\n    id\n    name\n  }\n}"
    );
    assert_eq!(
        query.start,
        Position {
            line: 19,
            column: 5
        }
    );
    assert_eq!(query.indentation, 4);
}

#[test]
fn a_multi_dollar_raw_string_keeps_a_variable_as_text() {
    let mutation = &scanned(FIXTURE)[2];
    assert!(
        mutation.text.starts_with(
            "mutation AddNoteMutation($characterId: ID!, $text: String!) {\n  addNote("
        )
    );
    assert!(mutation.text.ends_with("\n}"));
}

#[test]
fn a_multi_dollar_plain_string_under_the_qualified_marker_keeps_a_variable_as_text() {
    let subscription = &scanned(FIXTURE)[3];
    assert_eq!(subscription.marker, Marker::Subscription);
    assert_eq!(
        subscription.text,
        "subscription NoteAddedSubscription($characterId: ID!) { noteAdded(characterId: $characterId) { character { id } } }"
    );
}

#[test]
fn a_position_in_a_dedented_text_maps_to_its_column_in_the_file() {
    let embedded = scanned(FIXTURE).remove(1);
    let document = Document {
        path: "NotesScreen.kt".into(),
        index: 1,
        start: embedded.start,
        text: embedded.text.clone(),
        embedded: Some(embedded),
    };
    let offset = document
        .text
        .find("name")
        .expect("the query selects `name`");
    assert_eq!(
        document.position_of(offset),
        Position {
            line: 22,
            column: 9
        }
    );
}

#[test]
fn dedent_removes_the_indentation_the_non_blank_lines_share() {
    let (text, start, indentation) = dedent(
        "\n      query Q {\n\n        id\n      }\n    ",
        Position {
            line: 3,
            column: 10,
        },
    );
    assert_eq!(text, "query Q {\n\n  id\n}");
    assert_eq!(start, Position { line: 4, column: 7 });
    assert_eq!(indentation, 6);
}

#[test]
fn dedent_keeps_a_first_line_that_is_not_blank() {
    let (text, start, indentation) = dedent(
        "query Q { id }",
        Position {
            line: 2,
            column: 11,
        },
    );
    assert_eq!(text, "query Q { id }");
    assert_eq!(
        start,
        Position {
            line: 2,
            column: 11
        }
    );
    assert_eq!(indentation, 0);
}

#[test]
fn a_variable_in_a_raw_string_without_dollars_is_an_error_at_the_marker() {
    let source = "@Query(\"\"\"\n    query Q($id: ID!) { node(id: $id) { id } }\n    \"\"\")\nfun Screen() {}\n";
    let (documents, errors) = scan(source);
    assert_eq!(documents.len(), 1);
    assert_eq!(
        errors,
        [ScanError::Variable {
            at: Position { line: 1, column: 1 }
        }]
    );
    assert_eq!(
        errors[0].to_string(),
        "a document with a variable needs a `$$` string"
    );
}

#[test]
fn a_variable_in_a_plain_string_without_dollars_is_an_error_at_the_marker() {
    let source = "  @Fragment(\"fragment F on Note @argumentDefinitions(n: {type: \\\"Int\\\"}) { id }\")\n  @Query(\"query Q(${'$'}id: ID!) { node(id: $id) { id } }\")\n";
    let (_, errors) = scan(source);
    assert_eq!(
        errors,
        [ScanError::Variable {
            at: Position { line: 2, column: 3 }
        }]
    );
}

#[test]
fn an_escaped_dollar_in_a_plain_string_is_text() {
    let documents = scanned("@Query(\"query Q(\\$id: ID!) { node(id: \\$id) { id } }\")\n");
    assert_eq!(
        documents[0].text,
        "query Q($id: ID!) { node(id: $id) { id } }"
    );
}

#[test]
fn a_run_of_fewer_dollars_than_the_prefix_is_text() {
    let documents = scanned("@Query($$$\"\"\"query Q($id: ID!, $$n: Int) { id }\"\"\")\n");
    assert_eq!(documents[0].text, "query Q($id: ID!, $$n: Int) { id }");
}

#[test]
fn a_template_in_a_multi_dollar_string_is_an_error_at_the_marker() {
    let (_, errors) = scan("@Query($$\"query Q { node(id: $$id) { id } }\")\n");
    assert_eq!(
        errors,
        [ScanError::Template {
            at: Position { line: 1, column: 1 }
        }]
    );
}

#[test]
fn a_bare_query_imported_from_another_library_is_not_a_document() {
    let source = "import androidx.room.Query\n\n@Query(\"SELECT * FROM notes\")\nfun all(): List<Note>\n\n@baton.Query(\"query Q { id }\")\nfun Screen() {}\n";
    let documents = scanned(source);
    assert_eq!(documents.len(), 1);
    assert_eq!(documents[0].text, "query Q { id }");
}

#[test]
fn a_marker_without_a_string_is_an_error() {
    let (_, errors) = scan("@Fragment(DOCUMENT)\nfun Row() {}\n");
    assert_eq!(
        errors,
        [ScanError::MissingLiteral {
            marker: Marker::Fragment,
            at: Position {
                line: 1,
                column: 11
            }
        }]
    );
}

#[test]
fn an_unknown_escape_is_an_error_at_the_escape() {
    let (_, errors) = scan("@Query(\"query Q { a\\qb }\")\n");
    assert_eq!(
        errors,
        [ScanError::UnknownEscape {
            escape: 'q',
            at: Position {
                line: 1,
                column: 20
            }
        }]
    );
}

#[test]
fn a_unicode_escape_reads_as_its_character() {
    let documents = scanned("@Query(\"query Q { \\u0069d }\")\n");
    assert_eq!(documents[0].text, "query Q { id }");
}

#[test]
fn a_file_without_a_package_declares_none() {
    let documents = scanned("@Query(\"query Q { id }\")\nfun Screen() {}\n");
    assert_eq!(documents[0].package, None);
}

#[test]
fn a_kotlin_host_writes_its_output_beside_its_name() {
    let host = KotlinHost;
    assert_eq!(
        host.output_name(Path::new("app/ui/Screen.kt"), Path::new("app")),
        "ui_Screen.baton.kt"
    );
    assert_eq!(
        host.output_name(Path::new("app/Screen.graphql"), Path::new("app")),
        "Screen.graphql.baton.kt"
    );
    assert!(host.is_output(Path::new("out/Screen.baton.kt")));
    assert!(!host.is_output(Path::new("out/Screen.baton.swift")));
}
