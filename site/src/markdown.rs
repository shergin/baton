//! Markdown to HTML for the site: pulldown-cmark plus the site's own
//! rules. Links into the repository become links into the site; code
//! fences are highlighted, and consecutive fences tagged `tab` become one
//! block of tabs, SwiftUI beside Compose; `text` fences become terminal
//! plates; headings get anchors; a `{{directive}}` on a line of its own
//! becomes a plate the figures render; a terminology entry gets an id.

use std::cell::Cell;
use std::fs;

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::Site;
use crate::escape::escape;
use crate::figures::Registry;
use crate::highlight::{highlight, label};
use crate::layout::REPO;
use crate::pages::{self, Page};

/// What a page body needs to know while it renders.
pub struct Context<'a> {
    pub site: &'a Site,
    pub figures: &'a Registry,
    pub page: &'a Page,
    /// The repository directory relative links resolve against.
    pub source_dir: String,
}

impl Context<'_> {
    /// The relative prefix that reaches the site root from this page.
    pub fn root(&self) -> String {
        self.page.root()
    }

    /// A site-internal href for a site-absolute URL.
    pub fn href(&self, url: &str) -> String {
        format!("{}{}", self.root(), url.trim_start_matches('/'))
    }
}

/// A heading in a rendered body, for the table of contents.
pub struct Heading {
    pub level: u8,
    pub id: String,
    pub text: String,
}

/// A rendered body.
pub struct Body {
    pub html: String,
    pub headings: Vec<Heading>,
    /// Plain text, for the search index.
    pub summary: String,
    /// Page scripts the body asked for, as paths relative to the site root.
    pub scripts: Vec<String>,
}

/// Renders a markdown source into a body.
pub fn render(source: &str, context: &Context) -> Body {
    let plates = Cell::new(0);
    let mut scripts = Vec::new();
    let expanded = expand_directives(source, context, &plates, &mut scripts);
    let mut body = render_markdown(&expanded, context);
    body.scripts.append(&mut scripts);
    body
}

/// A fenced block that may join a tab group.
struct Fence {
    language: String,
    tab: Option<String>,
    code: String,
}

fn render_markdown(source: &str, context: &Context) -> Body {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    let mut parser = Parser::new_ext(source, options);
    let mut events: Vec<Event> = Vec::new();
    let mut headings = Vec::new();
    let mut used = Vec::new();
    let mut text = String::new();
    let mut dropped_title = false;
    let mut tabs: Vec<Fence> = Vec::new();
    let flush_tabs = |tabs: &mut Vec<Fence>, events: &mut Vec<Event>| {
        if tabs.is_empty() {
            return;
        }
        let html = if tabs.len() == 1 {
            let fence = &tabs[0];
            code_block(&fence.language, &fence.code)
        } else {
            tab_block(tabs)
        };
        events.push(Event::Html(html.into()));
        tabs.clear();
    };
    while let Some(event) = parser.next() {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                let info = match kind {
                    CodeBlockKind::Fenced(info) => info.to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                let mut code = String::new();
                for event in parser.by_ref() {
                    match event {
                        Event::End(TagEnd::CodeBlock) => break,
                        Event::Text(t) => code.push_str(&t),
                        _ => {}
                    }
                }
                let mut words = info.split_whitespace();
                let language = words.next().unwrap_or("").to_string();
                let rest: Vec<&str> = words.collect();
                let tab = rest.iter().find_map(|word| {
                    word.strip_prefix("tab=")
                        .map(str::to_string)
                        .or_else(|| (*word == "tab").then(|| tab_label(&language)))
                });
                if tab.is_some() {
                    tabs.push(Fence {
                        language,
                        tab,
                        code,
                    });
                    continue;
                }
                flush_tabs(&mut tabs, &mut events);
                events.push(Event::Html(code_block(&language, &code).into()));
                continue;
            }
            _ => flush_tabs(&mut tabs, &mut events),
        }
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                let mut inner = Vec::new();
                let mut label = String::new();
                for event in parser.by_ref() {
                    match event {
                        Event::End(TagEnd::Heading(_)) => break,
                        Event::Text(ref t) | Event::Code(ref t) => {
                            label.push_str(t);
                            inner.push(event);
                        }
                        other => inner.push(other),
                    }
                }
                // The first h1 is the page title; the layout prints it.
                if level == HeadingLevel::H1 && !dropped_title {
                    dropped_title = true;
                    continue;
                }
                // `## Title {#id}` names its own anchor, as the gallery does.
                let (label, id) = match label.rsplit_once(" {#") {
                    Some((text, rest)) if rest.ends_with('}') => {
                        let id = rest.trim_end_matches('}').to_string();
                        used.push(id.clone());
                        // The suffix is in the last text event; trim it there.
                        if let Some(Event::Text(last)) = inner.last_mut() {
                            let trimmed = last
                                .rsplit_once(" {#")
                                .map(|(t, _)| t.to_string())
                                .unwrap_or_default();
                            *last = trimmed.into();
                        }
                        (text.to_string(), id)
                    }
                    _ => {
                        let id = slug(&label, &mut used);
                        (label, id)
                    }
                };
                let n = level as u8;
                events.push(Event::Html(format!("<h{n} id=\"{id}\">").into()));
                events.extend(inner);
                events.push(Event::Html(
                    format!("<a class=\"anchor\" href=\"#{id}\" aria-label=\"Link to this section\">#</a></h{n}>\n")
                        .into(),
                ));
                headings.push(Heading {
                    level: n,
                    id,
                    text: label,
                });
            }
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest = rewrite_link(&dest_url, context);
                events.push(Event::Start(Tag::Link {
                    link_type,
                    dest_url: dest.into(),
                    title,
                    id,
                }));
            }
            Event::Start(Tag::Image {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest = rewrite_image(&dest_url, context);
                events.push(Event::Start(Tag::Image {
                    link_type,
                    dest_url: dest.into(),
                    title,
                    id,
                }));
            }
            Event::Html(ref html) | Event::InlineHtml(ref html) => {
                let rewritten = rewrite_raw_html(html, context);
                events.push(match event {
                    Event::Html(_) => Event::Html(rewritten.into()),
                    _ => Event::InlineHtml(rewritten.into()),
                });
            }
            Event::Text(ref t) => {
                text.push_str(t);
                text.push(' ');
                events.push(event);
            }
            other => events.push(other),
        }
    }
    flush_tabs(&mut tabs, &mut events);
    let mut html = String::with_capacity(source.len() * 2);
    pulldown_cmark::html::push_html(&mut html, events.into_iter());
    let html = entry_ids(&html, &mut used);
    let summary: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let summary = summary.chars().take(1500).collect();
    Body {
        html,
        headings,
        summary,
        scripts: Vec::new(),
    }
}

