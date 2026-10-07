//! The writer every printer writes through: lines at a depth. It owns the
//! indentation, so no printer carries a string of spaces or closes a brace
//! at a column it worked out.

/// One level of indentation.
const INDENT: &str = "    ";

/// Generated Swift under way: the text so far and the depth the next line
/// is written at.
pub(super) struct Writer {
    text: String,
    depth: usize,
}

impl Writer {
    pub(super) fn new() -> Writer {
        Writer {
            text: String::new(),
            depth: 0,
        }
    }

    /// A line at the current depth. Text that holds line breaks of its own,
    /// a multi-line literal or an expression laid out by its printer, keeps
    /// them as they are: only its first line is indented here.
    pub(super) fn line(&mut self, line: impl AsRef<str>) {
        for _ in 0..self.depth {
            self.text.push_str(INDENT);
        }
        self.text.push_str(line.as_ref());
        self.text.push('\n');
    }

    /// An empty line.
    pub(super) fn blank(&mut self) {
        self.text.push('\n');
    }

    /// A documentation comment of one line.
    pub(super) fn doc(&mut self, comment: impl AsRef<str>) {
        self.line(format!("/// {}", comment.as_ref()));
    }

    /// `head {`, what `body` writes one level deeper, and the closing brace.
    pub(super) fn block(&mut self, head: impl AsRef<str>, body: impl FnOnce(&mut Writer)) {
        self.closed_block(format!("{} {{", head.as_ref()), "}", body);
    }

    /// `opening`, a line that ends inside the brace it opens, as
    /// `x = { () -> T in` does, what `body` writes one level deeper, and
    /// `close`: the closing brace and what follows it on its line, as `}()`
    /// closes a closure called where it stands.
    pub(super) fn closed_block(
        &mut self,
        opening: impl AsRef<str>,
        close: &str,
        body: impl FnOnce(&mut Writer),
    ) {
        self.line(opening);
        self.depth += 1;
        body(self);
        self.depth -= 1;
        self.line(close);
    }

    /// The depth the next line is written at, for a printer that lays out
    /// an expression over several lines by itself.
    pub(super) fn depth(&self) -> usize {
        self.depth
    }

    pub(super) fn finish(self) -> String {
        self.text
    }
}

#[cfg(test)]
#[path = "../tests/emit_writer_tests.rs"]
mod tests;
