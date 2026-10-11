//! A small syntax highlighter for the languages the site quotes: Swift,
//! Kotlin, GraphQL, JSON, shell, Rust and Starlark. Tokens become
//! `<span>`s with one-letter classes; anything unrecognized passes through
//! escaped. A GraphQL document carried by a marker in Swift or Kotlin, the
//! string after `@Fragment(`, `@Query(`, `@Mutation(` or `@Subscription(`,
//! is highlighted as GraphQL inside the string, since that is what a reader
//! looks at first.

use crate::escape::escape;

/// Highlights `code` written in `language` (a fence tag) as HTML.
pub fn highlight(language: &str, code: &str) -> String {
    match language {
        "swift" => host(code, Host::Swift),
        "kotlin" | "kt" => host(code, Host::Kotlin),
        "graphql" | "gql" => graphql(code),
        "json" => json(code),
        "sh" | "bash" | "shell" | "zsh" | "console" => shell(code),
        "rust" | "rs" => rust(code),
        "starlark" | "bzl" | "python" | "py" => starlark(code),
        _ => escape(code),
    }
}

/// The label a fence tag is shown under.
pub fn label(language: &str) -> &'static str {
    match language {
        "swift" => "Swift",
        "kotlin" | "kt" => "Kotlin",
        "graphql" | "gql" => "GraphQL",
        "json" => "JSON",
        "sh" | "bash" | "shell" | "zsh" | "console" => "shell",
        "rust" | "rs" => "Rust",
        "starlark" | "bzl" => "Starlark",
        "python" | "py" => "Python",
        "toml" => "TOML",
        "properties" => "properties",
        "diff" => "diff",
        "text" | "" => "",
        _ => "",
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Host {
    Swift,
    Kotlin,
}

const SWIFT_KEYWORDS: &[&str] = &[
    "actor",
    "as",
    "assert",
    "associatedtype",
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "continue",
    "default",
    "defer",
    "deinit",
    "do",
    "else",
    "enum",
    "extension",
    "fallthrough",
    "false",
    "fileprivate",
    "final",
    "for",
    "func",
    "guard",
    "if",
    "import",
    "in",
    "init",
    "inout",
    "internal",
    "is",
    "lazy",
    "let",
    "mutating",
    "nil",
    "nonisolated",
    "open",
    "operator",
    "override",
    "private",
    "protocol",
    "public",
    "repeat",
    "rethrows",
    "return",
    "self",
    "Self",
    "some",
    "static",
    "struct",
    "subscript",
    "super",
    "switch",
    "throw",
    "throws",
    "true",
    "try",
    "typealias",
    "var",
    "weak",
    "where",
    "while",
];

const KOTLIN_KEYWORDS: &[&str] = &[
    "abstract",
    "as",
    "break",
    "by",
    "catch",
    "class",
    "companion",
    "const",
    "constructor",
    "continue",
    "data",
    "do",
    "else",
    "enum",
    "false",
    "final",
    "finally",
    "for",
    "fun",
    "get",
    "if",
    "import",
    "in",
    "infix",
    "inline",
    "interface",
    "internal",
    "is",
    "it",
    "lateinit",
    "null",
    "object",
    "open",
    "operator",
    "override",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "sealed",
    "set",
    "super",
    "suspend",
    "this",
    "throw",
    "true",
    "try",
    "typealias",
    "val",
    "var",
    "when",
    "where",
    "while",
];

const RUST_KEYWORDS: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
    "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
    "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type",
    "unsafe", "use", "where", "while",
];

const STARLARK_KEYWORDS: &[&str] = &[
    "and", "def", "elif", "else", "for", "if", "in", "load", "not", "or", "pass", "return", "True",
    "False", "None", "import", "from",
];

const GRAPHQL_KEYWORDS: &[&str] = &[
    "query",
    "mutation",
    "subscription",
    "fragment",
    "on",
    "type",
    "interface",
    "union",
    "enum",
    "input",
    "scalar",
    "schema",
    "extend",
    "directive",
    "implements",
    "true",
    "false",
    "null",
];

