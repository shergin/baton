//! The page table: every URL on the site, what it is built from, and how
//! the navigation groups it. The principles and the decisions are read
//! from their directories, so a new record is a new page without a line
//! here.

use std::fs;
use std::path::Path;

/// Where a page's body comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// A markdown file under `site/content/`.
    Content(String),
    /// A markdown file in the repository, rendered with its links rewritten.
    Repo(String),
    /// A repository markdown file with site material inserted after named
    /// headings: the repository stays the single source of the text, the
    /// site adds the plates.
    RepoWith(String, Vec<(String, String)>),
    /// The front page.
    Home,
    /// A section's index: its pages with their blurbs.
    Index,
    /// The examples gallery.
    Gallery,
    /// The playground.
    Playground,
}

/// One page.
#[derive(Debug, Clone)]
pub struct Page {
    /// The site-absolute URL, always a directory (`/guide/reads/`).
    pub url: String,
    /// The title, as the navigation and the browser tab show it.
    pub title: String,
    /// One line for the section index and the search results.
    pub blurb: String,
    /// Where the body comes from.
    pub source: Source,
    /// Whether the sidebar lists it; an unlisted page is reached from its
    /// section's index.
    pub listed: bool,
}

impl Page {
    /// The output path relative to the output directory.
    pub fn path(&self) -> String {
        format!("{}index.html", self.url.trim_start_matches('/'))
    }

    /// The relative prefix that reaches the site root from this page.
    pub fn root(&self) -> String {
        let depth = self
            .url
            .trim_matches('/')
            .split('/')
            .filter(|part| !part.is_empty())
            .count();
        "../".repeat(depth)
    }

    /// The repository directory relative links in this page's source
    /// resolve against.
    pub fn source_dir(&self) -> String {
        match &self.source {
            Source::Repo(path) | Source::RepoWith(path, _) => {
                path.rsplit_once('/').map_or("", |(dir, _)| dir).to_string()
            }
            _ => String::new(),
        }
    }

    /// The repository path the page is rendered from, if any.
    pub fn repo_path(&self) -> Option<&str> {
        match &self.source {
            Source::Repo(path) | Source::RepoWith(path, _) => Some(path),
            _ => None,
        }
    }

    /// Whether the search index lists the page.
    pub fn searchable(&self) -> bool {
        !matches!(self.source, Source::Home)
    }
}

/// A navigation section.
#[derive(Debug, Clone)]
pub struct Section {
    pub title: String,
    pub pages: Vec<Page>,
}

fn page(url: &str, title: &str, blurb: &str, source: Source) -> Page {
    Page {
        url: url.to_string(),
        title: title.to_string(),
        blurb: blurb.to_string(),
        source,
        listed: true,
    }
}

fn content(url: &str, title: &str, blurb: &str, file: &str) -> Page {
    page(url, title, blurb, Source::Content(file.to_string()))
}

fn repo(url: &str, title: &str, blurb: &str, file: &str) -> Page {
    page(url, title, blurb, Source::Repo(file.to_string()))
}

fn repo_with(url: &str, title: &str, blurb: &str, file: &str, inserts: &[(&str, &str)]) -> Page {
    page(
        url,
        title,
        blurb,
        Source::RepoWith(
            file.to_string(),
            inserts
                .iter()
                .map(|(heading, material)| (heading.to_string(), material.to_string()))
                .collect(),
        ),
    )
}

