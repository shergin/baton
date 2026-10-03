//! `baton.json`: the schema's location and the identity configuration the
//! compiler bakes into plans.

use std::path::{Path, PathBuf};

/// A root field that returns an entity addressable by one of its arguments.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Lookup {
    /// `Type.field`, e.g. `Query.character`.
    pub field: String,
    /// The entity type the field returns, e.g. `Character`. Omitted for fields
    /// that return an interface such as `Node`: the entity is then found by id
    /// across types.
    #[serde(rename = "type", default)]
    pub type_name: Option<String>,
    /// The argument that carries the entity's key, e.g. `id`.
    pub argument: String,
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct Config {
    /// Path of the schema SDL, relative to the configuration file.
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub lookups: Vec<Lookup>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("batonc: cannot read {}: {error}", path.display()))?;
        serde_json::from_str(&text).map_err(|error| format!("batonc: {}: {error}", path.display()))
    }

    /// The schema path resolved against the configuration file's directory.
    pub fn schema_path(&self, config_path: &Path) -> PathBuf {
        config_path
            .parent()
            .map(|directory| directory.join(&self.schema))
            .unwrap_or_else(|| PathBuf::from(&self.schema))
    }
}
