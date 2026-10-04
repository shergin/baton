//! Golden tests for the Swift emitter. The documents of the Swift test target
//! go through the whole pipeline, as the build plugin runs it, and the
//! generated files are compared byte for byte with `goldens/`. Those documents
//! exist to exercise every directive the runtime's tests prove, so they cover
//! every shape the emitter writes, and a change to the emitter shows up here
//! as a diff to review.
//!
//! After an intended change, `BATON_BLESS=1 cargo test` rewrites the goldens.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::{diagnostics, documents, pipeline};

fn goldens() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/tests/goldens")
}

/// Compiles the Swift test target and returns the generated files by output
/// name, the shared file among them.
fn emit_swift_tests() -> BTreeMap<String, String> {
    let target = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("swift/Tests/BatonTests");
    let config_path = target.join("baton.json");
    let config = Config::load(&config_path).expect("the test target has a baton.json");
    let schema_path = config.schema_path(&config_path);
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let mut sources: Vec<PathBuf> = std::fs::read_dir(&target)
        .expect("the test target is readable")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "swift")
        })
        .collect();
    sources.sort();

    let (documents, errors) = documents::collect(&sources);
    assert!(errors.is_empty(), "{errors:?}");
    let compiled = pipeline::compile(&schema, &schema_path.to_string_lossy(), &documents, &config)
        .unwrap_or_else(|errors| {
            let rendered: Vec<String> = errors
                .iter()
                .map(|error| diagnostics::render(error, &documents).to_string())
                .collect();
            panic!(
                "the test documents do not compile:\n{}",
                rendered.join("\n")
            )
        });

    let output = emit(&compiled.plan).unwrap_or_else(|duplicates| {
        let messages: Vec<String> = duplicates.iter().map(ToString::to_string).collect();
        panic!(
            "the test documents emit names twice:\n{}",
            messages.join("\n")
        )
    });
    let mut files: BTreeMap<String, String> = output
        .files
        .into_iter()
        .map(|(source, text)| {
            let stem = Path::new(&source)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .expect("a source file has a name");
            (format!("{stem}.baton.swift"), text)
        })
        .collect();
    files.insert("Baton.baton.swift".to_string(), output.shared);
    files
}

/// The names of the goldens on disk.
fn golden_names(directory: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    names.sort();
    names
}

/// Where two texts part: the line number and both versions of the line.
fn first_difference(golden: &str, emitted: &str) -> String {
    let mut golden_lines = golden.lines();
    let mut emitted_lines = emitted.lines();
    let mut line = 1;
    loop {
        match (golden_lines.next(), emitted_lines.next()) {
            (Some(left), Some(right)) if left == right => line += 1,
            (left, right) => {
                return format!(
                    "line {line}\n  golden:  {}\n  emitted: {}",
                    left.unwrap_or("<end of file>"),
                    right.unwrap_or("<end of file>")
                );
            }
        }
    }
}

/// Replaces the goldens with what the emitter writes now.
fn bless(directory: &Path, emitted: &BTreeMap<String, String>) {
    std::fs::create_dir_all(directory).expect("the goldens directory can be created");
    for name in golden_names(directory) {
        if !emitted.contains_key(&name) {
            std::fs::remove_file(directory.join(&name)).expect("a stale golden can be removed");
        }
    }
    for (name, text) in emitted {
        std::fs::write(directory.join(name), text).expect("a golden can be written");
    }
}

#[test]
fn the_swift_emitter_reproduces_its_goldens_byte_for_byte() {
    let emitted = emit_swift_tests();
    let directory = goldens();
    if std::env::var_os("BATON_BLESS").is_some() {
        bless(&directory, &emitted);
        return;
    }

    let mut problems: Vec<String> = Vec::new();
    for (name, text) in &emitted {
        match std::fs::read_to_string(directory.join(name)) {
            Ok(golden) if &golden == text => {}
            Ok(golden) => problems.push(format!(
                "{name} differs from its golden at {}",
                first_difference(&golden, text)
            )),
            Err(_) => problems.push(format!("{name} has no golden")),
        }
    }
    for name in golden_names(&directory) {
        if !emitted.contains_key(&name) {
            problems.push(format!("{name} is a golden nothing emits any more"));
        }
    }
    assert!(
        problems.is_empty(),
        "{}\nIf the change is intended, run `BATON_BLESS=1 cargo test` in compiler/ and review the diff.",
        problems.join("\n")
    );
}

#[test]
fn compiling_the_same_sources_twice_emits_the_same_bytes() {
    assert!(
        emit_swift_tests() == emit_swift_tests(),
        "two compilations of the same sources emitted different bytes"
    );
}
