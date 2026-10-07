//! Finds GraphQL embedded in Kotlin source: a marker annotation
//! (`@Fragment`, `@Query`, `@Mutation`, `@Subscription`, each also qualified
//! as `@baton.Query`) whose argument, labelled `document =` or not, is one
//! string literal in any of Kotlin's forms: a plain `"…"` with its escapes,
//! a raw `"""…"""`, or either after a run of dollars, `$$"""…"""`, in which
//! a run of fewer dollars than the prefix is text. `KotlinHost` is Kotlin as
//! a host language: this scan, the names of the outputs, and the package
//! the code generated for a file takes.
//!
//! The text is the string's value, as the Kotlin compiler reads it: escapes
//! decoded, and a raw string dedented as Swift's multi-line literal is, its
//! common indentation removed and a blank first and last line dropped, so
//! it equals the `.graphql` file an author would write. A GraphQL variable
//! is a template in a string without enough dollars, which the scan refuses
//! at the marker. A position in the text maps back into the file through
//! the literal's start and the indentation removed.

use std::path::Path;

use crate::diagnostics::Rendered;
use crate::documents::{self, Document, EmbeddedDocument, HostLanguage, Marker, Position};
use crate::pipeline;

/// The marker an annotation's name names, if any.
fn marker_named(identifier: &str) -> Option<Marker> {
    match identifier {
        "Fragment" => Some(Marker::Fragment),
        "Query" => Some(Marker::Query),
        "Mutation" => Some(Marker::Mutation),
        "Subscription" => Some(Marker::Subscription),
        _ => None,
    }
}

/// Packages whose star import brings an annotation named like a marker,
/// whose bare use is then theirs: Room's and Retrofit's `@Query`.
const FOREIGN_STAR_IMPORTS: [&str; 2] = ["androidx.room", "retrofit2.http"];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ScanError {
    #[error("{marker} must be followed by a string literal")]
    MissingLiteral { marker: Marker, at: Position },
    #[error("unterminated string literal")]
    UnterminatedLiteral { at: Position },
    #[error("a document with a variable needs a `$$` string")]
    Variable { at: Position },
    #[error(
        "a document must not interpolate: a run of `$` as long as the string's opens a template"
    )]
    Template { at: Position },
    #[error("unknown escape `\\{escape}` in a string literal")]
    UnknownEscape { escape: char, at: Position },
}

impl ScanError {
    pub fn position(&self) -> Position {
        match self {
            ScanError::MissingLiteral { at, .. }
            | ScanError::UnterminatedLiteral { at }
            | ScanError::Variable { at }
            | ScanError::Template { at }
            | ScanError::UnknownEscape { at, .. } => *at,
        }
    }
}

/// Scans one Kotlin file. Errors do not stop the scan; every document that
/// can be found is returned alongside the errors.
pub fn scan(source: &str) -> (Vec<EmbeddedDocument>, Vec<ScanError>) {
    let mut scanner = Scanner::new(source);
    scanner.run();
    let package = scanner.package.clone();
    for document in &mut scanner.documents {
        document.package = package.clone();
    }
    (scanner.documents, scanner.errors)
}

/// Kotlin as a host language.
pub struct KotlinHost;

/// What every generated Kotlin file's name ends in.
const OUTPUT_SUFFIX: &str = ".baton.kt";

impl HostLanguage for KotlinHost {
    fn extensions(&self) -> &'static [&'static str] {
        &["kt"]
    }

    fn scan(&self, source: &str) -> (Vec<EmbeddedDocument>, Vec<(Position, String)>) {
        let (documents, errors) = scan(source);
        let problems = errors
            .into_iter()
            .map(|error| (error.position(), error.to_string()))
            .collect();
        (documents, problems)
    }

    /// The source's path relative to `root`, each directory separator an
    /// underscore, with `.baton.kt` in place of a `.kt` extension and after
    /// any other.
    fn output_name(&self, source: &Path, root: &Path) -> String {
        documents::output_name(source, root, ".kt", OUTPUT_SUFFIX)
    }

    fn shared_output_name(&self) -> &'static str {
        "Baton.baton.kt"
    }

    fn is_output(&self, path: &Path) -> bool {
        path.to_string_lossy().ends_with(OUTPUT_SUFFIX)
    }

    /// A Kotlin marker annotates the composable or the class that holds the
    /// document, never a typed property, so there is nothing to check.
    fn check(&self, _documents: &[Document], _plan: &pipeline::Plan) -> Vec<Rendered> {
        Vec::new()
    }
}

