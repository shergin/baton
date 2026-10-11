//! The examples gallery: every sample in the repository, Swift and Kotlin,
//! with what the compiler found in it when the page was built: the
//! operations, the fragments each spreads, and the variables.

use std::path::Path;

use serde_json::Value;

use crate::compiler::Language;
use crate::escape::escape;
use crate::figures::plate;
use crate::markdown::{self, Body, Context};

/// One sample.
pub struct Entry {
    /// The anchor on the gallery page.
    pub id: &'static str,
    pub title: &'static str,
    /// The directory in the repository.
    pub path: &'static str,
    /// The directory holding `baton.json`, relative to the repository;
    /// none for a sample without documents.
    pub config: Option<&'static str>,
    /// Where the hosts are, relative to the configuration's directory.
    pub hosts: &'static str,
    pub language: Language,
    /// The story, as markdown.
    pub story: &'static str,
    /// How to run it.
    pub run: &'static str,
}

const ENTRIES: &[Entry] = &[
    Entry {
        id: "github-triage",
        title: "GitHub triage, in SwiftUI",
        path: "examples/GitHubTriage",
        config: Some("examples/GitHubTriage"),
        hosts: ".",
        language: Language::Swift,
        story: "What the viewer has to look at: open issues and pull requests assigned to or created by them, a repository with a star toggle, and an issue with its comments and reactions. Reads, writes with optimistic responses, interfaces and a union, a connection a mutation appends to, `@required` and `@catch`, and a lookup by id, against a schema of about 1,800 definitions. The README's screen is this app's.",
        run: "GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage",
    },
    Entry {
        id: "github-kotlin",
        title: "GitHub triage, in Compose",
        path: "kotlin/samples/github",
        config: Some("kotlin/samples/github"),
        hosts: "src/jvmMain/kotlin/baton/github",
        language: Language::Kotlin,
        story: "The same screens over GitHub's API, as a Compose for Desktop app: the same documents, the same lenses and the same phase, in Kotlin's words. It sends through the Kotlin exchange and keeps an image in the user's cache directory, so a relaunch renders before the network answers.",
        run: "GITHUB_TOKEN=$(gh auth token) gradle :samples:github:run",
    },
    Entry {
        id: "rick-and-morty",
        title: "Rick and Morty, in SwiftUI",
        path: "examples/RickAndMorty",
        config: Some("examples/RickAndMorty"),
        hosts: ".",
        language: Language::Swift,
        story: "The public Rick and Morty API through Baton: characters, their details, episodes and locations share one store, so a character seen in a list, in an episode's cast and among a location's residents is one record. The store keeps an image on disk: quit and launch again, and the screens seen before are drawn from it before the network answers. The schema is small enough to read whole, which is why this site's GraphQL chapter uses it.",
        run: "swift run RickAndMorty",
    },
    Entry {
        id: "rick-and-morty-kotlin",
        title: "Rick and Morty, in Compose",
        path: "kotlin/samples/shared",
        config: Some("kotlin/samples/shared"),
        hosts: "src/commonMain/kotlin/baton/sample",
        language: Language::Kotlin,
        story: "The same screens as Compose Multiplatform, shared by a Compose for Desktop app (`kotlin/samples/desktop`, with an inspector pane over the store) and an Android app (`kotlin/samples/android`, which tells the environment the process's lifecycle). The Android app has an Apollo Kotlin twin, `kotlin/samples/apollo-android`, the same two screens over Apollo Kotlin, for a head-to-head over the same launch.",
        run: "gradle :samples:desktop:run",
    },
    Entry {
        id: "controllers",
        title: "UIKit and AppKit controllers",
        path: "examples/Controllers",
        config: Some("examples/Controllers"),
        hosts: ".",
        language: Language::Swift,
        story: "A `UIViewController` and an `NSViewController` holding the same handle a view does: the operations live in a `.graphql` file, the controller asks the environment for the handle, holds the retention, renders what it reads, and renders again when that changes. The recipe is [UIKit and AppKit](/recipes/uikit/).",
        run: "swift build --target Controllers",
    },
    Entry {
        id: "exchange",
        title: "The exchange",
        path: "examples/Exchange",
        config: None,
        hosts: ".",
        language: Language::Swift,
        story: "The few dozen lines a production endpoint needs and the library does not ship: a transport that wraps a transport, with one replay of a challenge, a bounded retry with backoff, a deadline across every attempt, and the rule that a mutation is never sent twice. The Kotlin twin is `kotlin/samples/exchange`. The recipe is [the exchange](/recipes/exchange/).",
        run: "",
    },
];

