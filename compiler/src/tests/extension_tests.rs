//! Tests of client schema extensions: the plan marks each client field, the
//! text a server receives leaves them out, the digest folds the extensions
//! in, and an extension or an operation no server can serve is refused.

use super::*;

/// The extension the Swift test target reads.
fn extension() -> (String, String) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/extensions.graphql");
    (
        std::fs::read_to_string(&path).expect("the test extension is readable"),
        path.to_string_lossy().into_owned(),
    )
}

fn config() -> Config {
    Config {
        path: PathBuf::from("baton.json"),
        ..Config::default()
    }
}

/// The plan of `text` with the given extensions.
fn compiled(extensions: &[(String, String)], text: &str) -> crate::pipeline::plan::Plan {
    let (sdl, path) = schema();
    compile(&sdl, &path, extensions, &[document(text)], &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// Every field of the operation's normalization selection, by its response
/// path, with whether the plan marks it as the client's.
fn marks(plan: &crate::pipeline::plan::Plan) -> Vec<(String, bool)> {
    fn walk(selections: &[SelectionPlan], path: &str, out: &mut Vec<(String, bool)>) {
        for selection in selections {
            match selection {
                SelectionPlan::Scalar {
                    name,
                    alias,
                    client,
                    ..
                } => out.push((join(path, alias.as_ref().unwrap_or(name)), *client)),
                SelectionPlan::Linked {
                    name,
                    alias,
                    client,
                    selections,
                    ..
                } => {
                    let here = join(path, alias.as_ref().unwrap_or(name));
                    out.push((here.clone(), *client));
                    walk(selections, &here, out);
                }
                SelectionPlan::Inline { selections, .. }
                | SelectionPlan::Condition { selections, .. } => walk(selections, path, out),
                SelectionPlan::Spread { .. } => {}
            }
        }
    }
    fn join(path: &str, key: &str) -> String {
        if path.is_empty() {
            key.to_string()
        } else {
            format!("{path}.{key}")
        }
    }
    let mut out = Vec::new();
    walk(&plan.operations[0].normalization, "", &mut out);
    out
}

/// The paths the plan marks as the client's.
fn client_paths(plan: &crate::pipeline::plan::Plan) -> Vec<String> {
    let mut paths: Vec<String> = marks(plan)
        .into_iter()
        .filter(|(_, client)| *client)
        .map(|(path, _)| path)
        .collect();
    paths.sort();
    paths.dedup();
    paths
}

const PINNED: &str =
    "query Probe($id: ID!) { character(id: $id) { id name status isPinned note } }";
const SERVER: &str = "query Probe($id: ID!) { character(id: $id) { id name status } }";
const DRAFTS: &str =
    "query Probe { drafts { id text about { id name } } character(id: \"1\") { id name } }";

#[test]
fn the_plan_marks_each_client_field_and_everything_under_a_client_link() {
    let extensions = [extension()];
    assert_eq!(
        client_paths(&compiled(&extensions, PINNED)),
        vec!["character.isPinned", "character.note"]
    );
    assert_eq!(
        client_paths(&compiled(&extensions, DRAFTS)),
        vec![
            "drafts",
            "drafts.about",
            "drafts.about.id",
            "drafts.about.name",
            "drafts.id",
            "drafts.text",
        ],
        "a server field below a client link is the client's too, and the server's own `character` is not"
    );
}

#[test]
fn a_document_without_client_fields_marks_nothing() {
    let plan = compiled(&[extension()], SERVER);
    assert!(!marks(&plan).is_empty());
    assert!(client_paths(&plan).is_empty(), "{:?}", marks(&plan));
}

#[test]
fn the_text_and_the_id_leave_the_client_fields_out_and_differ_from_the_server_s_document_by_nothing_else()
 {
    let extensions = [extension()];
    let pinned = compiled(&extensions, PINNED);
    let server = compiled(&extensions, SERVER);
    let pinned = &pinned.operations[0];
    let server = &server.operations[0];
    assert!(!pinned.text.contains("isPinned"), "{}", pinned.text);
    assert!(!pinned.text.contains("note"), "{}", pinned.text);
    assert_eq!(pinned.text, server.text);
    assert_eq!(pinned.id, server.id);

    let drafts = compiled(&extensions, DRAFTS);
    let text = &drafts.operations[0].text;
    assert!(text.contains("character"), "{text}");
    assert!(!text.contains("drafts"), "{text}");
}

#[test]
fn a_non_null_client_field_is_refused_at_its_line_in_the_extension() {
    let (sdl, path) = schema();
    let text = "extend type Character {\n  pinnedAt: String!\n}\n";
    let diagnostics = compile(
        &sdl,
        &path,
        &[(text.to_string(), "extensions.graphql".to_string())],
        &[document(SERVER)],
        &config(),
    )
    .err()
    .expect("a non-null client field does not compile");
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec![
            "the client field `Character.pinnedAt` is non-null: a client field is nullable, since no server promises it"
        ]
    );
    let location = diagnostics[0].location();
    assert_eq!(
        location.source_location(),
        SourceLocationKey::standalone("extensions.graphql"),
        "the diagnostic points into the extension"
    );
    let span = location.span();
    assert_eq!(&text[span.start as usize..span.end as usize], "pinnedAt");
}

#[test]
fn an_operation_of_client_fields_alone_is_refused_at_its_name() {
    let (sdl, path) = schema();
    let text = "query OnlyDrafts { drafts { id text } }";
    let diagnostics = compile(&sdl, &path, &[extension()], &[document(text)], &config())
        .err()
        .expect("an operation of client fields alone does not compile");
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec![
            "`OnlyDrafts` selects client fields only; a server answers one field at least, so select a server field beside them"
        ]
    );
    let span = diagnostics[0].location().span();
    assert_eq!(&text[span.start as usize..span.end as usize], "OnlyDrafts");
}

