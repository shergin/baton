//! Tests of client schema extensions: the plan marks each client field, the
//! text a server receives leaves them out, the digest folds the extensions
//! in, and an extension or an operation no server can serve is refused. And
//! of the schema read from several files, where an extension declares the
//! server's fields: the place a file is listed in says whose its fields
//! are, whatever keyword declares them.

use super::*;

/// The extension the Swift test target reads.
fn extension() -> SchemaFile {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/extensions.graphql");
    SchemaFile::new(
        std::fs::read_to_string(&path).expect("the test extension is readable"),
        path.to_string_lossy(),
    )
}

/// The test schema, with the given client extensions.
fn extended(extensions: &[SchemaFile]) -> SchemaSources {
    let (sdl, path) = schema();
    SchemaSources {
        extensions: extensions.to_vec(),
        ..one_file(&sdl, &path)
    }
}

fn config() -> Config {
    Config {
        path: PathBuf::from("baton.json"),
        ..Config::default()
    }
}

/// The plan of `text` with the given extensions.
fn compiled(extensions: &[SchemaFile], text: &str) -> crate::pipeline::plan::Plan {
    compile(&extended(extensions), &[document(text)], &config())
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
    let text = "extend type Character {\n  pinnedAt: String!\n}\n";
    let diagnostics = compile(
        &extended(&[SchemaFile::new(text, "extensions.graphql")]),
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
fn a_query_of_client_fields_alone_is_client_only_and_keeps_its_fields_in_its_text() {
    let text = "query OnlyDrafts {\n  drafts {\n    id\n    text\n  }\n}";
    let mut config: Config =
        serde_json::from_str(r#"{"persistConfig": {"file": "persisted.json"}}"#)
            .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let plan = compile(&extended(&[extension()]), &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    let operation = &plan.operations[0];
    assert!(operation.client_only);
    assert_eq!(
        operation.text, "query OnlyDrafts{drafts{id,text}}",
        "the text is the author's document, printed compact"
    );
    assert_eq!(
        operation.id, None,
        "a client-only query is never registered"
    );
    assert_eq!(
        crate::persisted_documents(&plan),
        "{}\n",
        "the persisted documents file leaves it out"
    );
    let report = serde_json::to_value(crate::report::report(&plan, Path::new("/nowhere")))
        .expect("the report serializes");
    assert_eq!(report["operations"][0]["clientOnly"], true);

    let server = compiled(&[extension()], DRAFTS);
    assert!(!server.operations[0].client_only);
    let report = serde_json::to_value(crate::report::report(&server, Path::new("/nowhere")))
        .expect("the report serializes");
    assert!(
        report["operations"][0].get("clientOnly").is_none(),
        "the report says `clientOnly` only of a client-only query"
    );
}

#[test]
fn a_mutation_or_a_subscription_of_client_fields_alone_is_refused_at_its_name() {
    // The test target's extension has no client field on either root, so
    // this test adds one to each.
    let roots = SchemaFile::new(
        "extend type Mutation {\n  saveDraft: Draft\n}\nextend type Subscription {\n  draftSaved: Draft\n}\n",
        "roots.graphql",
    );
    for (text, kind) in [
        ("mutation OnlyDrafts { saveDraft { id text } }", "mutation"),
        (
            "subscription OnlyDrafts { draftSaved { id text } }",
            "subscription",
        ),
    ] {
        let diagnostics = compile(
            &extended(&[extension(), roots.clone()]),
            &[document(text)],
            &config(),
        )
        .err()
        .unwrap_or_else(|| panic!("a {kind} of client fields alone does not compile"));
        let messages: Vec<String> = diagnostics
            .iter()
            .map(|diagnostic| diagnostic.message().to_string())
            .collect();
        assert_eq!(
            messages,
            vec![format!(
                "`OnlyDrafts` selects client fields only; a {kind} is the server's to answer, so select a server field beside them, and declare a field another backend answers in the schema, not in `schemaExtensions`"
            )]
        );
        let span = diagnostics[0].location().span();
        assert_eq!(&text[span.start as usize..span.end as usize], "OnlyDrafts");
    }
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
    let original = extension();
    let edited = compiled(
        &[SchemaFile::new(
            original
                .text
                .replace("note: String", "note: String\n  rank: Int"),
            original.path,
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
    let files = crate::graphql_files(&directory).expect("the directory is read");
    let file = crate::graphql_files(&directory.join("b.graphql")).expect("a file is itself");
    std::fs::remove_dir_all(&directory).expect("the directory is removed");
    assert_eq!(
        files,
        vec![directory.join("a.graphql"), directory.join("b.graphql")]
    );
    assert_eq!(file, vec![directory.join("b.graphql")]);
}

/// The shared file `text` compiles to with the given extensions.
fn shared(extensions: &[SchemaFile], text: &str) -> String {
    crate::emit::swift(&compiled(extensions, text), &config())
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

// The schema of several files.

/// A second backend the app's transport answers for, declared beside the
/// server's schema: a root field on the server's own `Subscription`.
const FEED: &str = "extend type Subscription {\n  feed(id: ID!): Ticker!\n}\n\ntype Ticker {\n  id: ID!\n  price: Float!\n}\n";

/// A subscription of the feed's field alone.
const PRICES: &str =
    "subscription Prices($id: ID!) {\n  prices: feed(id: $id) {\n    id\n    price\n  }\n}";

/// The test schema followed by `files`, each a schema file, without client
/// extensions.
fn schema_files(files: &[SchemaFile]) -> SchemaSources {
    let (sdl, path) = schema();
    let mut sources = one_file(&sdl, &path);
    sources.schema.extend(files.iter().cloned());
    sources
}

/// The configuration that persists every operation the server is sent.
fn persisting() -> Config {
    let mut config: Config =
        serde_json::from_str(r#"{"persistConfig": {"file": "persisted.json"}}"#)
            .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    config
}

/// The messages compiling `text` against `sources` fails with.
fn refusals(sources: &SchemaSources, text: &str) -> Vec<String> {
    match compile(sources, &[document(text)], &config()) {
        Ok(_) => Vec::new(),
        Err(diagnostics) => diagnostics
            .iter()
            .map(|diagnostic| diagnostic.message().to_string())
            .collect(),
    }
}

#[test]
fn an_extension_in_a_schema_file_declares_server_fields_the_server_is_sent_and_a_persisted_id_covers()
 {
    let sources = schema_files(&[SchemaFile::new(FEED, "feed.graphql")]);
    let plan = compile(&sources, &[document(PRICES)], &persisting())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    let operation = &plan.operations[0];
    assert!(!operation.client_only);
    assert!(
        client_paths(&plan).is_empty(),
        "a schema file's extension declares no client field: {:?}",
        marks(&plan)
    );
    assert_eq!(
        marks(&plan),
        vec![
            ("prices".to_string(), false),
            ("prices.id".to_string(), false),
            ("prices.price".to_string(), false),
        ]
    );
    assert_eq!(
        operation.text, "subscription Prices($id:ID!){prices:feed(id:$id){id,price}}",
        "the text sends the extension's field"
    );
    assert!(operation.id.is_some(), "the subscription is persisted");
    let swift = crate::emit::swift(&plan, &config())
        .expect("the plan emits")
        .shared;
    assert!(
        swift.contains(r#"Baton.Registry.slot(Types.Ticker, "price")"#),
        "{swift}"
    );
    assert!(!swift.contains("clientSlot"), "{swift}");
}

#[test]
fn the_same_extension_under_schema_extensions_declares_client_fields_and_is_refused_as_non_null() {
    let feed = SchemaFile::new(FEED, "feed.graphql");
    let messages = refusals(&extended(&[feed]), PRICES);
    assert_eq!(
        messages,
        vec![
            "the client field `Subscription.feed` is non-null: a client field is nullable, since no server promises it",
            "the client field `Ticker.id` is non-null: a client field is nullable, since no server promises it",
            "the client field `Ticker.price` is non-null: a client field is nullable, since no server promises it",
        ]
    );
    let nullable = SchemaFile::new(FEED.replace('!', ""), "feed.graphql");
    let messages = refusals(&extended(&[nullable]), &PRICES.replace("ID!", "ID"));
    assert_eq!(
        messages,
        vec![
            "`Prices` selects client fields only; a subscription is the server's to answer, so select a server field beside them, and declare a field another backend answers in the schema, not in `schemaExtensions`"
        ]
    );
}

#[test]
fn an_extension_written_before_its_type_in_the_same_schema_file_is_built() {
    let text = "extend type Ticker {\n  change: Float!\n}\n\nextend type Subscription {\n  feed(id: ID!): Ticker!\n}\n\ntype Ticker {\n  id: ID!\n  price: Float!\n}\n";
    let sources = schema_files(&[SchemaFile::new(text, "feed.graphql")]);
    let plan = compile(
        &sources,
        &[document(&PRICES.replace("price\n", "price\n    change\n"))],
        &config(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"))
    .plan;
    assert!(client_paths(&plan).is_empty(), "{:?}", marks(&plan));
    assert!(
        plan.operations[0].text.contains("change"),
        "{}",
        plan.operations[0].text
    );
}

#[test]
fn an_extension_in_a_schema_file_extends_a_type_of_another_schema_file_listed_before_or_after_it() {
    let (sdl, path) = schema();
    let rank = SchemaFile::new("extend type Character {\n  rank: Int!\n}\n", "rank.graphql");
    let server = SchemaFile::new(sdl, path);
    let text = "query Ranked { character(id: \"1\") { id rank } }";
    for files in [
        vec![server.clone(), rank.clone()],
        vec![rank.clone(), server.clone()],
    ] {
        let order: Vec<&str> = files.iter().map(|file| file.path.as_str()).collect();
        let sources = SchemaSources {
            schema: files.clone(),
            extensions: Vec::new(),
        };
        let plan = compile(&sources, &[document(text)], &config())
            .unwrap_or_else(|errors| panic!("{order:?}: {errors:?}"))
            .plan;
        assert!(
            client_paths(&plan).is_empty(),
            "{order:?}: {:?}",
            marks(&plan)
        );
        assert_eq!(
            plan.operations[0].text, "query Ranked{character(id:\"1\"){id,rank}}",
            "{order:?}"
        );
    }
}

#[test]
fn an_interface_extension_in_a_schema_file_declares_server_fields() {
    let text = "extend interface Named {\n  initials: String!\n}\n";
    let sources = schema_files(&[SchemaFile::new(text, "named.graphql")]);
    let query = "query Initials { namesake(name: \"a\") { initials } }";
    let plan = compile(&sources, &[document(query)], &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    assert!(client_paths(&plan).is_empty(), "{:?}", marks(&plan));
    assert!(
        plan.operations[0].text.contains("initials"),
        "{}",
        plan.operations[0].text
    );

    let nullable = SchemaFile::new(text.replace('!', ""), "named.graphql");
    let plan = compiled(&[nullable], query);
    assert_eq!(
        client_paths(&plan),
        vec!["namesake.initials"],
        "under `schemaExtensions` the same extension is the client's"
    );
}

#[test]
fn an_enum_extension_in_a_schema_file_adds_a_value_a_document_passes_and_the_server_is_sent() {
    let text = "extend enum Status {\n  ZOMBIE\n}\n";
    let sources = schema_files(&[SchemaFile::new(text, "status.graphql")]);
    let query = "query Zombies { charactersWithStatus(status: ZOMBIE) { id } }";
    let plan = compile(&sources, &[document(query)], &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    assert!(client_paths(&plan).is_empty(), "{:?}", marks(&plan));
    assert_eq!(
        plan.operations[0].text,
        "query Zombies{charactersWithStatus(status:ZOMBIE){id}}"
    );
    // A value the document reads is a case of the enum it reads as.
    let read = compile(
        &sources,
        &[document("mutation Lists { setLists { statuses } }")],
        &config(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"))
    .plan;
    let swift = crate::emit::swift(&read, &config())
        .expect("the plan emits")
        .shared;
    assert!(swift.contains("case ZOMBIE"), "{swift}");
}

#[test]
fn a_union_extension_in_a_schema_file_adds_a_member_a_document_spreads_on_and_the_server_is_sent() {
    let text = "extend union SearchResult = Note\n";
    let sources = schema_files(&[SchemaFile::new(text, "search.graphql")]);
    let query = "query Notes { search(name: \"a\") { __typename ... on Note { id text } } }";
    let plan = compile(&sources, &[document(query)], &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    assert!(client_paths(&plan).is_empty(), "{:?}", marks(&plan));
    assert!(
        plan.operations[0]
            .text
            .starts_with("query Notes{search(name:\"a\"){__typename,...on Note{id,text}"),
        "the text keeps the spread on the added member: {}",
        plan.operations[0].text
    );
    let unextended = refusals(&schema_files(&[]), query);
    assert_eq!(
        unextended.len(),
        1,
        "without the extension `Note` is no member: {unextended:?}"
    );
}

/// The three extensions Relay's front end does not build, each with the
/// keyword its diagnostic names.
const UNBUILT: [(&str, &str); 3] = [
    ("extend schema @deprecated", "schema"),
    ("extend input FilterCharacter {\n  rank: Int\n}", "input"),
    ("extend scalar DateTime @deprecated", "scalar"),
];

/// `extension` written in a file of comments and a type, on its third line.
fn unbuilt_file(extension: &str) -> String {
    format!("# A file that extends what it cannot.\n\n{extension}\n\ntype Extra {{\n  id: ID\n}}\n")
}

#[test]
fn an_extension_relay_does_not_build_is_an_error_at_what_it_extends_in_a_schema_file_and_in_an_extension_file()
 {
    let mut rendered = Vec::new();
    for (extension, keyword) in UNBUILT {
        let text = unbuilt_file(extension);
        let file = SchemaFile::new(text.as_str(), "extra.graphql");
        for (sources, place) in [
            (schema_files(std::slice::from_ref(&file)), "a schema file"),
            (extended(std::slice::from_ref(&file)), "an extension file"),
        ] {
            let diagnostics = compile(&sources, &[document(SERVER)], &config())
                .err()
                .unwrap_or_else(|| panic!("`extend {keyword}` in {place} does not compile"));
            for diagnostic in &diagnostics {
                rendered.push(format!(
                    "{place}: {}",
                    crate::diagnostics::render(
                        diagnostic,
                        &[crate::documents::Document::schema("extra.graphql", &text)],
                    )
                ));
            }
        }
    }
    // Relay's span of an extension starts past `extend` and its keyword:
    // at the type's name, or at the directives of `extend schema`.
    let unbuilt = |keyword: &str, column: usize| {
        format!(
            "extra.graphql:3:{column}: error: `extend {keyword}` is not built: Relay's front end has no code for it, so write what it adds in the definition it extends"
        )
    };
    assert_eq!(
        rendered,
        vec![
            format!("a schema file: {}", unbuilt("schema", 15)),
            format!("an extension file: {}", unbuilt("schema", 15)),
            format!("a schema file: {}", unbuilt("input", 14)),
            format!("an extension file: {}", unbuilt("input", 14)),
            format!("a schema file: {}", unbuilt("scalar", 15)),
            format!("an extension file: {}", unbuilt("scalar", 15)),
        ]
    );
}

/// The digest of the plan of `SERVER` against `sources`.
fn digest_of(sources: &SchemaSources) -> String {
    compile(sources, &[document(SERVER)], &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
        .schema_digest
}

#[test]
fn the_digest_of_one_schema_file_is_the_file_s_own_md5() {
    let (sdl, path) = schema();
    assert_eq!(
        digest_of(&one_file(&sdl, &path)),
        format!("{:x}", md5::compute(sdl.as_bytes()))
    );
    assert_eq!(
        digest_of(&one_file(&sdl, "elsewhere/schema.graphql")),
        format!("{:x}", md5::compute(sdl.as_bytes())),
        "the file's path is no part of it"
    );
}

#[test]
fn the_digest_of_two_schema_files_is_the_same_in_either_order_and_under_other_paths() {
    let (sdl, path) = schema();
    let server = SchemaFile::new(sdl.as_str(), path);
    let feed = SchemaFile::new(FEED, "feed.graphql");
    let given = digest_of(&SchemaSources {
        schema: vec![server.clone(), feed.clone()],
        extensions: Vec::new(),
    });
    let reversed = digest_of(&SchemaSources {
        schema: vec![feed, server],
        extensions: Vec::new(),
    });
    assert_eq!(given, reversed);
    let renamed = digest_of(&SchemaSources {
        schema: vec![
            SchemaFile::new(FEED, "schema/b.graphql"),
            SchemaFile::new(sdl.as_str(), "schema/a.graphql"),
        ],
        extensions: Vec::new(),
    });
    assert_eq!(given, renamed);
    // The files' texts, sorted, joined by their separator.
    let mut texts = [sdl.as_str(), FEED];
    texts.sort_unstable();
    assert_eq!(
        given,
        format!("{:x}", md5::compute(texts.join("\n# schema\n").as_bytes()))
    );
}

#[test]
fn the_digest_of_two_schema_files_differs_from_either_file_alone_and_from_their_texts_in_one_file()
{
    let (sdl, path) = schema();
    let two = digest_of(&schema_files(&[SchemaFile::new(FEED, "feed.graphql")]));
    assert_ne!(two, digest_of(&one_file(&sdl, &path)));
    assert_ne!(two, format!("{:x}", md5::compute(FEED.as_bytes())));
    let joined = format!("{sdl}\n{FEED}");
    let one = digest_of(&one_file(&joined, "schema.graphql"));
    assert_eq!(one, format!("{:x}", md5::compute(joined.as_bytes())));
    assert_ne!(
        two, one,
        "the separator between the files is part of the digest"
    );
}

#[test]
fn the_order_of_the_client_extensions_changes_the_digest_and_their_place_does_too() {
    let drafts = extension();
    let feed = SchemaFile::new(FEED.replace('!', ""), "feed.graphql");
    let first = compiled(&[drafts.clone(), feed.clone()], SERVER).schema_digest;
    let second = compiled(&[feed.clone(), drafts], SERVER).schema_digest;
    assert_ne!(
        first, second,
        "the extensions keep the order they are listed in"
    );
    let served = digest_of(&schema_files(&[SchemaFile::new(FEED, "feed.graphql")]));
    assert_ne!(
        compiled(&[feed], SERVER).schema_digest,
        served,
        "the same fields are another digest as a schema file and as an extension"
    );
}