/// The site URL a path under the repository is published at, when it is a
/// sample.
pub fn url_for(repo_path: &str) -> Option<String> {
    let path = repo_path.trim_end_matches('/');
    ENTRIES
        .iter()
        .find(|entry| path == entry.path || path.starts_with(&format!("{}/", entry.path)))
        .map(|entry| format!("/examples/#{}", entry.id))
        .or_else(|| {
            matches!(
                path,
                "kotlin/samples/desktop"
                    | "kotlin/samples/android"
                    | "kotlin/samples/apollo-android"
            )
            .then(|| "/examples/#rick-and-morty-kotlin".to_string())
            .or_else(|| {
                (path == "kotlin/samples/exchange").then(|| "/examples/#exchange".to_string())
            })
        })
}

/// The gallery page.
pub fn render(context: &Context) -> Body {
    let root = &context.site.root;
    let mut source = String::new();
    source.push_str("<p class=\"section-intro\">Every sample is compiled in the repository's checks, and what each plate below lists was found by the compiler when this page was built: the operations each sample sends and the fragments its views declare. The sources are linked; read one screen whole before writing one.</p>\n\n");
    source.push_str("<div class=\"gallery-index\"><ol>");
    for entry in ENTRIES {
        source.push_str(&format!(
            "<li><a href=\"#{}\">{}</a> <span>{}</span></li>",
            entry.id,
            escape(entry.title),
            escape(entry.path)
        ));
    }
    source
        .push_str("<li><a href=\"#caton\">Caton</a> <span>the demo app</span></li></ol></div>\n\n");
    let mut plates = 0;
    for entry in ENTRIES {
        source.push_str(&format!("## {} {{#{}}}\n\n", entry.title, entry.id));
        source.push_str(&format!(
            "<p class=\"source-link\"><a href=\"{}/tree/master/{}\">{}</a></p>\n\n",
            crate::layout::REPO,
            entry.path,
            entry.path
        ));
        source.push_str(entry.story);
        source.push_str("\n\n");
        if !entry.run.is_empty() {
            source.push_str(&format!("```sh\n{}\n```\n\n", entry.run));
        }
        if let Some(config) = entry.config {
            plates += 1;
            let html = found_html(context, entry, root, config, plates);
            // The plate is HTML; a blank line inside would end the block.
            source.push_str(&html.replace("\n\n", "\n<!-- -->\n"));
            source.push_str("\n\n");
        }
    }
    source.push_str("## Caton {#caton}\n\n");
    source.push_str("[Caton](https://github.com/shergin/caton) is the demo app: a macOS menu bar inbox for GitHub notifications, built to show this framework in a real product. It joins each notification to the live state of its pull request or issue, and the number in the menu bar is the number of things waiting on you.\n");
    markdown::render(&source, context)
}

