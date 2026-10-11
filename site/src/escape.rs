//! HTML escaping, the one helper every renderer shares.

/// Escapes text for HTML element content and attribute values.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

/// Backticks to `<code>` and nothing else: captions stay one sentence.
pub fn inline_markdown(text: &str) -> String {
    let mut out = String::new();
    let mut code = false;
    for part in text.split('`') {
        if code {
            out.push_str("<code>");
            out.push_str(&escape(part));
            out.push_str("</code>");
        } else {
            out.push_str(&escape(part));
        }
        code = !code;
    }
    out
}