#[test]
fn the_digest_folds_the_extensions_in_and_is_the_schema_s_alone_without_them() {
    let (sdl, _) = schema();
    let plain = compiled(&[], SERVER).schema_digest;
    assert_eq!(
        plain,
        format!("{:x}", md5::compute(sdl.as_bytes())),
        "without extensions the digest is what it was before they could be configured"
    );
    assert_eq!(compiled(&[], SERVER).schema_digest, plain);
    let extended = compiled(&[extension()], SERVER).schema_digest;
    assert_ne!(extended, plain);
    let (text, path) = extension();
    let edited = compiled(
        &[(
            text.replace("note: String", "note: String\n  rank: Int"),
            path,
        )],
        SERVER,
    )
    .schema_digest;
    assert_ne!(edited, extended, "an edit to an extension is a new digest");
}

#[test]
fn a_schema_extensions_entry_naming_a_directory_reads_its_graphql_files_in_name_order() {
    let directory = std::env::temp_dir().join(format!("batonc-extensions-{}", std::process::id()));
    std::fs::create_dir_all(&directory).expect("the directory is created");
    for name in ["b.graphql", "a.graphql", "notes.txt"] {
        std::fs::write(directory.join(name), "").expect("the file is written");
    }
    let files = crate::extension_files(&directory).expect("the directory is read");
    let file = crate::extension_files(&directory.join("b.graphql")).expect("a file is itself");
    std::fs::remove_dir_all(&directory).expect("the directory is removed");
    assert_eq!(
        files,
        vec![directory.join("a.graphql"), directory.join("b.graphql")]
    );
    assert_eq!(file, vec![directory.join("b.graphql")]);
}

/// The shared file `text` compiles to with the given extensions.
fn shared(extensions: &[(String, String)], text: &str) -> String {
    crate::emit::emit(&compiled(extensions, text))
        .expect("the plan emits")
        .shared
}

#[test]
fn the_shared_file_interns_a_schema_extension_s_slots_as_the_client_s_and_no_other() {
    let extensions = [extension()];
    let swift = shared(
        &extensions,
        &format!("{PINNED}\n{}", DRAFTS.replace("Probe", "Drafts")),
    );
    for line in [
        r#"static let isPinned = Baton.Registry.clientSlot(Types.Character, "isPinned")"#,
        r#"static let note = Baton.Registry.clientSlot(Types.Character, "note")"#,
        r#"static let about = Baton.Registry.clientSlot(Types.Draft, "about")"#,
        r#"static let id = Baton.Registry.clientSlot(Types.Draft, "id")"#,
        r#"static let text = Baton.Registry.clientSlot(Types.Draft, "text")"#,
        r#"static let drafts = Baton.Registry.clientSlot(Types.Query, "drafts")"#,
        r#"static let name = Baton.Registry.slot(Types.Character, "name")"#,
        r#"static let id = Baton.Registry.slot(Types.Character, "id")"#,
    ] {
        assert!(swift.contains(line), "{line} is missing from:\n{swift}");
    }
    assert!(
        !shared(&extensions, SERVER).contains("clientSlot"),
        "a module of server fields alone interns no client slot"
    );
}