/// What the compiler found in a sample, as a plate.
fn found_html(
    context: &Context,
    entry: &Entry,
    root: &Path,
    config: &str,
    number: usize,
) -> String {
    let dir = root.join(config);
    let hosts_dir = dir.join(entry.hosts);
    let schemas = crate::compiler::schema_files(&dir);
    let mut hosts: Vec<String> = crate::compiler::file_names(&hosts_dir)
        .into_iter()
        .filter(|name| {
            name.ends_with(&format!(".{}", entry.language.extension()))
                || name.ends_with(".graphql")
        })
        .filter(|name| !schemas.contains(name))
        .filter(|name| !name.ends_with("Test.kt") && !name.ends_with("Tests.swift"))
        .map(|name| {
            if entry.hosts == "." {
                name
            } else {
                format!("{}/{name}", entry.hosts)
            }
        })
        .collect();
    hosts.sort();
    let compiled = context.figures.compiler().compile_hosts(
        &format!("gallery-{}", entry.id),
        &dir,
        &hosts,
        entry.language,
    );
    if !compiled.ok {
        panic!(
            "the sample {} does not compile:\n{}",
            entry.path, compiled.diagnostics
        );
    }
    let report = compiled.report.expect("a report");
    let mut inner = String::from(
        "<table class=\"found\"><thead><tr><th>operation</th><th>in</th><th>variables</th><th>spreads</th></tr></thead><tbody>",
    );
    for operation in report["operations"].as_array().into_iter().flatten() {
        let variables: Vec<String> = operation["variables"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|variable| {
                format!(
                    "${}: {}",
                    variable["name"].as_str().unwrap_or(""),
                    variable["type"].as_str().unwrap_or("")
                )
            })
            .collect();
        let fragments: Vec<String> = operation["fragments"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        inner.push_str(&format!(
            "<tr><td><span class=\"kind\">{}</span> <code>{}</code></td><td><a href=\"{}/blob/master/{}/{}\">{}</a></td><td>{}</td><td>{}</td></tr>",
            escape(operation["kind"].as_str().unwrap_or("")),
            escape(operation["name"].as_str().unwrap_or("")),
            crate::layout::REPO,
            config,
            escape(operation["source"].as_str().unwrap_or("")),
            escape(operation["source"].as_str().unwrap_or("").rsplit('/').next().unwrap_or("")),
            if variables.is_empty() { "<span class=\"muted\">none</span>".to_string() } else { format!("<code>{}</code>", escape(&variables.join(", "))) },
            if fragments.is_empty() { "<span class=\"muted\">none</span>".to_string() } else { fragments.iter().map(|f| format!("<code>{}</code>", escape(f))).collect::<Vec<_>>().join(" ") }
        ));
    }
    inner.push_str("</tbody></table>");
    inner.push_str("<table class=\"found\"><thead><tr><th>fragment</th><th>on</th><th>in</th><th>spread by</th></tr></thead><tbody>");
    for fragment in report["fragments"].as_array().into_iter().flatten() {
        let operations: Vec<String> = fragment["operations"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        inner.push_str(&format!(
            "<tr><td><code>{}</code></td><td><code>{}</code></td><td><a href=\"{}/blob/master/{}/{}\">{}</a></td><td>{}</td></tr>",
            escape(fragment["name"].as_str().unwrap_or("")),
            escape(fragment["type"].as_str().unwrap_or("")),
            crate::layout::REPO,
            config,
            escape(fragment["source"].as_str().unwrap_or("")),
            escape(fragment["source"].as_str().unwrap_or("").rsplit('/').next().unwrap_or("")),
            if operations.is_empty() { "<span class=\"muted\">no operation yet</span>".to_string() } else { operations.iter().map(|o| format!("<code>{}</code>", escape(o))).collect::<Vec<_>>().join(" ") }
        ));
    }
    inner.push_str("</tbody></table>");
    let operations = report["operations"].as_array().map_or(0, Vec::len);
    let fragments = report["fragments"].as_array().map_or(0, Vec::len);
    plate(
        number,
        &inner,
        &format!(
            "What the compiler found in `{}` when this page was built: {operations} operations and {fragments} fragments, against the schema its `baton.json` names.",
            entry.path
        ),
        "found-plate",
    )
}
