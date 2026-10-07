//! Tests of where a diagnostic points and how it reads.

use std::path::PathBuf;

use super::*;
use crate::config::Config;
use crate::pipeline;

fn document(text: &str) -> Document {
    Document {
        path: PathBuf::from("Screen.swift"),
        index: 0,
        start: crate::documents::Position {
            line: 10,
            column: 5,
        },
        text: text.to_string(),
        embedded: None,
    }
}

#[test]
fn an_error_in_the_schema_points_at_its_line_in_the_schema_file() {
    let sdl = "type Query {\n  a: A\n}\n\ntype A {\n  b: String\n  c: Missing\n}\n";
    let Err(diagnostics) = pipeline::compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Q { a { b } }")],
        &Config::default(),
    ) else {
        panic!("the schema names a type it does not define");
    };
    let rendered = render(&diagnostics[0], &[Document::schema("schema.graphql", sdl)]);
    assert_eq!(
        (rendered.path.as_str(), rendered.line),
        ("schema.graphql", 7)
    );
}

#[test]
fn an_error_in_a_document_points_at_its_place_in_the_host_file_on_one_line() {
    let sdl = "type Query { a: String }";
    let source = document("query Q {\n  b\n}");
    let Err(diagnostics) = pipeline::compile(
        sdl,
        "schema.graphql",
        &[],
        std::slice::from_ref(&source),
        &Config::default(),
    ) else {
        panic!("the query selects a field the schema does not have");
    };
    let rendered = render(&diagnostics[0], &[source]);
    assert_eq!((rendered.line, rendered.column), (11, 3));
    assert!(!rendered.message.contains('\n'), "{}", rendered.message);
    assert!(
        rendered
            .to_string()
            .starts_with("Screen.swift:11:3: error: ")
    );
}
