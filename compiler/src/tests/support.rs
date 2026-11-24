//! What the tests of several modules share. Each test module that needs it
//! includes this file as its own `support` module.

use crate::pipeline::{SchemaFile, SchemaSources};

/// The schema of one file, `text` at `path`, without client extensions:
/// what `batonc` reads from a `--schema` that names one file.
pub(crate) fn one_file(text: &str, path: &str) -> SchemaSources {
    SchemaSources {
        schema: vec![SchemaFile::new(text, path)],
        extensions: Vec::new(),
    }
}
