//! Turns the front end's diagnostics into `path:line:column: severity: message`
//! lines, which Xcode and most editors display inline at that position.

use std::fmt::Write as _;

use common::{Diagnostic, SourceLocationKey};
use intern::Lookup;

use crate::documents::Document;

/// A rendered diagnostic, ready to print.
#[derive(Debug, Clone)]
pub struct Rendered {
    pub path: String,
    pub line: u32,
    pub column: u32,
    pub severity: &'static str,
    pub message: String,
}

impl std::fmt::Display for Rendered {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "{}:{}:{}: {}: {}",
            self.path, self.line, self.column, self.severity, self.message
        )
    }
}

/// Renders a front-end diagnostic against the documents it may refer to.
pub fn render(diagnostic: &Diagnostic, documents: &[Document]) -> Rendered {
    let location = diagnostic.location();
    let mut message = String::new();
    let _ = write!(message, "{}", diagnostic.message());
    for related in diagnostic.related_information() {
        let _ = write!(message, "; {}", related.message);
    }
    let (path, line, column) = resolve(
        location.source_location(),
        location.span().start as usize,
        documents,
    );
    Rendered {
        path,
        line,
        column,
        severity: "error",
        message,
    }
}

fn resolve(key: SourceLocationKey, offset: usize, documents: &[Document]) -> (String, u32, u32) {
    match key {
        SourceLocationKey::Embedded { path, index } => {
            let path = path.lookup();
            let document = documents.iter().find(|document| {
                document.path.to_string_lossy() == path && document.index == index as usize
            });
            match document {
                Some(document) => {
                    let position = document.position_of(offset);
                    (path.to_string(), position.line, position.column)
                }
                None => (path.to_string(), 1, 1),
            }
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
    }
}
