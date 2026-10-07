//! The authors' documents under `spec/sources/`: the texts of the Swift test
//! target's markers, one `.graphql` file each, so that a second runtime's
//! harness compiles its lenses from the specification alone. The files are
//! checked against the markers byte for byte, and compiled with
//! `spec/tests/baton.json` they must plan what the Swift host files plan
//! with the test target's `baton.json`.
//!
//! After an intended change to the markers, `BATON_BLESS=1 cargo test`
//! rewrites the directory.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::{compile_swift_tests, first_difference, repository, schema_extensions};
use crate::config::Config;
use crate::pipeline::Plan;
use crate::{diagnostics, documents, pipeline};

/// The directory of the authors' documents.
fn sources() -> PathBuf {
    repository().join("spec/sources")
}

/// The Swift host files of the test target, sorted.
fn swift_host_files() -> Vec<PathBuf> {
    let target = repository().join("swift/Tests/BatonTests");
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&target)
        .expect("the test target is readable")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "swift")
        })
        .collect();
    paths.sort();
    paths
}

/// The `.graphql` files of `directory`, sorted.
fn graphql_files(directory: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "graphql")
        })
        .collect();
    paths.sort();
    paths
}

/// A marker's verbatim text in the form Swift's multi-line literal yields:
/// the indentation every non-blank line shares removed, a blank line
/// emptied, no blank line at either end, and one newline after the last.
fn authored(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let indentation = lines
        .iter()
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.len() - line.trim_start_matches([' ', '\t']).len())
        .min()
        .unwrap_or(0);
    let dedented: Vec<&str> = lines
        .iter()
        .map(|line| {
            if line.trim().is_empty() {
                ""
            } else {
                &line[indentation..]
            }
        })
        .collect();
    let first = dedented.iter().position(|line| !line.is_empty());
    let last = dedented.iter().rposition(|line| !line.is_empty());
    let (Some(first), Some(last)) = (first, last) else {
        return String::new();
    };
    format!("{}\n", dedented[first..=last].join("\n"))
}

/// The name of the first definition, an operation or a fragment, in a
/// document's text, comments skipped.
fn first_definition_name(text: &str) -> Option<String> {
    let mut words = text
        .lines()
        .map(|line| line.split('#').next().unwrap_or(""))
        .flat_map(|line| {
            line.split(|character: char| !(character.is_alphanumeric() || character == '_'))
        })
        .filter(|word| !word.is_empty());
    while let Some(word) = words.next() {
        if matches!(word, "query" | "mutation" | "subscription" | "fragment") {
            return words.next().map(str::to_string);
        }
    }
    None
}

/// Every marker's text of the Swift host files in its authored form, by the
/// file name it is written under.
fn marker_sources() -> BTreeMap<String, String> {
    let (documents, errors) = documents::collect(&swift_host_files());
    assert!(errors.is_empty(), "{errors:?}");
    let root = repository();
    let mut written: BTreeMap<String, (String, String)> = BTreeMap::new();
    for document in &documents {
        let host = document
            .path
            .strip_prefix(&root)
            .unwrap_or(&document.path)
            .to_string_lossy()
            .into_owned();
        let name = first_definition_name(&document.text).unwrap_or_else(|| {
            panic!(
                "document {} of {host} has no named operation or fragment",
                document.index
            )
        });
        let file = format!("{name}.graphql");
        if let Some((other, _)) = written.get(&file) {
            panic!("{file} would be written from both {other} and {host}");
        }
        written.insert(file, (host, authored(&document.text)));
    }
    written
        .into_iter()
        .map(|(file, (_, text))| (file, text))
        .collect()
}

#[test]
fn the_spec_sources_are_the_markers_texts() {
    let directory = sources();
    let expected = marker_sources();
    let on_disk: Vec<String> = graphql_files(&directory)
        .iter()
        .filter_map(|path| path.file_name()?.to_str().map(str::to_string))
        .collect();

    if std::env::var_os("BATON_BLESS").is_some() {
        std::fs::create_dir_all(&directory).expect("the sources directory can be created");
        for name in &on_disk {
            if !expected.contains_key(name) {
                std::fs::remove_file(directory.join(name)).expect("a stale source can be removed");
            }
        }
        for (name, text) in &expected {
            std::fs::write(directory.join(name), text).expect("a source can be written");
        }
        return;
    }

    let mut problems: Vec<String> = Vec::new();
    for (name, text) in &expected {
        match std::fs::read_to_string(directory.join(name)) {
            Ok(written) if &written == text => {}
            Ok(written) => problems.push(format!(
                "spec/sources/{name} differs from its marker at {}",
                first_difference(&written, text)
            )),
            Err(_) => problems.push(format!("spec/sources/{name} is missing")),
        }
    }
    for name in &on_disk {
        if !expected.contains_key(name) {
            problems.push(format!("spec/sources/{name} is a text no marker yields"));
        }
    }
    assert!(
        problems.is_empty(),
        "{}\nIf the markers changed, run `BATON_BLESS=1 cargo test` in compiler/ and review the diff.",
        problems.join("\n")
    );
}

/// The plan of the authors' documents under `spec/sources/`, compiled with
/// the specification's own configuration.
fn compile_spec_sources() -> Plan {
    let config_path = repository().join("spec/tests/baton.json");
    let config = Config::load(&config_path).expect("the specification has a baton.json");
    let schema_path = config.schema_path(&config_path);
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let (documents, errors) = documents::collect(&graphql_files(&sources()));
    assert!(errors.is_empty(), "{errors:?}");
    let extensions = schema_extensions(&config, &config_path);
    pipeline::compile(
        &schema,
        &schema_path.to_string_lossy(),
        &extensions,
        &documents,
        &config,
    )
    .unwrap_or_else(|errors| {
        let rendered: Vec<String> = errors
            .iter()
            .map(|error| diagnostics::render(error, &documents).to_string())
            .collect();
        panic!(
            "the specification's sources do not compile:\n{}",
            rendered.join("\n")
        )
    })
    .plan
}

/// A plan as the plan goldens serialize it, without where each definition
/// was written: the file and the document's index differ between a host
/// file and a `.graphql` file, and the definitions are sorted by name.
fn placeless(mut plan: Plan) -> String {
    for fragment in &mut plan.fragments {
        fragment.source.clear();
        fragment.document = 0;
    }
    for operation in &mut plan.operations {
        operation.source.clear();
        operation.document = 0;
    }
    plan.fragments
        .sort_by(|left, right| left.name.cmp(&right.name));
    plan.operations
        .sort_by(|left, right| left.name.cmp(&right.name));
    let json = serde_json::to_string_pretty(&plan).expect("a plan serializes");
    format!("{json}\n")
}

#[test]
fn the_spec_sources_compile_to_the_plans_the_swift_tests_run_against() {
    let swift = placeless(compile_swift_tests());
    let spec = placeless(compile_spec_sources());
    assert!(
        swift == spec,
        "the specification's sources plan differently from the Swift host files at {}",
        first_difference(&swift, &spec)
    );
}