/// The navigation, in order.
pub fn sections(root: &Path) -> Vec<Section> {
    vec![
        Section {
            title: "Start here".to_string(),
            pages: vec![
                page(
                    "/",
                    "Baton",
                    "Relay for SwiftUI and Compose: a fragment beside every view, one request per screen, cached data in the first frame, and a re-render only where a field changed.",
                    Source::Home,
                ),
                content(
                    "/start/",
                    "Getting started",
                    "Install, the schema, the first screen, the first fragment, and the first list. SwiftUI and Compose side by side.",
                    "start.md",
                ),
                content(
                    "/graphql/",
                    "GraphQL for mobile engineers",
                    "What a schema is, what a document asks, why the response has the document's shape, what an id buys, and what Relay adds. No prior GraphQL needed.",
                    "graphql.md",
                ),
                content(
                    "/walkthrough/",
                    "One screen, end to end",
                    "A screen followed from the fragment beside its view to the frame it renders: the operation the compiler assembles, the request, the response, the records, the reads, the one view that re-renders, and the image on disk.",
                    "walkthrough.md",
                ),
                page(
                    "/playground/",
                    "Playground",
                    "Write a fragment and a query in the browser and watch the compiler answer: the lens in Swift and Kotlin, the operation's text, and the diagnostic that names the character that is wrong.",
                    Source::Playground,
                ),
            ],
        },
        Section {
            title: "The guide".to_string(),
            pages: vec![
                content(
                    "/guide/concepts/",
                    "The twelve words",
                    "Schema, document, directive, lens, record, store, plan, operation value, connection, environment, transport, phase: the closed vocabulary, one plate each.",
                    "guide/concepts.md",
                ),
                content(
                    "/guide/reads/",
                    "Reads",
                    "A query per screen, a fragment per view, a lens per fragment, and a phase a view switches over. Fetch policies, refetch, retry.",
                    "guide/reads.md",
                ),
                content(
                    "/guide/store/",
                    "The store",
                    "Records by type and id, the commit, what a view observes, roots and collection, and the image on disk that renders the next launch.",
                    "guide/store.md",
                ),
                content(
                    "/guide/lists/",
                    "Lists",
                    "A connection on a refetchable fragment: pages merged in the store, `loadNext` on the lens, and the edge directives that add to or remove from it.",
                    "guide/lists.md",
                ),
                content(
                    "/guide/writes/",
                    "Writes",
                    "A mutation is an action; an optimistic response shows at once and is reverted on failure; nothing edits the cache by hand.",
                    "guide/writes.md",
                ),
                content(
                    "/guide/honest-data/",
                    "Honest data",
                    "Nullability as the schema says it, `@required` and `@catch`, field errors that survive caching, missing data that heals, enums and mapped scalars.",
                    "guide/honest-data.md",
                ),
                content(
                    "/guide/live/",
                    "Live data",
                    "Subscriptions as a stream of events into the store, deferred fragments, streamed lists, and what a handle does when the connection drops or the app sleeps.",
                    "guide/live.md",
                ),
                content(
                    "/guide/compiler/",
                    "The compiler",
                    "What `batonc` reads, what it checks, what it writes, and how the build runs it: SwiftPM, Gradle, Bazel, or the command line.",
                    "guide/compiler.md",
                ),
                content(
                    "/guide/environment/",
                    "The environment",
                    "The one door: the transport with one verb, the session that ends at sign-out, the log of value-free events, and a store without a server for previews and tests.",
                    "guide/environment.md",
                ),
                content(
                    "/guide/kotlin/",
                    "Compose",
                    "The same screens in Kotlin: where the marker stands, what differs in spelling, and the Gradle setup.",
                    "guide/kotlin.md",
                ),
            ],
        },
        Section {
            title: "Recipes".to_string(),
            pages: vec![
                page(
                    "/recipes/",
                    "Recipes",
                    "One page per composition of what ships: the shape of a screen, the exchange, testing, UIKit, view models, porting from Relay, and the build integrations.",
                    Source::Index,
                ),
                repo(
                    "/recipes/agents/",
                    "Agents",
                    "The page a coding agent reads first: what to read, the shape of a screen, what never to write, what to run, and a review checklist.",
                    "docs/recipes/agents.md",
                ),
                repo(
                    "/recipes/testing/",
                    "Previews and tests",
                    "A store without a server: a fixture committed as a response, recorded transports, a held mutation, a rule tested with a value.",
                    "docs/recipes/testing.md",
                ),
                repo(
                    "/recipes/exchange/",
                    "The exchange",
                    "A challenge, a retry and a deadline over the transport's one verb, compiled in both runtimes.",
                    "docs/recipes/exchange.md",
                ),
                repo(
                    "/recipes/uikit/",
                    "UIKit and AppKit",
                    "A handle held by a controller: the same reads, without SwiftUI.",
                    "docs/recipes/uikit.md",
                ),
                repo(
                    "/recipes/views/",
                    "Views and view models",
                    "A Kotlin handle without a composition: a view model behind Android Views reads through `snapshotFlow`.",
                    "docs/recipes/views.md",
                ),
                repo(
                    "/recipes/outside-views/",
                    "Outside views",
                    "A fetch, a read and a write from code that is not a view: a service, a background refresh, a notification handler.",
                    "docs/recipes/outside-views.md",
                ),
                repo(
                    "/recipes/derived-state/",
                    "Derived state outside views",
                    "A model over `Observations` that keeps a value computed from the store.",
                    "docs/recipes/derived-state.md",
                ),
                repo(
                    "/recipes/discover-once/",
                    "Discover once, refresh by id",
                    "The pattern for external keys: look a subject up by its natural key once, then refresh any number of them through `nodes(ids:)`.",
                    "docs/recipes/discover-once.md",
                ),
                repo(
                    "/recipes/porting-from-relay/",
                    "Porting from Relay",
                    "Relay's words beside Baton's, in Swift and in Kotlin; what differs on purpose; what is not ported and why.",
                    "docs/recipes/porting-from-relay.md",
                ),
                repo(
                    "/recipes/batonc/",
                    "The compiler's command line",
                    "`batonc`: the command's contract for a build outside SwiftPM.",
                    "docs/recipes/batonc.md",
                ),
                repo(
                    "/recipes/gradle/",
                    "Gradle",
                    "The Kotlin runtime from Maven Central and the compiler as a task.",
                    "docs/recipes/gradle.md",
                ),
                repo(
                    "/recipes/bazel/",
                    "Bazel",
                    "The compiler as a toolchain and one rule over its command.",
                    "docs/recipes/bazel.md",
                ),
            ],
        },
        Section {
            title: "Examples".to_string(),
            pages: vec![page(
                "/examples/",
                "The gallery",
                "Every sample in the repository, Swift and Kotlin, with what the compiler found in it: the GitHub triage apps, Rick and Morty, UIKit and AppKit controllers, the exchange, and Caton.",
                Source::Gallery,
            )],
        },
        Section {
            title: "Why it is shaped this way".to_string(),
            pages: why(root),
        },
        Section {
            title: "Articles".to_string(),
            pages: articles(),
        },
        Section {
            title: "Reference".to_string(),
            pages: vec![
                repo_with(
                    "/terminology/",
                    "Terminology",
                    "The vocabulary contract: each word's meaning in the literature, what it is here, and how Swift and Kotlin spell it.",
                    "docs/terminology.md",
                    &[
                        (
                            "## Documents",
                            "{{host issues IssueRow | A document in its marker, SwiftUI and Compose.}}",
                        ),
                        (
                            "## Generated",
                            "{{lens issues IssuesQuery | An operation's data lens as the compiler reported it, nested lens by nested lens.}}",
                        ),
                        (
                            "## Store",
                            "{{normalize spec/rickandmorty/character-header-9 | A response and the records it became.}}",
                        ),
                        (
                            "## Compiler",
                            "{{diagnostics typo | A diagnostic, pointing into the host.}}",
                        ),
                        (
                            "## Runtime",
                            "{{script phase steps=1,2,4,5 | Phases and fetches, from the specification's script.}}",
                        ),
                        (
                            "## Lists",
                            "{{script connections steps=1,2 | Two pages merged in the store.}}",
                        ),
                    ],
                ),
                repo(
                    "/contract/",
                    "The runtime contract",
                    "What a Baton runtime does with a plan, a response and a store, one paragraph a rule, each naming the fixture that holds it.",
                    "spec/runtime.md",
                ),
                repo(
                    "/spec/",
                    "The specification",
                    "The fixtures both runtimes are held to: schemas, documents, recorded responses, the records a store must hold, and the scripts over time.",
                    "spec/README.md",
                ),
                repo(
                    "/runtimes/",
                    "The two runtimes, one map",
                    "A file per concept in the Swift and the Kotlin tree, checked by the boundary script.",
                    "docs/runtimes.md",
                ),
                repo(
                    "/kotlin/",
                    "The Kotlin runtime",
                    "The layout of the Kotlin tree, its dependencies, and how it is built and published.",
                    "kotlin/README.md",
                ),
                repo(
                    "/changelog/",
                    "Changelog",
                    "Every release, named for a bread, written for a person.",
                    "CHANGELOG.md",
                ),
            ],
        },
    ]
}

