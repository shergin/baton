//! The generator behind <https://shergin.github.io/baton/>.
//!
//! One rule from the repository applies here too: no generated code,
//! operation text, diagnostic or store on the site is typed by hand. The
//! figures under `site/figures/` are compiled by `batonc` when a page asks
//! for one, and shown with the code the compiler wrote; the stores are the
//! dumps the runtime wrote under `spec/`.
//!
//! ```sh
//! cargo run --manifest-path site/Cargo.toml   # writes site/dist
//! ./site/build.sh                              # the same, plus the wasm the playground uses
//! ```

mod compiler;
mod escape;
mod figures;
mod gallery;
mod highlight;
mod layout;
mod markdown;
mod pages;
mod stage;
mod store;

use std::fs;
use std::path::{Path, PathBuf};

use pages::{Page, Section, Source};

/// Everything a page needs to know about where it lives.
pub struct Site {
    /// The repository root.
    pub root: PathBuf,
    /// The output directory.
    pub out: PathBuf,
    /// The latest release, from the compiler's manifest.
    pub version: String,
    /// The navigation.
    pub sections: Vec<Section>,
}

/// One entry in the client-side search index.
#[derive(serde::Serialize)]
struct SearchEntry {
    url: String,
    title: String,
    section: String,
    headings: Vec<String>,
    text: String,
}

fn main() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let root = manifest
        .parent()
        .expect("site sits inside the repository")
        .to_path_buf();
    let mut out = manifest.join("dist");
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--out" => out = PathBuf::from(arguments.next().expect("--out takes a directory")),
            other => panic!("unknown argument {other}"),
        }
    }
    let site = Site {
        version: manifest_version(&root.join("compiler/Cargo.toml")),
        sections: pages::sections(&root),
        root,
        out,
    };

    prepare(&site.out);
    copy_dir(&site.root.join("site/static"), &site.out);
    fs::copy(site.root.join("baton.png"), site.out.join("baton.png")).expect("copy the logo");
    let figures = figures::Registry::new(&site.root, &manifest.join("target/work"));
    let mut index = Vec::new();
    let mut written = 0;
    for section in &site.sections {
        for page in &section.pages {
            let rendered = render_page(&site, &figures, &section.title, page, section);
            write(&site.out.join(page.path()), &rendered.html);
            written += 1;
            if page.searchable() {
                index.push(SearchEntry {
                    url: page.url.clone(),
                    title: page.title.clone(),
                    section: section.title.clone(),
                    headings: rendered.headings,
                    text: rendered.summary,
                });
            }
        }
    }
    // A contact sheet of every figure, for proofing: SITE_CONTACT_SHEET=1.
    if std::env::var_os("SITE_CONTACT_SHEET").is_some() {
        let page = Page {
            url: "/contact/".to_string(),
            title: "Every figure".to_string(),
            blurb: "The contact sheet.".to_string(),
            source: Source::Content("contact.md".to_string()),
            listed: false,
        };
        let mut source = String::new();
        for name in figures.names() {
            source.push_str(&format!(
                "## {name}\n\n{{{{host {name}}}}}\n\n{{{{diagnostics {name}}}}}\n\n"
            ));
        }
        let context = markdown::Context {
            site: &site,
            figures: &figures,
            page: &page,
            source_dir: String::new(),
        };
        let body = markdown::render(&source, &context);
        write(
            &site.out.join("contact/index.html"),
            &layout::page(&site, "Proofing", &page, &body),
        );
    }
    let index = serde_json::to_string(&index).expect("search index serializes");
    write(&site.out.join("search.json"), &index);
    write(&site.out.join(".nojekyll"), "");
    println!(
        "wrote {written} pages and {} plates to {}",
        figures.rendered(),
        site.out.display()
    );
}

/// A rendered page plus what the search index keeps of it.
struct RenderedPage {
    html: String,
    headings: Vec<String>,
    summary: String,
}

