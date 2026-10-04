//! Golden tests for the Swift emitter and the plan. The documents of the
//! Swift test target go through the whole pipeline, as the build plugin runs
//! it, and the generated files are compared byte for byte with `goldens/`,
//! and the plan `batonc plan` prints for each file's documents with
//! `plans/`, beside them and out of the Swift target that compiles the
//! goldens. Those
//! documents exist to exercise every directive the runtime's tests prove, so
//! they cover every shape the lowering and the emitter write, and a change to
//! either shows up here as a diff to review.
//!
//! After an intended change, `BATON_BLESS=1 cargo test` rewrites the goldens.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::{diagnostics, documents, pipeline};

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .to_path_buf()
}

/// The Swift goldens, which a Swift test target compiles.
fn goldens() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/tests/goldens")
}

/// The plan goldens.
fn plans() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/tests/plans")
}

/// The plan of the Swift test target, its sources named from the
/// repository's root as `batonc plan` run there names them.
fn compile_swift_tests() -> Plan {
    let target = repository().join("swift/Tests/BatonTests");
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
    let mut plan = compiled.plan;
    let root = repository();
    let relative = |source: &mut String| {
        if let Ok(path) = Path::new(source.as_str()).strip_prefix(&root) {
            *source = path.to_string_lossy().into_owned();
        }
    };
    for fragment in &mut plan.fragments {
        relative(&mut fragment.source);
    }
    for operation in &mut plan.operations {
        relative(&mut operation.source);
    }
    plan
}

/// The output name for `source` with `extension` after its stem.
fn golden_name(source: &str, extension: &str) -> String {
    let stem = Path::new(source)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .expect("a source file has a name");
    format!("{stem}{extension}")
}

/// Compiles the Swift test target and returns the generated files by output
/// name, the shared file among them.
fn emit_swift_tests() -> BTreeMap<String, String> {
    let plan = compile_swift_tests();
    let output = emit(&plan).unwrap_or_else(|duplicates| {
        let messages: Vec<String> = duplicates.iter().map(ToString::to_string).collect();
        panic!(
            "the test documents emit names twice:\n{}",
            messages.join("\n")
        )
    });
    let mut files: BTreeMap<String, String> = output
        .files
        .into_iter()
        .map(|(source, text)| (golden_name(&source, ".baton.swift"), text))
        .collect();
    files.insert("Baton.baton.swift".to_string(), output.shared);
    files
}

/// The plan of the Swift test target as `batonc plan` prints it, one file's
/// documents to a golden.
fn plan_swift_tests() -> BTreeMap<String, String> {
    let plan = compile_swift_tests();
    let mut by_source: BTreeMap<String, Plan> = BTreeMap::new();
    for fragment in &plan.fragments {
        by_source
            .entry(golden_name(&fragment.source, ".plan.json"))
            .or_insert_with(|| Plan {
                root_names: plan.root_names.clone(),
                ..Plan::default()
            })
            .fragments
            .push(fragment.clone());
    }
    for operation in &plan.operations {
        by_source
            .entry(golden_name(&operation.source, ".plan.json"))
            .or_insert_with(|| Plan {
                root_names: plan.root_names.clone(),
                ..Plan::default()
            })
            .operations
            .push(operation.clone());
    }
    by_source
        .into_iter()
        .map(|(name, plan)| {
            let json = serde_json::to_string_pretty(&plan).expect("a plan serializes");
            (name, format!("{json}\n"))
        })
        .collect()
}

/// The names of the goldens on disk that end with `extension`.
fn golden_names(directory: &Path, extension: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| name.ends_with(extension))
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

/// Compares the goldens in `directory` that end with `extension` with what
/// is written now, or under `BATON_BLESS` replaces them.
fn check_goldens(directory: PathBuf, emitted: &BTreeMap<String, String>, extension: &str) {
    if std::env::var_os("BATON_BLESS").is_some() {
        std::fs::create_dir_all(&directory).expect("the goldens directory can be created");
        for name in golden_names(&directory, extension) {
            if !emitted.contains_key(&name) {
                std::fs::remove_file(directory.join(&name)).expect("a stale golden can be removed");
            }
        }
        for (name, text) in emitted {
            std::fs::write(directory.join(name), text).expect("a golden can be written");
        }
        return;
    }

    let mut problems: Vec<String> = Vec::new();
    for (name, text) in emitted {
        match std::fs::read_to_string(directory.join(name)) {
            Ok(golden) if &golden == text => {}
            Ok(golden) => problems.push(format!(
                "{name} differs from its golden at {}",
                first_difference(&golden, text)
            )),
            Err(_) => problems.push(format!("{name} has no golden")),
        }
    }
    for name in golden_names(&directory, extension) {
        if !emitted.contains_key(&name) {
            problems.push(format!("{name} is a golden nothing writes any more"));
        }
    }
    assert!(
        problems.is_empty(),
        "{}\nIf the change is intended, run `BATON_BLESS=1 cargo test` in compiler/ and review the diff.",
        problems.join("\n")
    );
}

#[test]
fn the_swift_emitter_reproduces_its_goldens_byte_for_byte() {
    check_goldens(goldens(), &emit_swift_tests(), ".baton.swift");
}

#[test]
fn the_plan_reproduces_its_goldens_byte_for_byte() {
    check_goldens(plans(), &plan_swift_tests(), ".plan.json");
}

#[test]
fn compiling_the_same_sources_twice_emits_the_same_bytes() {
    assert!(
        emit_swift_tests() == emit_swift_tests(),
        "two compilations of the same sources emitted different bytes"
    );
    assert!(
        plan_swift_tests() == plan_swift_tests(),
        "two compilations of the same sources planned different bytes"
    );
}