/// A terminology entry, `<p><strong>Lens.</strong> …`, gets an id so a
/// page can link to the word.
fn entry_ids(html: &str, used: &mut Vec<String>) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(at) = rest.find("<p><strong>") {
        out.push_str(&rest[..at]);
        let after = &rest[at + "<p><strong>".len()..];
        match after.find("</strong>") {
            Some(end) if after[..end].ends_with('.') && !after[..end].contains('<') => {
                let term = &after[..end - 1];
                let id = slug(
                    &format!("term {}", term.split(',').next().unwrap_or(term)),
                    used,
                );
                out.push_str(&format!("<p class=\"entry\" id=\"{id}\"><strong>"));
                rest = after;
            }
            _ => {
                out.push_str("<p><strong>");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// GitHub's heading slug: lowercase, spaces to hyphens, punctuation dropped.
pub fn slug(text: &str, used: &mut Vec<String>) -> String {
    let mut base = String::new();
    for c in text.chars() {
        if c.is_alphanumeric() {
            base.extend(c.to_lowercase());
        } else if c == ' ' || c == '-' {
            base.push('-');
        }
    }
    let base = base.trim_matches('-').to_string();
    let base = if base.is_empty() {
        "section".to_string()
    } else {
        base
    };
    let mut candidate = base.clone();
    let mut n = 1;
    while used.contains(&candidate) {
        n += 1;
        candidate = format!("{base}-{n}");
    }
    used.push(candidate.clone());
    candidate
}

/// The tab label a fence language stands for.
fn tab_label(language: &str) -> String {
    match language {
        "swift" => "SwiftUI".to_string(),
        "kotlin" | "kt" => "Compose".to_string(),
        other => label(other).to_string(),
    }
}

/// A fenced block: a terminal plate for `text`, highlighted code otherwise.
pub fn code_block(language: &str, code: &str) -> String {
    let code = code.trim_end_matches('\n');
    let language = language.split_whitespace().next().unwrap_or("");
    if language == "text" || language == "plate" {
        return format!(
            "<figure class=\"plate\"><pre class=\"term\">{}</pre></figure>\n",
            escape(code)
        );
    }
    format!(
        "<div class=\"code\" data-lang=\"{}\"><pre><code>{}</code></pre></div>\n",
        label(language),
        highlight(language, code)
    )
}

/// Consecutive fences tagged `tab`, as one block of tabs. A Swift tab and
/// a Kotlin tab are a language group: choosing one chooses it on the
/// whole page.
fn tab_block(fences: &[Fence]) -> String {
    let group = if fences
        .iter()
        .all(|fence| matches!(fence.language.as_str(), "swift" | "kotlin" | "kt"))
    {
        " data-group=\"language\""
    } else {
        ""
    };
    let mut tabs = format!("<div class=\"panels\"{group}><div class=\"tabs\" role=\"tablist\">");
    let mut panels = String::new();
    for (index, fence) in fences.iter().enumerate() {
        let selected = index == 0;
        let key = match fence.language.as_str() {
            "swift" => "swift".to_string(),
            "kotlin" | "kt" => "kotlin".to_string(),
            _ => index.to_string(),
        };
        tabs.push_str(&format!(
            "<button type=\"button\" role=\"tab\" aria-selected=\"{selected}\" data-panel=\"{key}\" class=\"lang-{key}\">{}</button>",
            escape(fence.tab.as_deref().unwrap_or(""))
        ));
        panels.push_str(&format!(
            "<div class=\"panel\" role=\"tabpanel\" data-panel=\"{key}\"{}>{}</div>",
            if selected { "" } else { " hidden" },
            code_block(&fence.language, &fence.code)
        ));
    }
    tabs.push_str("</div>");
    format!("{tabs}{panels}</div>\n")
}

/// Joins a relative path onto a directory and normalizes `.` and `..`.
pub fn resolve(dir: &str, relative: &str) -> String {
    let mut parts: Vec<&str> = dir.split('/').filter(|part| !part.is_empty()).collect();
    for part in relative.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    parts.join("/")
}

/// Rewrites a link destination from a markdown source into a site or
/// GitHub URL.
pub fn rewrite_link(dest: &str, context: &Context) -> String {
    if dest.starts_with("http://")
        || dest.starts_with("https://")
        || dest.starts_with("mailto:")
        || dest.starts_with('#')
    {
        return dest.to_string();
    }
    if let Some(site_path) = dest.strip_prefix('/') {
        return format!("{}{site_path}", context.root());
    }
    let (path, fragment) = match dest.split_once('#') {
        Some((path, fragment)) => (path, Some(fragment)),
        None => (dest, None),
    };
    let repo_path = resolve(&context.source_dir, path);
    // The README's sections are not the front page's; a link into one goes
    // to the README on GitHub.
    if repo_path == "README.md" && fragment.is_some() {
        return format!("{REPO}#{}", fragment.unwrap_or_default());
    }
    let fragment = fragment.map(|f| format!("#{f}")).unwrap_or_default();
    if let Some(url) = pages::url_for(&context.site.sections, &repo_path) {
        if url.contains('#') {
            return context.href(&url);
        }
        return format!("{}{fragment}", context.href(&url));
    }
    let on_disk = context.site.root.join(&repo_path);
    if on_disk.is_dir() {
        return format!("{REPO}/tree/master/{repo_path}");
    }
    if on_disk.exists() {
        return format!("{REPO}/blob/master/{repo_path}{fragment}");
    }
    dest.to_string()
}

/// Copies a repository image into the site and returns its URL.
fn rewrite_image(dest: &str, context: &Context) -> String {
    if dest.starts_with("http://") || dest.starts_with("https://") {
        return dest.to_string();
    }
    let repo_path = resolve(&context.source_dir, dest);
    let from = context.site.root.join(&repo_path);
    if !from.exists() {
        return dest.to_string();
    }
    let to = context.site.out.join("assets").join(&repo_path);
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent).expect("asset directory");
    }
    fs::copy(&from, &to).unwrap_or_else(|error| panic!("copying {}: {error}", from.display()));
    format!("{}assets/{repo_path}", context.root())
}

/// Raw HTML in a repository document, a `<picture>` with its `srcset`s,
/// with its relative sources copied into the site.
fn rewrite_raw_html(html: &str, context: &Context) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    loop {
        let next = ["src=\"", "srcset=\"", "href=\""]
            .iter()
            .filter_map(|needle| rest.find(needle).map(|at| (at, *needle)))
            .min_by_key(|(at, _)| *at);
        let Some((at, needle)) = next else {
            out.push_str(rest);
            return out;
        };
        let value_start = at + needle.len();
        let Some(length) = rest[value_start..].find('"') else {
            out.push_str(rest);
            return out;
        };
        let value = &rest[value_start..value_start + length];
        out.push_str(&rest[..value_start]);
        let rewritten = if needle == "href=\"" {
            rewrite_link(value, context)
        } else {
            rewrite_image(value, context)
        };
        out.push_str(&rewritten);
        rest = &rest[value_start + length..];
    }
}