fn render_page(
    site: &Site,
    figures: &figures::Registry,
    section: &str,
    page: &Page,
    group: &Section,
) -> RenderedPage {
    let context = markdown::Context {
        site,
        figures,
        page,
        source_dir: page.source_dir(),
    };
    let body = match &page.source {
        Source::Content(path) => {
            markdown::render(&read(&site.root.join("site/content").join(path)), &context)
        }
        Source::Repo(path) => markdown::render(&read(&site.root.join(path)), &context),
        Source::RepoWith(path, inserts) => {
            markdown::render(&illustrate(&read(&site.root.join(path)), inserts), &context)
        }
        Source::Home => markdown::render(&read(&site.root.join("site/content/home.md")), &context),
        Source::Index => markdown::render(&index_source(group, page), &context),
        Source::Gallery => gallery::render(&context),
        Source::Playground => {
            let mut body = markdown::render(
                &read(&site.root.join("site/content/playground.md")),
                &context,
            );
            if !body.scripts.iter().any(|script| script == "playground.js") {
                body.scripts.push("playground.js".to_string());
            }
            body
        }
    };
    let html = layout::page(site, section, page, &body);
    RenderedPage {
        html,
        headings: body
            .headings
            .iter()
            .map(|heading| heading.text.clone())
            .collect(),
        summary: body.summary,
    }
}

/// A section's index: its other pages, with their blurbs, as markdown.
fn index_source(section: &Section, index: &Page) -> String {
    let mut out = String::new();
    // A decisions index keeps the repository's README as its text.
    if index.url == "/decisions/" {
        out.push_str("<p class=\"section-intro\">Choices made among real alternatives, with the evidence that decided them and the condition that would reopen them. These are not principles: a principle must not rot, a decision may be superseded, and says so in its status line. Each record has the same shape: a status line, then Context, Decision, Evidence, Not chosen.</p>\n\n");
    }
    out.push_str("<ul class=\"index\">\n");
    for page in &section.pages {
        if page.url == index.url {
            continue;
        }
        // The decisions follow their own index; the vision and the
        // principles have their own entries in the sidebar.
        if index.url == "/decisions/" && !page.url.starts_with("/decisions/") {
            continue;
        }
        if index.url != "/decisions/" && !page.listed {
            continue;
        }
        out.push_str(&format!(
            "<li><a href=\"{}\">{}</a><span>{}</span></li>\n",
            page.url,
            escape::escape(&page.title),
            escape::inline_markdown(&page.blurb)
        ));
    }
    out.push_str("</ul>\n");
    out
}

/// Inserts site material after the named headings of a repository
/// document. A heading that does not exist fails the build: the insert
/// would vanish silently.
fn illustrate(source: &str, inserts: &[(String, String)]) -> String {
    let mut out = String::with_capacity(source.len() + 1024);
    let mut pending: Vec<&(String, String)> = inserts.iter().collect();
    for line in source.lines() {
        out.push_str(line);
        out.push('\n');
        if let Some(index) = pending
            .iter()
            .position(|(heading, _)| heading == line.trim_end())
        {
            let (_, material) = pending.remove(index);
            out.push('\n');
            out.push_str(material);
            out.push('\n');
        }
    }
    assert!(
        pending.is_empty(),
        "headings not found for inserts: {:?}",
        pending.iter().map(|(h, _)| h).collect::<Vec<_>>()
    );
    out
}

fn prepare(out: &Path) {
    // Keep `wasm/`: build.sh fills it after this generator runs, and a
    // local iteration should not have to rebuild it. Replace the rest.
    if out.exists() {
        for entry in fs::read_dir(out).expect("output directory") {
            let entry = entry.expect("directory entry");
            if entry.file_name() == "wasm" {
                continue;
            }
            let path = entry.path();
            if path.is_dir() {
                fs::remove_dir_all(&path).expect("remove stale directory");
            } else {
                fs::remove_file(&path).expect("remove stale file");
            }
        }
    }
    fs::create_dir_all(out).expect("create output directory");
}

fn copy_dir(from: &Path, to: &Path) {
    for entry in fs::read_dir(from).unwrap_or_else(|error| panic!("{}: {error}", from.display())) {
        let entry = entry.expect("directory entry");
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            fs::create_dir_all(&target).expect("create directory");
            copy_dir(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).expect("copy static file");
        }
    }
}

pub fn read(path: &Path) -> String {
    compiler::read(path)
}

fn write(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create page directory");
    }
    fs::write(path, content).unwrap_or_else(|error| panic!("writing {}: {error}", path.display()));
}

fn manifest_version(path: &Path) -> String {
    read(path)
        .lines()
        .find_map(|line| {
            line.strip_prefix("version = \"")
                .and_then(|rest| rest.strip_suffix('"'))
        })
        .expect("the compiler's manifest has a version")
        .to_string()
}