/// The vision, the principles, the decisions and the comparisons.
fn why(root: &Path) -> Vec<Page> {
    let mut pages = vec![
        repo_with(
            "/vision/",
            "Vision",
            "The argument: three commitments and five rules.",
            "docs/vision.md",
            &[(
                "## The rules",
                "{{stage characters CharactersQuery spec/rickandmorty/characters-page-1.store.json rows=4 | The five rules on one screen: a fragment is a lens, the store is the UI's state, and a change to a field re-renders the view that read it. Click a field.}}",
            )],
        ),
        repo_with(
            "/why-graphql/",
            "Why GraphQL",
            "For iOS and Android engineers who build on REST and view models: what it is, what it changes, what it costs.",
            "docs/why-graphql.md",
            &[
                (
                    "## What GraphQL solves",
                    "{{source spec/rickandmorty/schema.graphql lines=7-32 | A schema's root type and one object type, from the Rick and Morty API. The whole schema is on the GraphQL chapter.}}",
                ),
                (
                    "## What Relay solves",
                    "{{normalize spec/rickandmorty/character-header-9 | One store: a response and the records it became, each object once, by type and id.}}",
                ),
                (
                    "## What Baton adds",
                    "{{lens issues IssueRow_issue | The lens a fragment compiles to: one accessor per declared field.}}",
                ),
            ],
        ),
    ];
    let illustrated: &[(&str, &str, &str)] = &[
        (
            "fragment-is-a-lens",
            "## The idea",
            "{{lens issue-list IssueList_repository | A lens over a connection, as reported: a reference and one accessor per declared field, nested lenses for links, and nothing else.}}",
        ),
        (
            "store-is-the-ui-state",
            "## The idea",
            "{{script notifications steps=2,3 | A commit that changes nothing notifies nothing; a commit that changes one field notifies one slot.}}",
        ),
        (
            "response-is-the-oracle",
            "## The idea",
            "{{case rickandmorty/character-header-9 | A case of the manifest: the reads a lens must answer after the response, and the override an optimistic layer must read.}}",
        ),
        (
            "compiler-decides",
            "## The idea",
            "{{operation issues IssuesQuery | What the compiler settled: the fragment inlined, the key fields added, the text printed once and hashed.}}",
        ),
        (
            "honest-data",
            "## The idea",
            "{{script heal steps=2,3 | Missing data reported and healed: the read logs the miss and the owner refetches.}}",
        ),
        (
            "what-earns-a-concept",
            "## The idea",
            "{{script connections steps=4 | A list edited by a directive on a payload: a composition of connection, plan and store, not a concept of its own.}}",
        ),
        (
            "relays-words",
            "## The idea",
            "{{operation comments CommentComposerAddComment | Relay's directive on the client's side of the line: `@appendEdge` is left out of the text the server receives.}}",
        ),
        (
            "two-runtimes-one-compiler",
            "## The idea",
            "{{generated characters CharactersScreen | One plan, two emitters: the same operation's generated code in Swift and in Kotlin.}}",
        ),
    ];
    for (file, heading, material) in illustrated {
        let path = format!("docs/principles/{file}.md");
        let (title, blurb) = title_and_blurb(&root.join(&path));
        pages.push(repo_with(
            &format!("/principles/{file}/"),
            &title,
            &blurb,
            &path,
            &[(heading, material)],
        ));
    }
    pages.push(page(
        "/decisions/",
        "Decisions",
        "Choices made among real alternatives, with the evidence that decided them and the condition that would reopen them.",
        Source::Index,
    ));
    let mut decisions: Vec<String> = fs::read_dir(root.join("docs/decisions"))
        .expect("docs/decisions")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().to_string())
        .filter(|name| name.ends_with(".md") && name != "README.md")
        .collect();
    decisions.sort();
    for name in decisions {
        let stem = name.trim_end_matches(".md");
        let path = format!("docs/decisions/{name}");
        let (title, blurb) = title_and_blurb(&root.join(&path));
        let mut page = repo(&format!("/decisions/{stem}/"), &title, &blurb, &path);
        page.listed = false;
        pages.push(page);
    }
    pages
}