/// Replaces every `{{kind arguments}}` line with the HTML the figure
/// registry produces for it. Unknown directives fail the build: a page
/// that names a plate that does not exist is a broken page.
fn expand_directives(
    source: &str,
    context: &Context,
    plates: &Cell<usize>,
    scripts: &mut Vec<String>,
) -> String {
    let mut out = String::with_capacity(source.len());
    let mut in_fence = false;
    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
        }
        if !in_fence && trimmed.starts_with("{{") && trimmed.ends_with("}}") {
            let inner = trimmed[2..trimmed.len() - 2].trim();
            let (directive, caption) = match inner.split_once('|') {
                Some((directive, caption)) => (directive.trim(), Some(caption.trim())),
                None => (inner, None),
            };
            let mut words = directive.split_whitespace();
            let kind = words.next().unwrap_or("");
            let arguments: Vec<&str> = words.collect();
            let mut html = context
                .figures
                .directive(kind, &arguments, caption, context, plates, scripts)
                .unwrap_or_else(|error| panic!("{}: {{{{{inner}}}}}: {error}", context.page.url));
            // A blank line would end the markdown HTML block and hand the
            // rest of the plate to the paragraph parser; an empty comment
            // keeps a blank line of program output blank on the page.
            while html.contains("\n\n") {
                html = html.replace("\n\n", "\n<!-- -->\n");
            }
            out.push('\n');
            out.push_str(&html);
            out.push('\n');
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}