/// A string literal's opening: the dollars before it and whether it is raw.
#[derive(Clone, Copy)]
struct Opening {
    dollars: usize,
    raw: bool,
}

impl Opening {
    /// How many dollars open a template: the prefix's, and one in a string
    /// without a prefix.
    fn template_dollars(self) -> usize {
        self.dollars.max(1)
    }
}

struct Scanner<'a> {
    chars: Vec<(usize, char)>,
    source: &'a str,
    index: usize,
    line: u32,
    column: u32,
    package: Option<String>,
    /// The markers a bare annotation of their name is not Baton's in: the
    /// file imports an annotation of the name from elsewhere.
    foreign: Vec<String>,
    documents: Vec<EmbeddedDocument>,
    errors: Vec<ScanError>,
}

impl<'a> Scanner<'a> {
    fn new(source: &'a str) -> Self {
        Scanner {
            chars: source.char_indices().collect(),
            source,
            index: 0,
            line: 1,
            column: 1,
            package: None,
            foreign: Vec::new(),
            documents: Vec::new(),
            errors: Vec::new(),
        }
    }

    fn run(&mut self) {
        while let Some(current) = self.peek(0) {
            match current {
                '/' if self.peek(1) == Some('/') => self.skip_line_comment(),
                '/' if self.peek(1) == Some('*') => self.skip_block_comment(),
                '\'' => self.skip_character_literal(),
                '"' | '$' => match self.opening() {
                    Some(opening) => self.skip_string_literal(opening),
                    None => {
                        self.advance();
                    }
                },
                '@' => self.scan_annotation(),
                '`' => self.skip_quoted_identifier(),
                character if is_identifier_start(character) => {
                    let word = self.read_identifier();
                    match word.as_str() {
                        "package" if self.package.is_none() => {
                            self.package = Some(self.read_qualified_name());
                        }
                        "import" => self.read_import(),
                        _ => {}
                    }
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn position(&self) -> Position {
        Position {
            line: self.line,
            column: self.column,
        }
    }

    fn peek(&self, offset: usize) -> Option<char> {
        self.chars
            .get(self.index + offset)
            .map(|(_, character)| *character)
    }

    fn advance(&mut self) -> Option<char> {
        let (_, character) = *self.chars.get(self.index)?;
        self.index += 1;
        if character == '\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(character)
    }

    fn advance_by(&mut self, count: usize) {
        for _ in 0..count {
            self.advance();
        }
    }

    fn at_end(&self) -> bool {
        self.index >= self.chars.len()
    }

    fn byte_offset(&self) -> usize {
        self.chars
            .get(self.index)
            .map(|(offset, _)| *offset)
            .unwrap_or(self.source.len())
    }

    /// The string literal that opens at the cursor, after any dollars.
    fn opening(&self) -> Option<Opening> {
        let mut dollars = 0;
        while self.peek(dollars) == Some('$') {
            dollars += 1;
        }
        if self.peek(dollars) != Some('"') {
            return None;
        }
        let raw = self.peek(dollars + 1) == Some('"') && self.peek(dollars + 2) == Some('"');
        Some(Opening { dollars, raw })
    }

    fn skip_line_comment(&mut self) {
        while let Some(character) = self.peek(0) {
            if character == '\n' {
                return;
            }
            self.advance();
        }
    }

    /// Skips a block comment; Kotlin's nest.
    fn skip_block_comment(&mut self) {
        self.advance_by(2);
        let mut depth = 1;
        while depth > 0 && !self.at_end() {
            if self.peek(0) == Some('/') && self.peek(1) == Some('*') {
                self.advance_by(2);
                depth += 1;
            } else if self.peek(0) == Some('*') && self.peek(1) == Some('/') {
                self.advance_by(2);
                depth -= 1;
            } else {
                self.advance();
            }
        }
    }

    /// Skips a character literal, so that `'"'` opens no string.
    fn skip_character_literal(&mut self) {
        self.advance();
        while let Some(character) = self.peek(0) {
            match character {
                '\\' => self.advance_by(2),
                '\'' => {
                    self.advance();
                    return;
                }
                '\n' => return,
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn skip_quoted_identifier(&mut self) {
        self.advance();
        while let Some(character) = self.peek(0) {
            self.advance();
            if character == '`' || character == '\n' {
                return;
            }
        }
    }

    /// Skips a string literal that is not a marker's argument, templates
    /// included, so that quotes inside strings never confuse the scan.
    fn skip_string_literal(&mut self, opening: Opening) {
        self.advance_by(opening.dollars);
        self.advance_by(if opening.raw { 3 } else { 1 });
        let template = opening.template_dollars();
        while let Some(character) = self.peek(0) {
            match character {
                '\\' if !opening.raw => self.advance_by(2),
                '"' if !opening.raw => {
                    self.advance();
                    return;
                }
                '"' if self.closes_raw() => {
                    self.close_raw();
                    return;
                }
                '\n' if !opening.raw => return,
                '$' => {
                    let run = self.dollar_run();
                    self.advance_by(run);
                    if run >= template && self.peek(0) == Some('{') {
                        self.skip_template_expression();
                    }
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    /// The length of the run of dollars at the cursor.
    fn dollar_run(&self) -> usize {
        let mut run = 0;
        while self.peek(run) == Some('$') {
            run += 1;
        }
        run
    }

    /// Whether the cursor is at the quotes that close a raw string: three,
    /// the last of a longer run, whose first ones are text.
    fn closes_raw(&self) -> bool {
        (0..3).all(|offset| self.peek(offset) == Some('"'))
    }

    /// Steps over the quotes that close a raw string, keeping none of them;
    /// returns how many of the run's quotes are text.
    fn close_raw(&mut self) -> usize {
        let mut run = 0;
        while self.peek(run) == Some('"') {
            run += 1;
        }
        self.advance_by(run);
        run - 3
    }

    /// Skips a `${…}` template's expression, strings nested in it included.
    fn skip_template_expression(&mut self) {
        self.advance();
        let mut depth = 1;
        while depth > 0 && !self.at_end() {
            match self.peek(0) {
                Some('{') => depth += 1,
                Some('}') => depth -= 1,
                Some('\'') => {
                    self.skip_character_literal();
                    continue;
                }
                Some('"' | '$') => {
                    if let Some(opening) = self.opening() {
                        self.skip_string_literal(opening);
                        continue;
                    }
                }
                _ => {}
            }
            self.advance();
        }
    }

    fn read_identifier(&mut self) -> String {
        let mut identifier = String::new();
        while let Some(character) = self.peek(0) {
            if character.is_alphanumeric() || character == '_' {
                identifier.push(character);
                self.advance();
            } else {
                break;
            }
        }
        identifier
    }

    /// A dotted name after `package` or `import`, its segments unquoted,
    /// with a trailing `.*` kept.
    fn read_qualified_name(&mut self) -> String {
        self.skip_spaces();
        let mut name = String::new();
        loop {
            match self.peek(0) {
                Some('`') => {
                    self.advance();
                    while let Some(character) = self.peek(0) {
                        if character == '`' || character == '\n' {
                            self.advance();
                            break;
                        }
                        name.push(character);
                        self.advance();
                    }
                }
                Some('*') => {
                    name.push('*');
                    self.advance();
                    return name;
                }
                Some(character) if is_identifier_start(character) => {
                    name.push_str(&self.read_identifier());
                }
                _ => return name,
            }
            self.skip_spaces();
            if self.peek(0) != Some('.') {
                return name;
            }
            name.push('.');
            self.advance();
            self.skip_spaces();
        }
    }

    /// Notes an import of an annotation named like a marker from elsewhere,
    /// which a bare annotation of the name then is.
    fn read_import(&mut self) {
        let name = self.read_qualified_name();
        if let Some(package) = name.strip_suffix(".*") {
            if FOREIGN_STAR_IMPORTS.contains(&package) {
                self.foreign.push("Query".to_string());
            }
            return;
        }
        let Some((package, simple)) = name.rsplit_once('.') else {
            return;
        };
        if package != "baton" && marker_named(simple).is_some() {
            self.foreign.push(simple.to_string());
        }
    }

    fn skip_spaces(&mut self) {
        while matches!(self.peek(0), Some(' ' | '\t')) {
            self.advance();
        }
    }

    fn skip_whitespace(&mut self) {
        while let Some(character) = self.peek(0) {
            if character.is_whitespace() {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn scan_annotation(&mut self) {
        let attribute = self.position();
        self.advance();
        let mut identifier = self.read_identifier();
        // `@baton.Query` names the same annotation as `@Query`.
        let qualified = identifier == "baton" && self.peek(0) == Some('.');
        if qualified {
            self.advance();
            identifier = self.read_identifier();
        }
        let Some(marker) = marker_named(&identifier) else {
            return;
        };
        if !qualified && self.foreign.contains(&identifier) {
            return;
        }
        self.skip_whitespace();
        if self.peek(0) != Some('(') {
            return;
        }
        self.advance();
        self.skip_whitespace();
        if self.at_label("document") {
            self.advance_by("document".len());
            self.skip_whitespace();
            self.advance();
            self.skip_whitespace();
        }
        let Some(opening) = self.opening() else {
            self.errors.push(ScanError::MissingLiteral {
                marker,
                at: self.position(),
            });
            return;
        };
        let Some(literal) = self.read_literal(opening) else {
            return;
        };
        if literal.template {
            self.errors.push(if opening.dollars < 2 {
                ScanError::Variable { at: attribute }
            } else {
                ScanError::Template { at: attribute }
            });
        }
        self.skip_remaining_arguments();
        self.documents.push(EmbeddedDocument {
            marker,
            attribute,
            start: literal.start,
            text: literal.text,
            property: None,
            indentation: literal.indentation,
            package: None,
        });
    }

    /// Whether the cursor is at `label` followed by `=`, the argument's
    /// name.
    fn at_label(&self, label: &str) -> bool {
        let length = label.chars().count();
        let matches = label
            .chars()
            .enumerate()
            .all(|(offset, character)| self.peek(offset) == Some(character));
        if !matches {
            return false;
        }
        let mut offset = length;
        while matches!(self.peek(offset), Some(character) if character.is_whitespace()) {
            offset += 1;
        }
        self.peek(offset) == Some('=') && self.peek(offset + 1) != Some('=')
    }

    /// Reads the literal at the cursor and returns its value, where the
    /// value starts in the file and the indentation a raw string's lines
    /// lost, and whether the string holds a template.
    fn read_literal(&mut self, opening: Opening) -> Option<Literal> {
        let at = self.position();
        self.advance_by(opening.dollars);
        if opening.raw {
            self.advance_by(3);
            let start = self.position();
            let begin = self.byte_offset();
            loop {
                if self.at_end() {
                    self.errors.push(ScanError::UnterminatedLiteral { at });
                    return None;
                }
                if self.closes_raw() {
                    let end = self.byte_offset();
                    let quotes = self.close_raw();
                    let mut content = self.source[begin..end].to_string();
                    content.push_str(&"\"".repeat(quotes));
                    let template = template_in(&content, opening.template_dollars());
                    let (text, start, indentation) = dedent(&content, start);
                    return Some(Literal {
                        text,
                        start,
                        indentation,
                        template,
                    });
                }
                self.advance();
            }
        }
        self.advance();
        let start = self.position();
        let mut text = String::new();
        let mut template = false;
        while let Some(character) = self.peek(0) {
            match character {
                '"' => {
                    self.advance();
                    return Some(Literal {
                        text,
                        start,
                        indentation: 0,
                        template,
                    });
                }
                '\n' => break,
                '\\' => {
                    let escape_at = self.position();
                    self.advance();
                    match self.read_escape() {
                        Ok(decoded) => text.push(decoded),
                        Err(escape) => self.errors.push(ScanError::UnknownEscape {
                            escape,
                            at: escape_at,
                        }),
                    }
                }
                '$' => {
                    let run = self.dollar_run();
                    self.advance_by(run);
                    let opens = matches!(self.peek(0), Some(next) if next == '{' || is_identifier_start(next));
                    template |= run >= opening.template_dollars() && opens;
                    text.push_str(&"$".repeat(run));
                }
                _ => {
                    text.push(character);
                    self.advance();
                }
            }
        }
        self.errors.push(ScanError::UnterminatedLiteral { at });
        None
    }

    /// The character an escape after its backslash stands for, or the
    /// character that starts an escape Kotlin does not have.
    fn read_escape(&mut self) -> Result<char, char> {
        let Some(character) = self.advance() else {
            return Err(' ');
        };
        Ok(match character {
            't' => '\t',
            'b' => '\u{8}',
            'n' => '\n',
            'r' => '\r',
            '\'' => '\'',
            '"' => '"',
            '\\' => '\\',
            '$' => '$',
            'u' => {
                let digits: String = (0..4).filter_map(|offset| self.peek(offset)).collect();
                let decoded = (digits.len() == 4)
                    .then(|| u32::from_str_radix(&digits, 16).ok())
                    .flatten()
                    .and_then(char::from_u32);
                match decoded {
                    Some(decoded) => {
                        self.advance_by(4);
                        decoded
                    }
                    None => return Err('u'),
                }
            }
            other => return Err(other),
        })
    }

    /// Skips the rest of an annotation's argument list after the literal, up
    /// to and including the closing parenthesis.
    fn skip_remaining_arguments(&mut self) {
        let mut depth = 1;
        while let Some(character) = self.peek(0) {
            match character {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        self.advance();
                        return;
                    }
                }
                '"' | '$' => {
                    if let Some(opening) = self.opening() {
                        self.skip_string_literal(opening);
                        continue;
                    }
                }
                _ => {}
            }
            self.advance();
        }
    }
}

/// A marker's literal as the scan read it.
struct Literal {
    text: String,
    start: Position,
    indentation: u32,
    /// Whether the string holds a template.
    template: bool,
}

fn is_identifier_start(character: char) -> bool {
    character.is_alphabetic() || character == '_'
}

/// Whether a raw string's `content` holds a template: a run of at least
/// `dollars` dollars before a name or a brace.
fn template_in(content: &str, dollars: usize) -> bool {
    let characters: Vec<char> = content.chars().collect();
    let mut index = 0;
    while index < characters.len() {
        if characters[index] != '$' {
            index += 1;
            continue;
        }
        let mut run = 0;
        while characters.get(index + run) == Some(&'$') {
            run += 1;
        }
        index += run;
        let opens = matches!(characters.get(index), Some(next) if *next == '{' || is_identifier_start(*next));
        if run >= dollars && opens {
            return true;
        }
    }
    false
}

/// A raw string's content as Swift's multi-line literal reads its own: a
/// blank first and last line dropped, and the indentation the non-blank
/// lines share removed from each. Returns the text, where its first
/// character sits in the file given where the content's does, and the
/// indentation removed.
pub fn dedent(content: &str, start: Position) -> (String, Position, u32) {
    let mut lines: Vec<&str> = content.split('\n').collect();
    let mut start = start;
    if lines.len() > 1 && lines[0].trim().is_empty() {
        lines.remove(0);
        start = Position {
            line: start.line + 1,
            column: 1,
        };
    }
    if lines.len() > 1 && lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    let indentation = lines
        .iter()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            line.chars()
                .take_while(|character| *character == ' ' || *character == '\t')
                .count()
        })
        .min()
        .unwrap_or(0);
    let dedented: Vec<String> = lines
        .iter()
        .map(|line| {
            if line.trim().is_empty() {
                String::new()
            } else {
                line.chars().skip(indentation).collect()
            }
        })
        .collect();
    let removed = indentation as u32;
    start.column += removed;
    (dedented.join("\n"), start, removed)
}

#[cfg(test)]
#[path = "tests/kotlin_tests.rs"]
mod tests;
