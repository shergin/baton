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

/// What never reaches the image, decided at build time like identity: the
/// records of the types named, and the cells, storage keys and fetch stamps
/// of the root fields named, `Query.search`. A record's slot that links to a
/// transient record is left out of its row as well, so nothing on disk names
/// one.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Transient {
    #[serde(default)]
    pub types: Vec<String>,
    #[serde(default)]
    pub fields: Vec<String>,
}

impl Transient {
    pub fn is_empty(&self) -> bool {
        self.types.is_empty() && self.fields.is_empty()
    }

    /// The configuration as one text, for the digest.
    pub fn canonical(&self) -> String {
        let mut types = self.types.clone();
        types.sort();
        let mut fields = self.fields.clone();
        fields.sort();
        format!("types:{}\nfields:{}", types.join(","), fields.join(","))
    }
}

/// Relay's `persistConfig`: where the map from id to text is written, and
/// the hash the id is.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistConfig {
    pub file: String,
    #[serde(default)]
    pub algorithm: Algorithm,
}

/// The hash a persisted id is, as Relay names them; MD5 is Relay's default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Algorithm {
    #[default]
    Md5,
    Sha256,
    Sha1,
}

impl Algorithm {
    /// The id of a text: its hash in lowercase hexadecimal, one string in the
    /// artifact, in the file and on the wire.
    pub fn id(self, text: &str) -> String {
        match self {
            Algorithm::Md5 => format!("{:x}", md5::compute(text.as_bytes())),
            Algorithm::Sha256 => {
                use sha2::Digest;
                format!("{:x}", sha2::Sha256::digest(text.as_bytes()))
            }
            Algorithm::Sha1 => {
                use sha1::Digest;
                format!("{:x}", sha1::Sha1::digest(text.as_bytes()))
            }
        }
    }
}

/// The GraphQL specification's `onError` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum OnError {
    Propagate,
    Null,
    Abort,
}

/// A `customScalarTypes` value: the Swift type a scalar reads as, or the
/// host type by language.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(untagged)]
pub enum HostTypes {
    One(String),
    ByLanguage(BTreeMap<String, HostType>),
}

/// One language's entry of a mapped scalar: a type's name, as Swift's is,
/// or a type and the converter between it and the scalar's text, as
/// Kotlin's is.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(untagged)]
pub enum HostType {
    Named(String),
    Converted(ConvertedType),
}

/// A host type the runtime cannot extend, and the `object` that converts it
/// from and to the scalar's text: Kotlin's `{"type":
/// "java.math.BigDecimal", "converter": "app.Decimals"}`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConvertedType {
    #[serde(rename = "type")]
    pub type_name: String,
    pub converter: String,
}

impl HostTypes {
    /// The Swift type: the string, or the `swift` entry when it names one.
    pub fn swift(&self) -> Option<&str> {
        match self {
            HostTypes::One(swift_type) => Some(swift_type),
            HostTypes::ByLanguage(types) => match types.get("swift")? {
                HostType::Named(swift_type) => Some(swift_type),
                HostType::Converted(_) => None,
            },
        }
    }

    /// The `kotlin` entry, when it gives a type and its converter.
    pub fn kotlin(&self) -> Option<&ConvertedType> {
        match self {
            HostTypes::One(_) => None,
            HostTypes::ByLanguage(types) => match types.get("kotlin")? {
                HostType::Converted(converted) => Some(converted),
                HostType::Named(_) => None,
            },
        }
    }
}

/// The language a run generates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Language {
    #[default]
    Swift,
    Kotlin,
}

impl Language {
    /// The language as a message names it.
    pub fn name(self) -> &'static str {
        match self {
            Language::Swift => "Swift",
            Language::Kotlin => "Kotlin",
        }
    }
}

/// What the Kotlin target reads from `baton.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KotlinConfig {
    /// The package of the shared file and of the code generated from
    /// `.graphql` sources; a `.kt` host's code takes the host's own.
    #[serde(default)]
    pub package: Option<String>,
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
    /// What may not reach the image: types whose records are never written,
    /// and root fields whose cells, keys and operations are never written.
    /// Memory is unaffected; the next launch misses and fetches.
    #[serde(default)]
    pub transient: Transient,
    /// Relay's `persistConfig`: under it an artifact carries each operation's
    /// id, hashed from its text with the algorithm, and no text, and
    /// `generate` writes the file, Relay's map from id to text, for the
    /// registration step. Without it the text and no id.
    #[serde(rename = "persistConfig", default)]
    pub persist_config: Option<PersistConfig>,
    /// Relay's `customScalarTypes`: the host type a custom scalar reads as,
    /// by the scalar's name, e.g. `"Decimal": "Foundation.Decimal"` or
    /// `"Decimal": {"swift": "Foundation.Decimal", "kotlin": {"type":
    /// "java.math.BigDecimal", "converter": "app.Decimals"}}`. The store
    /// keeps the text; the accessor
    /// converts at the read, and says the conversion can fail. An unmapped
    /// custom scalar reads as `String`.
    #[serde(rename = "customScalarTypes", default)]
    pub custom_scalar_types: BTreeMap<String, HostTypes>,
    /// The `onError` request parameter every operation sends: `PROPAGATE`,
    /// `NULL` or `ABORT`. Under `NULL` a server nulls an errored field in
    /// place, so a field the schema types non-null is typed by its semantic
    /// nullability: non-null only where errors are handled.
    #[serde(rename = "onError", default)]
    pub on_error: Option<OnError>,
    /// What the Kotlin target reads: the package of the code it writes for
    /// no host file of its own.
    #[serde(default)]
    pub kotlin: Option<KotlinConfig>,
    /// The language the run generates, which the driver sets: a mapped
    /// scalar needs an entry for it.
    #[serde(skip)]
    pub language: Language,
    /// Where the configuration was read from, for its diagnostics.
    #[serde(skip)]
    pub path: PathBuf,
}

/// Why `baton.json` could not be loaded.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("batonc: cannot read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("batonc: {path}: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
            path: path.display().to_string(),
            source,
        })?;
        let mut config: Config =
            serde_json::from_str(&text).map_err(|source| ConfigError::Parse {
                path: path.display().to_string(),
                source,
            })?;
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

    /// The Swift type each mapped custom scalar reads as, by the scalar's
    /// name: what the Swift writer resolves a mapped scalar by. A mapping
    /// without one is refused when the configuration is checked.
    pub fn swift_types(&self) -> BTreeMap<String, String> {
        self.custom_scalar_types
            .iter()
            .filter_map(|(scalar, host_types)| {
                Some((scalar.clone(), host_types.swift()?.to_string()))
            })
            .collect()
    }

    /// The Kotlin type and converter of each mapped custom scalar, by the
    /// scalar's name.
    pub fn kotlin_types(&self) -> BTreeMap<String, ConvertedType> {
        self.custom_scalar_types
            .iter()
            .filter_map(|(scalar, host_types)| Some((scalar.clone(), host_types.kotlin()?.clone())))
            .collect()
    }

    /// The package `kotlin.package` names.
    pub fn kotlin_package(&self) -> Option<&str> {
        self.kotlin.as_ref()?.package.as_deref()
    }
}
