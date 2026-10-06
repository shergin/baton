//! `baton.json`: the schema's location and the identity configuration the
//! compiler bakes into plans.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// A root field that returns an entity addressable by one of its arguments.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Lookup {
    /// `Type.field`, e.g. `Query.character`.
    pub field: String,
    /// The entity type the field returns, e.g. `Character`. Omitted for fields
    /// that return an interface such as `Node`: the entity is then found by id
    /// across types.
    #[serde(rename = "type", default)]
    pub type_name: Option<String>,
    /// The argument that carries the entity's key, e.g. `id`: the one
    /// spelling for a key of one field.
    #[serde(default)]
    pub argument: Option<String>,
    /// The arguments that carry the key's fields, in the order of the type's
    /// key fields, for a key of several.
    #[serde(default)]
    pub arguments: Vec<String>,
}

impl Lookup {
    /// The arguments the lookup reads, in the key's order; empty when the
    /// configuration names none or both spellings.
    pub fn arguments(&self) -> Vec<&str> {
        match (&self.argument, self.arguments.is_empty()) {
            (Some(argument), true) => vec![argument.as_str()],
            (None, false) => self.arguments.iter().map(String::as_str).collect(),
            _ => Vec::new(),
        }
    }
}

/// Which fields identify a record of a type: the list tried for every object
/// type, and the types, or interfaces whose implementers, with a list of
/// their own. A key is own scalar fields, in order, and does not rename: it
/// is their values at the write.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    #[serde(default = "default_key")]
    pub default: Vec<String>,
    #[serde(default)]
    pub types: BTreeMap<String, Vec<String>>,
}

impl Default for Identity {
    fn default() -> Self {
        Identity {
            default: default_key(),
            types: BTreeMap::new(),
        }
    }
}

impl Identity {
    /// Whether the configuration keys as the runtime always did, by `id`,
    /// so that the schema's digest stays what it was.
    pub fn is_default(&self) -> bool {
        *self == Identity::default()
    }

    /// The configuration as one text, for the digest an image is versioned
    /// by: a new keying is a miss, not a merge of two.
    pub fn canonical(&self) -> String {
        let mut text = self.default.join(",");
        for (name, fields) in &self.types {
            text.push('\n');
            text.push_str(name);
            text.push(':');
            text.push_str(&fields.join(","));
        }
        text
    }
}

fn default_key() -> Vec<String> {
    vec!["id".to_string()]
}

/// The GraphQL specification's `onError` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum OnError {
    Propagate,
    Null,
    Abort,
}

impl OnError {
    /// The case of `Baton.ErrorBehavior` that names it.
    pub fn swift_case(self) -> &'static str {
        match self {
            OnError::Propagate => "propagate",
            OnError::Null => "null",
            OnError::Abort => "abort",
        }
    }
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Path of the schema SDL, relative to the configuration file.
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub lookups: Vec<Lookup>,
    /// The fields that key a record of each type.
    #[serde(default)]
    pub identity: Identity,
    /// Relay's `schemaExtensions`: files, or directories of `.graphql` files,
    /// beside the configuration, which give server types client fields or
    /// declare types the server does not have. A client field is written by
    /// a payload committed by hand and never asked of a server.
    #[serde(rename = "schemaExtensions", default)]
    pub schema_extensions: Vec<String>,
    /// Relay's `customScalarTypes`: the Swift type a custom scalar reads as,
    /// by the scalar's name, e.g. `"Decimal": "Foundation.Decimal"`. The
    /// store keeps the text; the accessor converts at the read, and says the
    /// conversion can fail. An unmapped custom scalar reads as `String`.
    #[serde(rename = "customScalarTypes", default)]
    pub custom_scalar_types: BTreeMap<String, String>,
    /// The `onError` request parameter every operation sends: `PROPAGATE`,
    /// `NULL` or `ABORT`. Under `NULL` a server nulls an errored field in
    /// place, so a field the schema types non-null is typed by its semantic
    /// nullability: non-null only where errors are handled.
    #[serde(rename = "onError", default)]
    pub on_error: Option<OnError>,
    /// Where the configuration was read from, for its diagnostics.
    #[serde(skip)]
    pub path: PathBuf,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("batonc: cannot read {}: {error}", path.display()))?;
        let mut config: Config = serde_json::from_str(&text)
            .map_err(|error| format!("batonc: {}: {error}", path.display()))?;
        config.path = path.to_path_buf();
        Ok(config)
    }

    /// The schema path resolved against the configuration file's directory.
    pub fn schema_path(&self, config_path: &Path) -> PathBuf {
        config_path
            .parent()
            .map(|directory| directory.join(&self.schema))
            .unwrap_or_else(|| PathBuf::from(&self.schema))
    }
}
