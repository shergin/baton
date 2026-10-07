//! Tests of `persistConfig`: without it an operation carries its text and no
//! id; under it the id, hashed from the printed text with the configured
//! algorithm, and no text; `generate` writes the map from id to text; the
//! schema's digest does not depend on it.

use super::*;

const MUTATION: &str =
    "mutation Rename($id: ID!) { addNote(characterId: $id, text: \"x\") { note { id } } }";

/// The plan of `texts` under the configuration `config`.
fn compiled(config: &str, texts: &[&str]) -> crate::pipeline::plan::Plan {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let documents: Vec<Document> = texts
        .iter()
        .enumerate()
        .map(|(index, text)| Document {
            index,
            ..document(text)
        })
        .collect();
    compile(&sdl, &path, &[], &documents, &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The Swift emitted for the one host file of `plan`.
fn emitted(plan: &crate::pipeline::plan::Plan) -> String {
    crate::emit::emit(plan)
        .expect("the plan emits")
        .files
        .into_values()
        .next()
        .expect("the host file has output")
}

fn md5(text: &str) -> String {
    format!("{:x}", md5::compute(text.as_bytes()))
}

fn sha256(text: &str) -> String {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(text.as_bytes()))
}

fn sha1(text: &str) -> String {
    use sha1::Digest;
    format!("{:x}", sha1::Sha1::digest(text.as_bytes()))
}

#[test]
fn without_persist_config_an_operation_carries_its_text_and_no_id() {
    let plan = compiled("{}", &[QUERY]);
    let operation = &plan.operations[0];
    assert_eq!(operation.id, None);
    let swift = emitted(&plan);
    assert!(
        swift.contains(&format!(
            "public static let document: Baton.Document = .text(#\"{}\"#)\n",
            operation.text
        )),
        "the text is one line in a one-line raw literal: {swift}"
    );
    assert!(!swift.contains(".id("), "{swift}");
    assert!(!swift.contains("persistedID"), "{swift}");
    let json = serde_json::to_value(operation).expect("the operation serializes");
    assert!(json.get("id").is_none(), "{json}");
    assert!(json.get("text").is_some(), "{json}");
}

#[test]
fn under_persist_config_an_operation_carries_the_hash_of_its_text_and_no_text() {
    for (algorithm, hash) in [
        ("MD5", md5 as fn(&str) -> String),
        ("SHA256", sha256),
        ("SHA1", sha1),
    ] {
        let config = format!(
            r#"{{"persistConfig": {{"file": "persisted.json", "algorithm": "{algorithm}"}}}}"#
        );
        let plan = compiled(&config, &[QUERY]);
        let operation = &plan.operations[0];
        let id = hash(&operation.text);
        assert_eq!(operation.id.as_deref(), Some(id.as_str()), "{algorithm}");
        let swift = emitted(&plan);
        assert!(
            swift.contains(&format!(
                "public static let document: Baton.Document = .id(\"{id}\")"
            )),
            "{algorithm}: {swift}"
        );
        assert!(!swift.contains(".text("), "{algorithm}: {swift}");
        assert!(
            !swift.contains("character(id: \"1\")"),
            "{algorithm}: the binary holds no text: {swift}"
        );
        let json = serde_json::to_value(operation).expect("the operation serializes");
        assert_eq!(json.get("id").and_then(|id| id.as_str()), Some(id.as_str()));
    }
}

#[test]
fn the_persisted_id_is_the_hash_of_the_compact_text() {
    let plan = compiled(
        r#"{"persistConfig": {"file": "persisted.json"}}"#,
        &[MUTATION],
    );
    let operation = &plan.operations[0];
    assert_eq!(
        operation.text,
        "mutation Rename($id:ID!){addNote(characterId:$id,text:\"x\"){note{id}}}"
    );
    assert_eq!(
        operation.id.as_deref(),
        Some(md5(&operation.text).as_str()),
        "the id hashes exactly the text the server would otherwise receive"
    );
}

#[test]
fn each_algorithm_is_the_digest_it_names() {
    use crate::config::Algorithm;
    assert_eq!(Algorithm::Md5.id("abc"), "900150983cd24fb0d6963f7d28e17f72");
    assert_eq!(
        Algorithm::Sha256.id("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        Algorithm::Sha1.id("abc"),
        "a9993e364706816aba3e25717850c26c9cd0d89d"
    );
}

#[test]
fn the_algorithm_defaults_to_md5() {
    let config: Config = serde_json::from_str(r#"{"persistConfig": {"file": "persisted.json"}}"#)
        .expect("the configuration parses");
    let persist = config.persist_config.expect("the block is read");
    assert_eq!(persist.algorithm, crate::config::Algorithm::Md5);
    let plan = compiled(r#"{"persistConfig": {"file": "persisted.json"}}"#, &[QUERY]);
    let operation = &plan.operations[0];
    assert_eq!(operation.id, Some(md5(&operation.text)));
}

#[test]
fn an_unknown_algorithm_or_key_is_refused_where_the_configuration_parses() {
    for config in [
        r#"{"persistConfig": {"file": "persisted.json", "algorithm": "SHA512"}}"#,
        r#"{"persistConfig": {"file": "persisted.json", "url": "https://example.com"}}"#,
        r#"{"persistConfig": {}}"#,
    ] {
        assert!(serde_json::from_str::<Config>(config).is_err(), "{config}");
    }
}

#[test]
fn the_schema_digest_does_not_depend_on_persist_config() {
    let plain = compiled("{}", &[QUERY]).schema_digest;
    for algorithm in ["MD5", "SHA256", "SHA1"] {
        let config = format!(
            r#"{{"persistConfig": {{"file": "persisted.json", "algorithm": "{algorithm}"}}}}"#
        );
        assert_eq!(
            compiled(&config, &[QUERY]).schema_digest,
            plain,
            "{algorithm}"
        );
    }
}

/// A directory of its own under the system's temporary directory, removed
/// when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let path =
            std::env::temp_dir().join(format!("batonc-persist-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("the scratch directory is created");
        Scratch(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Writes a configuration, the test schema's path and two operations into
/// `scratch`, returning the configuration's and the document's paths.
fn sources(scratch: &Scratch, persist: &str) -> (PathBuf, PathBuf) {
    let (_, schema_path) = schema();
    let config = scratch.0.join("baton.json");
    std::fs::write(
        &config,
        format!(
            r#"{{"schema": {}, "persistConfig": {persist}}}"#,
            serde_json::to_string(&schema_path).expect("the path serializes")
        ),
    )
    .expect("the configuration is written");
    let document = scratch.0.join("Probe.graphql");
    std::fs::write(&document, format!("{QUERY}\n\n{MUTATION}\n")).expect("the document is written");
    (config, document)
}

/// The persisted file's entries, in the file's order.
fn entries(path: &Path) -> Vec<(String, String)> {
    let text = std::fs::read_to_string(path).expect("the persisted file is written");
    assert!(text.ends_with("}\n"), "{text}");
    let map: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&text).expect("the persisted file is a JSON object");
    let keys: Vec<&str> = text
        .lines()
        .filter_map(|line| line.trim_start().strip_prefix('"'))
        .filter_map(|line| line.split('"').next())
        .collect();
    assert_eq!(keys.len(), map.len(), "one line per id: {text}");
    keys.iter()
        .map(|key| {
            (
                key.to_string(),
                map[*key].as_str().expect("a text").to_string(),
            )
        })
        .collect()
}

#[test]
fn generate_writes_the_ids_in_order_each_to_its_text_into_the_output_directory() {
    let scratch = Scratch::new("out");
    let (config, document) = sources(
        &scratch,
        r#"{"file": "nested/persisted.json", "algorithm": "SHA256"}"#,
    );
    let out = scratch.0.join("out");
    crate::generate(&[
        "--config".to_string(),
        config.display().to_string(),
        "--out".to_string(),
        out.display().to_string(),
        document.display().to_string(),
    ])
    .expect("generate succeeds");

    assert!(
        !scratch.0.join("nested/persisted.json").exists(),
        "under `--out` the source tree is left alone"
    );
    let entries = entries(&out.join("persisted.json"));
    assert_eq!(entries.len(), 2, "{entries:?}");
    let ids: Vec<&String> = entries.iter().map(|(id, _)| id).collect();
    let mut sorted = ids.clone();
    sorted.sort();
    assert_eq!(ids, sorted, "the ids are in order");
    for (id, text) in &entries {
        assert_eq!(*id, sha256(text));
    }
    let texts: Vec<&str> = entries.iter().map(|(_, text)| text.as_str()).collect();
    assert!(
        texts.iter().any(|text| text.starts_with("query Probe")),
        "{texts:?}"
    );
    assert!(
        texts.iter().any(|text| text.starts_with("mutation Rename")),
        "{texts:?}"
    );

    let host = std::fs::read_dir(&out)
        .expect("the output directory is listed")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.extension()
                .is_some_and(|extension| extension == "swift")
                && !path.ends_with("Baton.baton.swift")
        })
        .expect("the host file's output is written");
    let generated = std::fs::read_to_string(host).expect("the host file's output is readable");
    for (id, _) in &entries {
        assert!(generated.contains(&format!(".id(\"{id}\")")), "{generated}");
    }
}

#[test]
fn generate_by_hand_writes_the_file_beside_the_configuration() {
    let scratch = Scratch::new("beside");
    let (config, document) = sources(&scratch, r#"{"file": "persisted.json"}"#);
    let shared = scratch.0.join("Shared.swift");
    let emitted = scratch.0.join("Probe.swift");
    crate::generate(&[
        "--config".to_string(),
        config.display().to_string(),
        "--shared".to_string(),
        shared.display().to_string(),
        "--emit".to_string(),
        format!("{}={}", document.display(), emitted.display()),
        document.display().to_string(),
    ])
    .expect("generate succeeds");
    let entries = entries(&scratch.0.join("persisted.json"));
    assert_eq!(entries.len(), 2, "{entries:?}");
    for (id, text) in &entries {
        assert_eq!(*id, md5(text));
    }
}