/// The design argued at length: one essay per choice that shapes the
/// library, in reading order, each read from `docs/articles/`.
fn articles() -> Vec<Page> {
    let essays: &[(&str, &str, &str)] = &[
        (
            "relay-without-the-read-side",
            "Relay without the read side",
            "Why Baton keeps Relay's compiler and the write side of its store and deletes the read side: Observation and snapshot state already answer the question Relay's runtime was built to answer.",
        ),
        (
            "what-meta-built",
            "What Meta built, and what you can download",
            "Meta's native apps run an in-house GraphQL client that is not public. What its engineers have said about it, where Baton makes the same choices, and where Baton goes further.",
        ),
        (
            "materialization-is-the-bill",
            "Materialization is the bill",
            "Why Baton is faster than Apollo iOS and Apollo Kotlin on the same data: not a faster store, but three steps it never takes. The numbers on a Mac and on a phone, and the caveats.",
        ),
        (
            "the-first-frame",
            "The first frame has the data",
            "A warm cache that still shows a spinner is a design, not a bug. Why reads are synchronous on the main actor, what the image on disk does before the first body, and what a phone measured.",
        ),
        (
            "two-runtimes-no-bridge",
            "Two runtimes, no bridge",
            "The compiler is Rust; the runtimes are Swift and Kotlin, written twice on purpose. Why a shared core would cost the read path the design exists for, and what holds two runtimes to one behaviour.",
        ),
        (
            "a-compiler-not-a-configuration",
            "A compiler, not a configuration",
            "Every operation is static, so identity, storage keys, masking, persisted ids and diagnostics are settled at build time. Why the runtime has no parser and no policy object, and why that matters more now that agents write screens.",
        ),
        (
            "how-a-fast-store-stays-honest",
            "How a fast store stays honest",
            "A normalized store is a chain of clever steps, and every step is a place to lose a value. The oracle, the fixtures, Relay's own tests and the benches that keep Baton's answers equal to the server's, on both runtimes.",
        ),
        (
            "twelve-words",
            "Twelve words, and why the list is closed",
            "GraphQL clients die of configuration. Baton's vocabulary is twelve concepts and Relay's directives; what that refuses, what it buys, and how it looks beside a client that dropped GraphQL.",
        ),
        (
            "baton-beside-fate",
            "Baton beside fate",
            "fate takes Relay's three insights and removes GraphQL; Baton takes them and keeps the compiler. Where the two agree, where they part, three of fate's mechanisms Baton watches, and a proof against fate's own server.",
        ),
        (
            "the-small-lies",
            "The small lies a client tells",
            "Every field optional, an error hidden behind a null, a failure that is a string, missing data that is nothing, a value that does not fit read as zero, cached served as fresh: six lies, and the mechanism that refuses each.",
        ),
        (
            "settled-stays-settled",
            "Settled stays settled",
            "How Baton is built: research first, principles with the mechanism that fails when they rot, decisions with the condition that reopens them, spikes with gates written first, fixtures as the oracle, and a release whenever there is something to use.",
        ),
    ];
    let mut pages = vec![page(
        "/articles/",
        "Articles",
        "The design argued at length: one essay per choice that shapes the library, with the evidence behind it and the alternatives it refused.",
        Source::Index,
    )];
    for (stem, title, blurb) in essays {
        pages.push(repo(
            &format!("/articles/{stem}/"),
            title,
            blurb,
            &format!("docs/articles/{stem}.md"),
        ));
    }
    pages
}

