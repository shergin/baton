//! A base: a target whose report another target's compilation reads, so
//! that the target spreads the base's fragments
//! (`docs/decisions/a-target-spreads-its-bases-fragments.md`). The word is
//! Relay's, whose project names a `base` project it may reference the
//! documents of.
//!
//! This file reads a base's file, the head and the fragments of a report,
//! and adds to a compilation's definitions the base fragments its documents
//! reach. A compilation pays for what it reaches and not for its closure: a
//! target at the top of an app has every fragment of the app among its
//! bases and spreads a handful.

use std::collections::{BTreeMap, BTreeSet};

use common::{Diagnostic, Location, SourceLocationKey, Span};
use graphql_syntax::{ExecutableDefinition, Selection};
use intern::Lookup;

use crate::config::Language;

/// The format of a report's head and fragments, what a dependent target
/// reads. A report of another format is refused: the two targets were
/// compiled by two compilers.
pub const FORMAT: u32 = 1;

/// A base as its file states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Base {
    /// The file it was read from, which a diagnostic names it by.
    pub path: String,
    pub schema_digest: String,
    /// Where the target's generated code is declared: the Swift module it
    /// is compiled in, or the Kotlin package of its shared file, none being
    /// the default package.
    pub module: Option<String>,
    pub fragments: Vec<BaseFragment>,
}

/// A fragment a base declares.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BaseFragment {
    pub name: String,
    /// The file that declares it, relative to where the base was compiled.
    pub source: String,
    /// The definition as its author wrote it.
    pub text: String,
    /// The Kotlin package its lens is declared in; none is the default one.
    pub package: Option<String>,
}

/// Why a base's file could not be read as one.
#[derive(Debug, thiserror::Error)]
pub enum BaseError {
    #[error("{path}:1:1: error: the base is not a report `batonc generate` wrote: {source}")]
    Json {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error(
        "{path}:1:1: error: the base's report is of format {found}, and this `batonc` reads format {FORMAT}: generate the base with the `batonc` that compiles this target"
    )]
    Format { path: String, found: String },
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    format: Option<u32>,
    schema_digest: String,
    module: Option<String>,
    #[serde(default)]
    fragments: Vec<FileFragment>,
}

#[derive(serde::Deserialize)]
struct FileFragment {
    name: String,
    source: String,
    text: String,
    package: Option<String>,
}

impl Base {
    /// Reads a base from the text of its file: a report, or a report's
    /// head and fragments alone. What else a report holds is not read.
    pub fn parse(path: &str, text: &str) -> Result<Base, BaseError> {
        let file: File = serde_json::from_str(text).map_err(|source| BaseError::Json {
            path: path.to_string(),
            source,
        })?;
        if file.format != Some(FORMAT) {
            return Err(BaseError::Format {
                path: path.to_string(),
                found: file
                    .format
                    .map_or_else(|| "none".to_string(), |format| format.to_string()),
            });
        }
        Ok(Base {
            path: path.to_string(),
            schema_digest: file.schema_digest,
            module: file.module,
            fragments: file
                .fragments
                .into_iter()
                .map(|fragment| BaseFragment {
                    name: fragment.name,
                    source: fragment.source,
                    text: fragment.text,
                    package: fragment.package,
                })
                .collect(),
        })
    }

    fn location(&self) -> Location {
        Location::new(SourceLocationKey::standalone(&self.path), Span::new(0, 0))
    }
}

/// A base fragment a compilation includes: where its lens is declared, as
/// the language of the run names the place, and the file that declares it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Included {
    /// The Swift module or the Kotlin package of the lens; none is Kotlin's
    /// default package.
    pub module: Option<String>,
    pub source: String,
}

