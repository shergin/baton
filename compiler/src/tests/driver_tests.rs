//! Tests of the driver: `--check` read as a flag by the commands that take
//! it, and `check_outputs` comparing what `generate` would write with the
//! files on disk.

use super::*;

fn arguments(texts: &[&str]) -> Vec<String> {
    texts.iter().map(|text| text.to_string()).collect()
}

#[test]
fn check_is_a_flag_that_takes_no_value() {
    let options = parse_options(
        "generate",
        &arguments(&["--check", "Screen.swift", "--out", "out"]),
        &["out", "check"],
    )
    .unwrap_or_else(|error| panic!("{error}"));
    assert!(options.flags.contains("check"));
    assert_eq!(options.paths, [PathBuf::from("Screen.swift")]);
    assert_eq!(options.values.get("out").map(String::as_str), Some("out"));
    assert!(!options.values.contains_key("check"));
}

#[test]
fn check_as_the_last_argument_needs_no_value() {
    let options = parse_options("generate", &arguments(&["--check"]), &["check"])
        .unwrap_or_else(|error| panic!("{error}"));
    assert!(options.flags.contains("check"));
    assert!(options.paths.is_empty());
}

#[test]
fn check_is_refused_by_a_command_that_does_not_take_it() {
    let refused = parse_options(
        "validate",
        &arguments(&["--check", "Screen.swift"]),
        &["schema", "config"],
    );
    let Err(DriverError::Usage(message)) = refused else {
        panic!("`--check` is refused as a usage error");
    };
    assert_eq!(
        message,
        "`--check` is not an option of `validate`, which takes `--schema`, `--config`"
    );
}

/// A directory under the system's temporary one, empty for one test and
/// removed after it.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let path =
            std::env::temp_dir().join(format!("batonc-driver-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("the scratch directory is created");
        Scratch(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The outputs `generate` would write into `out`, written to disk.
fn fresh(out: &Scratch) -> Vec<(PathBuf, String)> {
    let planned = vec![
        (out.join("Screen.baton.swift"), "// Screen\n".to_string()),
        (out.join("Baton.baton.swift"), "// Shared\n".to_string()),
    ];
    for (path, text) in &planned {
        std::fs::write(path, text).expect("the output is written");
    }
    planned
}

fn stale_count(result: Result<(), DriverError>) -> usize {
    match result {
        Ok(()) => 0,
        Err(DriverError::Stale(count)) => count,
        Err(other) => panic!("`check_outputs` fails only as stale: {other}"),
    }
}

#[test]
fn fresh_outputs_pass_the_check() {
    let out = Scratch::new("fresh");
    let planned = fresh(&out);
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 0);
}

#[test]
fn an_edited_output_is_stale() {
    let out = Scratch::new("edited");
    let planned = fresh(&out);
    std::fs::write(out.join("Screen.baton.swift"), "// Screen, edited\n")
        .expect("the output is edited");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 1);
    assert_eq!(
        std::fs::read_to_string(out.join("Screen.baton.swift")).ok(),
        Some("// Screen, edited\n".to_string()),
        "the check writes nothing"
    );
}

#[test]
fn a_missing_output_is_stale() {
    let out = Scratch::new("missing");
    let planned = fresh(&out);
    std::fs::remove_file(out.join("Screen.baton.swift")).expect("the output is removed");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 1);
    assert!(
        !out.join("Screen.baton.swift").exists(),
        "the check writes nothing"
    );
}

#[test]
fn a_generated_file_nothing_writes_is_stale() {
    let out = Scratch::new("stray");
    let planned = fresh(&out);
    std::fs::write(out.join("Removed.baton.swift"), "// Removed\n").expect("the stray is written");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 1);
    assert!(
        out.join("Removed.baton.swift").exists(),
        "the check removes nothing"
    );
}

#[test]
fn a_file_of_another_extension_in_the_output_directory_is_ignored() {
    let out = Scratch::new("other");
    let planned = fresh(&out);
    std::fs::write(out.join("Notes.swift"), "// Notes\n").expect("the file is written");
    std::fs::write(out.join("Baton.report.json"), "{}\n").expect("the file is written");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 0);
}

#[test]
fn a_planned_output_outside_the_output_directory_is_compared_too() {
    let out = Scratch::new("inside");
    let elsewhere = Scratch::new("outside");
    let mut planned = fresh(&out);
    let report = elsewhere.join("Baton.report.json");
    planned.push((report.clone(), "{}\n".to_string()));
    std::fs::write(&report, "{}\n").expect("the report is written");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 0);
    std::fs::write(&report, "{ \"edited\": true }\n").expect("the report is edited");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 1);
    std::fs::remove_file(&report).expect("the report is removed");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 1);
}

#[test]
fn every_difference_is_counted() {
    let out = Scratch::new("every");
    let planned = fresh(&out);
    std::fs::write(out.join("Screen.baton.swift"), "// edited\n").expect("the output is edited");
    std::fs::remove_file(out.join("Baton.baton.swift")).expect("the output is removed");
    std::fs::write(out.join("Removed.baton.swift"), "// Removed\n").expect("the stray is written");
    assert_eq!(stale_count(check_outputs(&planned, Some(&out.0))), 3);
}