/// A repository document's title, from its first heading, and its blurb,
/// from the first paragraph after it.
fn title_and_blurb(path: &Path) -> (String, String) {
    let text =
        fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let mut lines = text.lines();
    let title = lines
        .by_ref()
        .find_map(|line| line.strip_prefix("# "))
        .unwrap_or("Untitled")
        .trim()
        .to_string();
    let mut blurb = String::new();
    for line in lines {
        let line = line.trim();
        if line.is_empty() {
            if blurb.is_empty() {
                continue;
            }
            break;
        }
        if !blurb.is_empty() {
            blurb.push(' ');
        }
        blurb.push_str(line);
    }
    (title, strip_markdown(&blurb))
}

/// Links and emphasis out of a line of markdown, for a blurb.
fn strip_markdown(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '[' => {}
            ']' => {
                if chars.peek() == Some(&'(') {
                    for c in chars.by_ref() {
                        if c == ')' {
                            break;
                        }
                    }
                }
            }
            '*' | '_' | '`' => {}
            c => out.push(c),
        }
    }
    out
}

/// Every page, flattened.
pub fn all(sections: &[Section]) -> impl Iterator<Item = &Page> {
    sections.iter().flat_map(|section| section.pages.iter())
}

/// The site URL a repository path is published at, if any.
pub fn url_for(sections: &[Section], repo_path: &str) -> Option<String> {
    let path = repo_path.trim_start_matches("./").trim_end_matches('/');
    let fixed = match path {
        "README.md" | "site/README.md" | "docs/README.md" | "docs" => Some("/"),
        "docs/principles" => Some("/vision/#principles"),
        "docs/decisions" | "docs/decisions/README.md" => Some("/decisions/"),
        "docs/articles" | "docs/articles/README.md" => Some("/articles/"),
        "docs/recipes" => Some("/recipes/"),
        "docs/openings" => Some("/vision/#openings"),
        "examples" => Some("/examples/"),
        "spec" => Some("/spec/"),
        "kotlin" => Some("/kotlin/"),
        "kotlin/samples" => Some("/examples/"),
        _ => None,
    };
    if let Some(url) = fixed {
        return Some(url.to_string());
    }
    if let Some(page) = all(sections).find(|page| page.repo_path() == Some(path)) {
        return Some(page.url.clone());
    }
    crate::gallery::url_for(path)
}