const MARKERS: &[&str] = &["Fragment", "Query", "Mutation", "Subscription"];

fn span(out: &mut String, class: &str, text: &str) {
    out.push_str("<span class=\"");
    out.push_str(class);
    out.push_str("\">");
    out.push_str(&escape(text));
    out.push_str("</span>");
}

fn is_ident_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Reads a string literal starting at `start` (which holds the quote),
/// with backslash escapes, and returns the index one past its close.
fn string_end(chars: &[char], start: usize, quote: char) -> usize {
    let mut i = start + 1;
    while i < chars.len() {
        if chars[i] == '\\' {
            i += 2;
            continue;
        }
        if chars[i] == quote {
            return i + 1;
        }
        i += 1;
    }
    chars.len()
}

/// The index one past a `"""` string's closing quotes, from its opening ones.
fn triple_end(chars: &[char], start: usize) -> usize {
    let mut i = start + 3;
    while i + 2 < chars.len() {
        if chars[i] == '"' && chars[i + 1] == '"' && chars[i + 2] == '"' {
            return i + 3;
        }
        i += 1;
    }
    chars.len()
}

fn number_end(chars: &[char], start: usize) -> usize {
    let mut i = start;
    while i < chars.len()
        && (chars[i].is_ascii_alphanumeric()
            || chars[i] == '_'
            || chars[i] == '.' && i + 1 < chars.len() && chars[i + 1].is_ascii_digit())
    {
        i += 1;
    }
    i
}

fn collect(chars: &[char]) -> String {
    chars.iter().collect()
}

