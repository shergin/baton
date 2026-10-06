//! Turns the front end's diagnostics into `path:line:column: severity: message`
//! lines, which Xcode and most editors display inline at that position.

use std::fmt::Write as _;

use common::{Diagnostic, SourceLocationKey};
use intern::Lookup;

use crate::documents::Document;
use crate::pipeline::Origin;

/// A rendered diagnostic, ready to print: one line, and a `note:` line for
/// each place it relates to.
#[derive(Debug, Clone)]
pub struct Rendered {
    pub path: String,
    pub line: u32,
    pub column: u32,
    pub severity: &'static str,
    pub message: String,
    pub notes: Vec<Rendered>,
}

impl std::fmt::Display for Rendered {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "{}:{}:{}: {}: {}",
            self.path, self.line, self.column, self.severity, self.message
        )?;
        for note in &self.notes {
            write!(formatter, "\n{note}")?;
        }
        Ok(())
    }
}

/// Renders a front-end diagnostic against the documents it may refer to,
/// the schema among them, so an error in the schema points into its file.
pub fn render(diagnostic: &Diagnostic, documents: &[Document]) -> Rendered {
    let location = diagnostic.location();
    let mut message = String::new();
    let _ = write!(message, "{}", diagnostic.message());
    let (path, line, column) = resolve(
        location.source_location(),
        location.span().start as usize,
        documents,
    );
    let notes = diagnostic
        .related_information()
        .iter()
        .map(|related| {
            let (path, line, column) = resolve(
                related.location.source_location(),
                related.location.span().start as usize,
                documents,
            );
            Rendered {
                path,
                line,
                column,
                severity: "note",
                message: one_line(&related.message.to_string()),
                notes: Vec::new(),
            }
        })
        .collect();
    Rendered {
        path,
        line,
        column,
        severity: "error",
        message: one_line(&message),
        notes,
    }
}

/// A message on one line, as an editor shows a diagnostic: Relay's end in
/// a line of their own with a link.
fn one_line(message: &str) -> String {
    message.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn resolve(key: SourceLocationKey, offset: usize, documents: &[Document]) -> (String, u32, u32) {
    match key {
        SourceLocationKey::Embedded { path, index } => {
            embedded(path.lookup(), index as usize, offset, documents)
        }
        SourceLocationKey::Standalone { path } => {
            let path = path.lookup();
            let document = documents
                .iter()
                .find(|document| document.path.to_string_lossy() == path);
            match document {
                Some(document) => {
                    let position = document.position_of(offset);
                    (path.to_string(), position.line, position.column)
                }
                None => (path.to_string(), 1, 1),
            }
        }
        SourceLocationKey::Generated => ("<generated>".to_string(), 1, 1),
    }
}

/// The position of `offset` in the `index`th document of the file at
/// `path`.
fn embedded(path: &str, index: usize, offset: usize, documents: &[Document]) -> (String, u32, u32) {
    let document = documents
        .iter()
        .find(|document| document.path.to_string_lossy() == path && document.index == index);
    match document {
        Some(document) => {
            let position = document.position_of(offset);
            (path.to_string(), position.line, position.column)
        }
        None => (path.to_string(), 1, 1),
    }
}

/// An error at a name the document wrote, which the compiler found after
/// the front end.
pub fn at(origin: &Origin, documents: &[Document], message: impl Into<String>) -> Rendered {
    positioned(origin, documents, "error", message)
}

/// A warning at a name the document wrote.
pub fn warning_at(origin: &Origin, documents: &[Document], message: impl Into<String>) -> Rendered {
    positioned(origin, documents, "warning", message)
}

fn positioned(
    origin: &Origin,
    documents: &[Document],
    severity: &'static str,
    message: impl Into<String>,
) -> Rendered {
    let (path, line, column) = embedded(
        &origin.path,
        origin.document,
        origin.offset as usize,
        documents,
    );
    Rendered {
        path,
        line,
        column,
        severity,
        message: message.into(),
        notes: Vec::new(),
    }
}

/// A diagnostic the compiler itself produces, already positioned.
pub fn own(
    path: &std::path::Path,
    line: u32,
    column: u32,
    severity: &'static str,
    message: impl Into<String>,
) -> Rendered {
    Rendered {
        path: path.to_string_lossy().into_owned(),
        line,
        column,
        severity,
        message: message.into(),
        notes: Vec::new(),
    }
}

#[cfg(test)]
#[path = "tests/diagnostics_tests.rs"]
mod tests;
