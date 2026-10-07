//! Collects every GraphQL document the compiler will see: literals embedded in
//! the files of a host language and standalone `.graphql` files, each
//! remembering where it came from so diagnostics can point back into the host
//! file. A host language is a `HostLanguage`, found by the extension of its
//! files; Swift's is `swift::SwiftHost`.

use std::fmt;
use std::path::{Path, PathBuf};

use crate::diagnostics::Rendered;
use crate::pipeline::Plan;
use crate::swift::SwiftHost;

/// A language whose source files hold GraphQL documents: how the documents
/// are found in a file, what the output a source writes is named, and what
/// the host files are checked for once the documents compile.
pub trait HostLanguage: Sync {
    /// The extensions of the language's source files, without the dot.
    fn extensions(&self) -> &'static [&'static str];

    /// The documents embedded in `source`, and each problem the scan found
    /// with where it is. A problem does not stop the scan.
    fn scan(&self, source: &str) -> (Vec<EmbeddedDocument>, Vec<(Position, String)>);

    /// The name of the output `source` writes, a source of any language,
    /// unique among the sources under `root`.
    fn output_name(&self, source: &Path, root: &Path) -> String;

    /// The name of the shared file.
    fn shared_output_name(&self) -> &'static str;

    /// Whether `path` names an output the compiler writes in this language,
    /// which an output directory may hold from an earlier run.
    fn is_output(&self, path: &Path) -> bool;

    /// What the language's host files are checked for once their documents
    /// compile to `plan`, as warnings.
    fn check(&self, documents: &[Document], plan: &Plan) -> Vec<Rendered>;
}

/// The host languages the compiler reads.
pub const HOSTS: [&dyn HostLanguage; 1] = [&SwiftHost];

/// The host language whose files have the extension of `path`.
pub fn host_of(path: &Path) -> Option<&'static dyn HostLanguage> {
    let extension = extension(path);
    HOSTS
        .into_iter()
        .find(|host| host.extensions().contains(&extension))
}

/// The marker that introduced an embedded document.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum Marker {
    Fragment,
    Query,
    Mutation,
    Subscription,
}

impl fmt::Display for Marker {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Marker::Fragment => "@Fragment",
            Marker::Query => "@Query",
            Marker::Mutation => "@Mutation",
            Marker::Subscription => "@Subscription",
        })
    }
}

/// A 1-based position in a source file. Columns count characters.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Position {
    pub line: u32,
    pub column: u32,
}

/// The property declaration that follows a marker, when there is one.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Property {
    pub name: String,
    /// The written type, e.g. `CharacterRow_character` or `Foo?`.
    pub type_name: String,
}

/// One GraphQL document found inside a host file.
#[derive(Clone, Debug, serde::Serialize)]
pub struct EmbeddedDocument {
    pub marker: Marker,
    /// Where the marker starts.
    pub attribute: Position,
    /// Where the first character of `text` sits in the file.
    pub start: Position,
    /// The literal's content, verbatim.
    pub text: String,
    pub property: Option<Property>,
}

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
    /// The marker and property, when the document came from a host file.
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
    #[error("{path}:{line}:{column}: error: {message}")]
    Scan {
        path: PathBuf,
        line: u32,
        column: u32,
        message: String,
    },
}

/// Reads the given files. A host language's files are scanned for its
/// markers; `.graphql` and `.gql` files are taken whole; anything else is
/// ignored.
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
        if let Some(host) = host_of(path) {
            let (embedded, problems) = host.scan(&source);
            for (position, message) in problems {
                errors.push(CollectError::Scan {
                    path: path.clone(),
                    line: position.line,
                    column: position.column,
                    message,
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
            continue;
        }
        match extension(path) {
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