/// Adds to `definitions` every base fragment they reach, directly or
/// through another base fragment, and returns those by name. Checked on
/// the way: each base was compiled against the schema of `digest`, a
/// fragment's name is unique among the target and its bases, a base
/// fragment spreads only what the target or a base declares, a base a
/// Swift target reaches names its module, and under Kotlin no two of the
/// target and its bases declare their shared file in one package, `package`
/// being the target's.
pub fn include(
    bases: &[Base],
    digest: &str,
    language: Language,
    package: Option<&str>,
    configuration: Location,
    definitions: &mut Vec<ExecutableDefinition>,
) -> Result<BTreeMap<String, Included>, Vec<Diagnostic>> {
    let mut included = BTreeMap::new();
    if bases.is_empty() {
        return Ok(included);
    }
    let mut errors = Vec::new();
    for base in bases {
        if base.schema_digest != digest {
            errors.push(Diagnostic::error(
                format!(
                    "the base `{}` was compiled against another schema, `identity` or `transient`: its digest is `{}` and this target's is `{digest}`, and one store cannot read a record both ways",
                    base.path, base.schema_digest
                ),
                configuration,
            ));
        }
    }
    if language == Language::Kotlin {
        errors.extend(shared_package_clashes(bases, package, configuration));
    }
    let mut declared: BTreeMap<&str, (&Base, &BaseFragment)> = BTreeMap::new();
    for base in bases {
        for fragment in &base.fragments {
            let Some((first, first_fragment)) = declared.get(fragment.name.as_str()) else {
                declared.insert(&fragment.name, (base, fragment));
                continue;
            };
            errors.push(Diagnostic::error(
                format!(
                    "two bases declare the fragment `{}`: `{}`, in `{}`, and `{}`, in `{}`; a fragment's name is unique among a target and its bases",
                    fragment.name, first.path, first_fragment.source, base.path, fragment.source
                ),
                base.location(),
            ));
        }
    }
    let mut own: BTreeMap<String, Location> = BTreeMap::new();
    // What is still to be looked up: a fragment's name, and the base
    // fragment that spreads it, when one does.
    let mut pending: Vec<(String, Option<(&Base, &BaseFragment)>)> = Vec::new();
    for definition in definitions.iter() {
        let selections = match definition {
            ExecutableDefinition::Fragment(fragment) => {
                own.insert(
                    fragment.name.value.lookup().to_string(),
                    Location::new(fragment.location.source_location(), fragment.name.span),
                );
                &fragment.selections.items
            }
            ExecutableDefinition::Operation(operation) => &operation.selections.items,
        };
        let mut names = Vec::new();
        spreads(selections, &mut names);
        pending.extend(names.into_iter().map(|name| (name, None)));
    }
    for (name, location) in &own {
        if let Some((base, fragment)) = declared.get(name.as_str()) {
            errors.push(Diagnostic::error(
                format!(
                    "the base `{}` declares a fragment `{name}` too, in `{}`: a fragment's name is unique among a target and its bases, so rename this one",
                    base.path, fragment.source
                ),
                *location,
            ));
        }
    }
    if !errors.is_empty() {
        return Err(errors);
    }
    // The bases told once that they name no module.
    let mut unnamed: BTreeSet<&str> = BTreeSet::new();
    while let Some((name, spreading)) = pending.pop() {
        if own.contains_key(&name) || included.contains_key(&name) {
            continue;
        }
        let Some((base, fragment)) = declared.get(name.as_str()).copied() else {
            // A spread of the target's own documents is Relay's to report,
            // at the spread. A base's is told here, where the base is named.
            if let Some((base, fragment)) = spreading {
                errors.push(Diagnostic::error(
                    format!(
                        "the fragment `{}` of the base `{}` spreads `{name}`, which no base given declares: pass the base of the target that declares it",
                        fragment.name, base.path
                    ),
                    base.location(),
                ));
            }
            continue;
        };
        let module = match language {
            Language::Swift => {
                if base.module.is_none() && unnamed.insert(base.path.as_str()) {
                    errors.push(Diagnostic::error(
                        format!(
                            "the base `{}` names no module, and `{name}` is read through the lens its module declares: pass `--module` to the `generate` that writes it",
                            base.path
                        ),
                        base.location(),
                    ));
                }
                base.module.clone()
            }
            Language::Kotlin => fragment.package.clone(),
        };
        let key = SourceLocationKey::standalone(&base.path);
        match graphql_syntax::parse_executable(&fragment.text, key) {
            Ok(parsed) => {
                for definition in parsed.definitions {
                    let ExecutableDefinition::Fragment(parsed_fragment) = &definition else {
                        continue;
                    };
                    let mut names = Vec::new();
                    spreads(&parsed_fragment.selections.items, &mut names);
                    pending.extend(
                        names
                            .into_iter()
                            .map(|spread| (spread, Some((base, fragment)))),
                    );
                    definitions.push(definition);
                }
            }
            Err(parse_errors) => errors.extend(parse_errors),
        }
        included.insert(
            name,
            Included {
                module,
                source: fragment.source.clone(),
            },
        );
    }
    if errors.is_empty() {
        Ok(included)
    } else {
        Err(errors)
    }
}

/// Under Kotlin, the targets among this one and its bases that declare
/// their shared file in one package. The shared file's objects are public
/// and named alike in every target, `Slots` among them, so two targets of
/// one package declare one class twice: the app loads one of the two, and
/// the other target's code fails when it first reads a slot only its own
/// declares.
fn shared_package_clashes(
    bases: &[Base],
    package: Option<&str>,
    configuration: Location,
) -> Vec<Diagnostic> {
    let spelled = |package: Option<&str>| match package {
        Some(package) => format!("the Kotlin package `{package}`"),
        None => "Kotlin's default package".to_string(),
    };
    let mut errors = Vec::new();
    let mut declaring: BTreeMap<Option<&str>, &Base> = BTreeMap::new();
    for base in bases {
        let base_package = base.module.as_deref();
        if base_package == package {
            errors.push(Diagnostic::error(
                format!(
                    "the base `{}` declares its shared file in {}, and so does this target: an app cannot hold both, so name another `kotlin.package` for one of them",
                    base.path,
                    spelled(package)
                ),
                configuration,
            ));
            continue;
        }
        if let Some(first) = declaring.get(&base_package) {
            errors.push(Diagnostic::error(
                format!(
                    "the bases `{}` and `{}` both declare their shared file in {}: an app cannot hold both, so name another `kotlin.package` for one of them",
                    first.path,
                    base.path,
                    spelled(base_package)
                ),
                base.location(),
            ));
            continue;
        }
        declaring.insert(base_package, base);
    }
    errors
}

/// The names of the fragments `selections` spread, at any depth.
fn spreads(selections: &[Selection], into: &mut Vec<String>) {
    for selection in selections {
        match selection {
            Selection::FragmentSpread(spread) => into.push(spread.name.value.lookup().to_string()),
            Selection::InlineFragment(inline) => spreads(&inline.selections.items, into),
            Selection::LinkedField(field) => spreads(&field.selections.items, into),
            Selection::ScalarField(_) => {}
        }
    }
}

#[cfg(test)]
#[path = "tests/base_tests.rs"]
mod tests;