/// Swift and Kotlin: the host languages, with the GraphQL inside a marker's
/// string highlighted as GraphQL.
fn host(code: &str, language: Host) -> String {
    let keywords = match language {
        Host::Swift => SWIFT_KEYWORDS,
        Host::Kotlin => KOTLIN_KEYWORDS,
    };
    let chars: Vec<char> = code.chars().collect();
    let mut out = String::with_capacity(code.len() * 2);
    let mut i = 0;
    // Whether the next string literal is a marker's document.
    let mut document_next = false;
    while i < chars.len() {
        let c = chars[i];
        if c == '/' && chars.get(i + 1) == Some(&'/') {
            let end = chars[i..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(chars.len(), |n| i + n);
            span(&mut out, "c", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '/' && chars.get(i + 1) == Some(&'*') {
            let end = (i + 2..chars.len())
                .find(|&n| chars[n] == '*' && chars.get(n + 1) == Some(&'/'))
                .map_or(chars.len(), |n| n + 2);
            span(&mut out, "c", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        // Kotlin's `$$"""` raw string with a dollar prefix.
        if c == '$' && language == Host::Kotlin {
            let mut end = i;
            while end < chars.len() && chars[end] == '$' {
                end += 1;
            }
            if chars.get(end) == Some(&'"') {
                span(&mut out, "s", &collect(&chars[i..end]));
                i = end;
                continue;
            }
        }
        if c == '"' {
            let triple = chars.get(i + 1) == Some(&'"') && chars.get(i + 2) == Some(&'"');
            let end = if triple {
                triple_end(&chars, i)
            } else {
                string_end(&chars, i, '"')
            };
            let quote = if triple { 3 } else { 1 };
            let close = end.saturating_sub(quote).max(i + quote);
            if document_next {
                span(&mut out, "s", &collect(&chars[i..i + quote]));
                out.push_str("<span class=\"gql\">");
                out.push_str(&graphql(&collect(&chars[i + quote..close])));
                out.push_str("</span>");
                span(&mut out, "s", &collect(&chars[close..end]));
                document_next = false;
            } else {
                span(&mut out, "s", &collect(&chars[i..end]));
            }
            i = end;
            continue;
        }
        if c == '@' {
            let mut end = i + 1;
            while end < chars.len() && (is_ident(chars[end]) || chars[end] == '.') {
                end += 1;
            }
            let word = collect(&chars[i + 1..end]);
            let bare = word.rsplit('.').next().unwrap_or("");
            if MARKERS.contains(&bare) {
                span(&mut out, "m", &collect(&chars[i..end]));
                document_next = true;
            } else {
                span(&mut out, "a", &collect(&chars[i..end]));
            }
            i = end;
            continue;
        }
        if c.is_ascii_digit() {
            let end = number_end(&chars, i);
            span(&mut out, "n", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if is_ident_start(c) {
            let mut end = i + 1;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            let word = collect(&chars[i..end]);
            if keywords.contains(&word.as_str()) {
                span(&mut out, "k", &word);
            } else if word.chars().next().is_some_and(char::is_uppercase) {
                span(&mut out, "t", &word);
            } else if chars.get(end) == Some(&'(') {
                span(&mut out, "f", &word);
            } else {
                out.push_str(&escape(&word));
            }
            i = end;
            continue;
        }
        out.push_str(&escape(&c.to_string()));
        i += 1;
    }
    out
}

/// GraphQL: keywords, names, fields, directives, variables, strings.
pub fn graphql(code: &str) -> String {
    let chars: Vec<char> = code.chars().collect();
    let mut out = String::with_capacity(code.len() * 2);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '#' {
            let end = chars[i..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(chars.len(), |n| i + n);
            span(&mut out, "c", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '"' {
            let triple = chars.get(i + 1) == Some(&'"') && chars.get(i + 2) == Some(&'"');
            let end = if triple {
                triple_end(&chars, i)
            } else {
                string_end(&chars, i, '"')
            };
            span(&mut out, "s", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '$' {
            let mut end = i + 1;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            span(&mut out, "v", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '@' {
            let mut end = i + 1;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            span(&mut out, "d", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '.' && chars.get(i + 1) == Some(&'.') && chars.get(i + 2) == Some(&'.') {
            let mut end = i + 3;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            span(&mut out, "p", "...");
            span(&mut out, "r", &collect(&chars[i + 3..end]));
            i = end;
            continue;
        }
        if c.is_ascii_digit() || (c == '-' && chars.get(i + 1).is_some_and(char::is_ascii_digit)) {
            let end = number_end(&chars, i + 1).max(i + 1);
            span(&mut out, "n", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if is_ident_start(c) {
            let mut end = i + 1;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            let word = collect(&chars[i..end]);
            // The word after `fragment`, `query`, `on`, `type`: a name.
            let mut after = end;
            while after < chars.len() && chars[after] == ' ' {
                after += 1;
            }
            let follows_colon = {
                let mut n = end;
                while n < chars.len() && chars[n] == ' ' {
                    n += 1;
                }
                chars.get(n) == Some(&':')
            };
            if GRAPHQL_KEYWORDS.contains(&word.as_str()) && !follows_colon {
                span(&mut out, "k", &word);
            } else if word.chars().next().is_some_and(char::is_uppercase) {
                span(&mut out, "t", &word);
            } else if follows_colon {
                span(&mut out, "a", &word);
            } else {
                span(&mut out, "f", &word);
            }
            i = end;
            continue;
        }
        out.push_str(&escape(&c.to_string()));
        i += 1;
    }
    out
}

fn json(code: &str) -> String {
    let chars: Vec<char> = code.chars().collect();
    let mut out = String::with_capacity(code.len() * 2);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '"' {
            let end = string_end(&chars, i, '"');
            let text = collect(&chars[i..end]);
            let rest = chars[end..]
                .iter()
                .take_while(|c| c.is_whitespace())
                .count();
            let is_key = chars.get(end + rest) == Some(&':');
            span(&mut out, if is_key { "a" } else { "s" }, &text);
            i = end;
            continue;
        }
        if c.is_ascii_digit() || c == '-' {
            let end = number_end(&chars, i + 1).max(i + 1);
            span(&mut out, "n", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c.is_alphabetic() {
            let mut end = i;
            while end < chars.len() && chars[end].is_alphabetic() {
                end += 1;
            }
            span(&mut out, "k", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        out.push_str(&escape(&c.to_string()));
        i += 1;
    }
    out
}

fn shell(code: &str) -> String {
    let mut out = String::with_capacity(code.len() * 2);
    for (index, line) in code.split('\n').enumerate() {
        if index > 0 {
            out.push('\n');
        }
        let trimmed = line.trim_start();
        let indent = &line[..line.len() - trimmed.len()];
        out.push_str(indent);
        if trimmed.starts_with('#') {
            span(&mut out, "c", trimmed);
            continue;
        }
        let mut command_next = true;
        let mut token = String::new();
        let chars: Vec<char> = trimmed.chars().collect();
        let mut i = 0;
        let flush = |out: &mut String, token: &mut String, command_next: &mut bool| {
            if token.is_empty() {
                return;
            }
            if token.contains('=') && *command_next {
                span(out, "a", token);
            } else if *command_next {
                span(out, "f", token);
                *command_next = false;
            } else if token.starts_with('-') {
                span(out, "a", token);
            } else if token.starts_with('$') {
                span(out, "v", token);
            } else {
                out.push_str(&escape(token));
            }
            token.clear();
        };
        while i < chars.len() {
            let c = chars[i];
            match c {
                '"' | '\'' => {
                    flush(&mut out, &mut token, &mut command_next);
                    let end = string_end(&chars, i, c);
                    span(&mut out, "s", &collect(&chars[i..end]));
                    i = end;
                    continue;
                }
                '#' if token.is_empty() => {
                    flush(&mut out, &mut token, &mut command_next);
                    span(&mut out, "c", &collect(&chars[i..]));
                    i = chars.len();
                    continue;
                }
                '|' | ';' | '&' | '(' | ')' => {
                    flush(&mut out, &mut token, &mut command_next);
                    span(&mut out, "p", &c.to_string());
                    command_next = true;
                }
                ' ' | '\t' => {
                    flush(&mut out, &mut token, &mut command_next);
                    out.push(c);
                }
                _ => token.push(c),
            }
            i += 1;
        }
        flush(&mut out, &mut token, &mut command_next);
    }
    out
}

fn rust(code: &str) -> String {
    words(code, RUST_KEYWORDS, "//")
}

fn starlark(code: &str) -> String {
    words(code, STARLARK_KEYWORDS, "#")
}

/// A plain word highlighter: comments, strings, numbers, keywords, types,
/// calls.
fn words(code: &str, keywords: &[&str], comment: &str) -> String {
    let chars: Vec<char> = code.chars().collect();
    let comment: Vec<char> = comment.chars().collect();
    let mut out = String::with_capacity(code.len() * 2);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if chars[i..].starts_with(&comment) {
            let end = chars[i..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(chars.len(), |n| i + n);
            span(&mut out, "c", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c == '"' || c == '\'' {
            let end = string_end(&chars, i, c);
            span(&mut out, "s", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if c.is_ascii_digit() {
            let end = number_end(&chars, i);
            span(&mut out, "n", &collect(&chars[i..end]));
            i = end;
            continue;
        }
        if is_ident_start(c) {
            let mut end = i + 1;
            while end < chars.len() && is_ident(chars[end]) {
                end += 1;
            }
            let word = collect(&chars[i..end]);
            if keywords.contains(&word.as_str()) {
                span(&mut out, "k", &word);
            } else if word.chars().next().is_some_and(char::is_uppercase) {
                span(&mut out, "t", &word);
            } else if chars.get(end) == Some(&'(') {
                span(&mut out, "f", &word);
            } else {
                out.push_str(&escape(&word));
            }
            i = end;
            continue;
        }
        out.push_str(&escape(&c.to_string()));
        i += 1;
    }
    out
}
