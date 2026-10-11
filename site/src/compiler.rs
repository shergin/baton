//! Running `batonc` over a figure: the host files of one directory, the
//! generated code, the report with each lens, the operation texts and the
//! diagnostics. Every plate that shows what the compiler makes of a
//! document comes from here, at build time, never from a file typed by
//! hand.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The language a run writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Language {
    Swift,
    Kotlin,
}

impl Language {
    pub fn flag(self) -> &'static str {
        match self {
            Language::Swift => "swift",
            Language::Kotlin => "kotlin",
        }
    }

    /// The host extension.
    pub fn extension(self) -> &'static str {
        match self {
            Language::Swift => "swift",
            Language::Kotlin => "kt",
        }
    }

    /// The name the site shows, the UI framework's rather than the
    /// language's, since that is what a reader chooses by.
    pub fn label(self) -> &'static str {
        match self {
            Language::Swift => "SwiftUI",
            Language::Kotlin => "Compose",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Language::Swift => "swift",
            Language::Kotlin => "kotlin",
        }
    }
}

/// One source the compiler read or wrote.
#[derive(Debug, Clone)]
pub struct File {
    pub name: String,
    pub text: String,
}

/// The result of one run over one figure in one language.
#[derive(Debug, Clone)]
pub struct Compiled {
    pub language: Language,
    /// The host sources, in the order given.
    pub hosts: Vec<File>,
    /// The generated files, the shared file last; empty when a document has
    /// an error.
    pub outputs: Vec<File>,
    /// The report, when the run succeeded.
    pub report: Option<serde_json::Value>,
    /// The diagnostics, as the compiler printed them.
    pub diagnostics: String,
    /// Whether the run succeeded.
    pub ok: bool,
    /// Each operation's text as `print` prints it, by name.
    pub operations: BTreeMap<String, String>,
}

/// The compiler binary, found once.
pub struct Compiler {
    binary: PathBuf,
    work: PathBuf,
}

impl Compiler {
    /// Finds `batonc`: `BATON_COMPILER`, else the release build in the
    /// checkout, else the debug build.
    pub fn locate(root: &Path, work: &Path) -> Compiler {
        let candidates = [
            std::env::var_os("BATON_COMPILER").map(PathBuf::from),
            Some(root.join("compiler/target/release/batonc")),
            Some(root.join("compiler/target/debug/batonc")),
        ];
        let binary = candidates
            .into_iter()
            .flatten()
            .find(|path| path.is_file())
            .unwrap_or_else(|| {
                panic!(
                    "no batonc: build it with scripts/build-compiler.sh or name one in BATON_COMPILER"
                )
            });
        fs::create_dir_all(work).expect("work directory");
        Compiler {
            binary,
            work: work.to_path_buf(),
        }
    }

    /// The languages a figure directory has hosts for: Swift for `.swift`
    /// and for `.graphql` alone, Kotlin for `.kt`.
    pub fn languages(dir: &Path) -> Vec<Language> {
        let names = file_names(dir);
        let mut languages = Vec::new();
        if names.iter().any(|name| name.ends_with(".swift"))
            || names.iter().all(|name| !name.ends_with(".kt"))
        {
            languages.push(Language::Swift);
        }
        if names.iter().any(|name| name.ends_with(".kt")) {
            languages.push(Language::Kotlin);
        }
        languages
    }

    /// Compiles the hosts of `dir` in `language`: the host files of that
    /// language and every `.graphql` document beside them, against the
    /// directory's `baton.json`.
    pub fn compile(&self, name: &str, dir: &Path, language: Language) -> Compiled {
        let schemas = schema_files(dir);
        let hosts: Vec<String> = file_names(dir)
            .into_iter()
            .filter(|file| {
                file.ends_with(&format!(".{}", language.extension())) || file.ends_with(".graphql")
            })
            .filter(|file| !schemas.contains(file))
            .collect();
        self.compile_hosts(name, dir, &hosts, language)
    }

    /// Compiles the given hosts, paths relative to `dir`, in `language`.
    pub fn compile_hosts(
        &self,
        name: &str,
        dir: &Path,
        hosts: &[String],
        language: Language,
    ) -> Compiled {
        let out = self.work.join(name).join(language.flag());
        if out.exists() {
            fs::remove_dir_all(&out).expect("clear the figure's output");
        }
        fs::create_dir_all(&out).expect("the figure's output");
        let report_path = out.join("report.json");
        let mut command = Command::new(&self.binary);
        command
            .current_dir(dir)
            .arg("generate")
            .arg("--config")
            .arg("baton.json")
            .arg("--language")
            .arg(language.flag())
            .arg("--out")
            .arg(&out)
            .arg("--report")
            .arg(&report_path)
            .args(hosts);
        let result = command
            .output()
            .unwrap_or_else(|error| panic!("running {}: {error}", self.binary.display()));
        let diagnostics = String::from_utf8_lossy(&result.stderr).trim_end().to_string();
        let ok = result.status.success();
        let host_files = hosts
            .iter()
            .map(|host| File {
                name: host.clone(),
                text: read(&dir.join(host)),
            })
            .collect();
        let mut outputs = Vec::new();
        let report = if ok {
            let mut names: Vec<String> = file_names(&out)
                .into_iter()
                .filter(|file| file != "report.json")
                .collect();
            names.sort_by_key(|file| (file.starts_with("Baton.baton."), file.clone()));
            for file in names {
                outputs.push(File {
                    text: read(&out.join(&file)),
                    name: file,
                });
            }
            let parsed: serde_json::Value = serde_json::from_str(&read(&report_path))
                .unwrap_or_else(|error| panic!("{}: {error}", report_path.display()));
            Some(parsed)
        } else {
            None
        };
        let mut operations = BTreeMap::new();
        if let Some(report) = &report {
            for operation in report["operations"].as_array().into_iter().flatten() {
                let operation_name = operation["name"].as_str().unwrap_or_default();
                let printed = Command::new(&self.binary)
                    .current_dir(dir)
                    .arg("print")
                    .arg(operation_name)
                    .arg("--config")
                    .arg("baton.json")
                    .arg("--language")
                    .arg(language.flag())
                    .args(hosts)
                    .output()
                    .expect("print");
                operations.insert(
                    operation_name.to_string(),
                    String::from_utf8_lossy(&printed.stdout).trim_end().to_string(),
                );
            }
        }
        Compiled {
            language,
            hosts: host_files,
            outputs,
            report,
            diagnostics,
            ok,
            operations,
        }
    }
}

/// The files a configuration names as inputs, the schema and its
/// extensions, which are not hosts though they end in `.graphql`.
pub fn schema_files(dir: &Path) -> Vec<String> {
    let config = dir.join("baton.json");
    if !config.is_file() {
        return Vec::new();
    }
    let value: serde_json::Value = match serde_json::from_str(&read(&config)) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let mut names = Vec::new();
    if let Some(schema) = value["schema"].as_str() {
        names.push(schema.rsplit('/').next().unwrap_or(schema).to_string());
    }
    for extension in value["schemaExtensions"].as_array().into_iter().flatten() {
        if let Some(path) = extension.as_str() {
            names.push(path.rsplit('/').next().unwrap_or(path).to_string());
        }
    }
    names
}

/// The file names of a directory, sorted.
pub fn file_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap_or_else(|error| panic!("{}: {error}", dir.display()))
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_file())
        .map(|entry| entry.file_name().to_string_lossy().to_string())
        .collect();
    names.sort();
    names
}

pub fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| panic!("reading {}: {error}", path.display()))
}
