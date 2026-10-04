//! Collects every GraphQL document the compiler will see: literals embedded in
//! Swift files and standalone `.graphql` files, each remembering where it came
//! from so diagnostics can point back into the host file.

use std::path::{Path, PathBuf};

use crate::swift::{self, EmbeddedDocument, Position, ScanError};

/// One GraphQL source text and the place it lives.
#[derive(Clone, Debug, serde::Serialize)]
pub struct Document {
    pub path: PathBuf,
    /// Index of this document among those embedded in the same file; `0` for a
    /// standalone `.graphql` file. Feeds `SourceLocationKey::Embedded`.
    pub index: usize,
    /// Position of the text's first character inside the host file.
    pub start: Position,
    pub text: String,
    /// The Swift marker and property, when the document came from Swift.
    pub embedded: Option<EmbeddedDocument>,
}

/// A problem found while reading or scanning a file.
#[derive(Debug, thiserror::Error)]
pub enum CollectError {
    #[error("{path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("{path}:{line}:{column}: error: {error}")]
    Scan {
        path: PathBuf,
        line: u32,
        column: u32,
        error: ScanError,
    },
}

/// Reads the given files. Swift files are scanned for marker attributes;
/// `.graphql` and `.gql` files are taken whole; anything else is ignored.
pub fn collect(paths: &[PathBuf]) -> (Vec<Document>, Vec<CollectError>) {
    let mut documents = Vec::new();
    let mut errors = Vec::new();
    for path in paths {
        let source = match std::fs::read_to_string(path) {
            Ok(source) => source,
            Err(error) => {
                errors.push(CollectError::Read {
                    path: path.clone(),
                    source: error,
                });
                continue;
            }
        };
        match extension(path) {
            "swift" => {
                let (embedded, scan_errors) = swift::scan(&source);
                for error in scan_errors {
                    let position = error.position();
                    errors.push(CollectError::Scan {
                        path: path.clone(),
                        line: position.line,
                        column: position.column,
                        error,
                    });
                }
                for (index, document) in embedded.into_iter().enumerate() {
                    documents.push(Document {
                        path: path.clone(),
                        index,
                        start: document.start,
                        text: document.text.clone(),
                        embedded: Some(document),
                    });
                }
            }
            "graphql" | "gql" => documents.push(Document {
                path: path.clone(),
                index: 0,
                start: Position { line: 1, column: 1 },
                text: source,
                embedded: None,
            }),
            _ => {}
        }
    }
    (documents, errors)
}

fn extension(path: &Path) -> &str {
    path.extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
}

impl Document {
    /// The schema as a document, so a diagnostic in it is positioned in its
    /// file like one in a source.
    pub fn schema(path: &str, text: &str) -> Document {
        Document {
            path: PathBuf::from(path),
            index: 0,
            start: Position { line: 1, column: 1 },
            text: text.to_string(),
            embedded: None,
        }
    }

    /// Maps a byte offset inside `text` to a position in the host file.
    pub fn position_of(&self, offset: usize) -> Position {
        let offset = offset.min(self.text.len());
        let before = &self.text[..offset];
        let newlines = before.matches('\n').count() as u32;
        let line_start = before.rfind('\n').map(|index| index + 1).unwrap_or(0);
        let column_in_line = before[line_start..].chars().count() as u32 + 1;
        if newlines == 0 {
            Position {
                line: self.start.line,
                column: self.start.column + column_in_line - 1,
            }
        } else {
            Position {
                line: self.start.line + newlines,
                column: column_in_line,
            }
        }
    }
}
