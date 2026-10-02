//! Finds GraphQL embedded in Swift source: a marker attribute (`@Fragment`,
//! `@Query`, `@Mutation`, `@Subscription`) followed by a string literal.
//!
//! The literal's text is taken verbatim, with its indentation, so every
//! character of the GraphQL sits at its exact file position and diagnostics
//! map back without arithmetic. Swift strips the indentation at run time; the
//! runtime value of the literal is never used.

use std::fmt;

/// The attribute that introduced an embedded document.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum Marker {
    Fragment,
    Query,
    Mutation,
    Subscription,
}

impl Marker {
    fn from_identifier(identifier: &str) -> Option<Marker> {
        match identifier {
            "Fragment" => Some(Marker::Fragment),
            "Query" => Some(Marker::Query),
            "Mutation" => Some(Marker::Mutation),
            "Subscription" => Some(Marker::Subscription),
            _ => None,
        }
    }
}

impl fmt::Display for Marker {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Marker::Fragment => "@Fragment",
            Marker::Query => "@Query",
            Marker::Mutation => "@Mutation",
            Marker::Subscription => "@Subscription",
        })
    }
}

/// A 1-based position in a source file. Columns count characters.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Position {
    pub line: u32,
    pub column: u32,
}

/// The property declaration that follows a marker attribute, when there is one.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Property {
    pub name: String,
    /// The written type, e.g. `CharacterRow_character` or `Foo?`.
    pub type_name: String,
}

/// One GraphQL document found inside a Swift file.
#[derive(Clone, Debug, serde::Serialize)]
pub struct EmbeddedDocument {
    pub marker: Marker,
    /// Where the attribute starts.
    pub attribute: Position,
    /// Where the first character of `text` sits in the file.
    pub start: Position,
    /// The literal's content, verbatim.
    pub text: String,
    pub property: Option<Property>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ScanError {
    #[error("{marker} must be followed by a string literal")]
    MissingLiteral { marker: Marker, at: Position },
    #[error("unterminated string literal")]
    UnterminatedLiteral { at: Position },
    #[error("the opening \"\"\" must be followed by a newline")]
    MultilineOpeningNotAlone { at: Position },
    #[error("GraphQL literals must not contain escapes or interpolation")]
    EscapeInLiteral { at: Position },
}

impl ScanError {
    pub fn position(&self) -> Position {
        match self {
            ScanError::MissingLiteral { at, .. }
            | ScanError::UnterminatedLiteral { at }
            | ScanError::MultilineOpeningNotAlone { at }
            | ScanError::EscapeInLiteral { at } => *at,
        }
    }
}

/// Scans one Swift file. Errors do not stop the scan; every document that can
/// be found is returned alongside the errors.
pub fn scan(source: &str) -> (Vec<EmbeddedDocument>, Vec<ScanError>) {
    let mut scanner = Scanner::new(source);
    scanner.run();
    (scanner.documents, scanner.errors)
}

struct Scanner<'a> {
    chars: Vec<(usize, char)>,
    source: &'a str,
    index: usize,
    line: u32,
    column: u32,
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
            documents: Vec::new(),
            errors: Vec::new(),
        }
    }

    fn run(&mut self) {
        while let Some(current) = self.peek(0) {
            match current {
                '/' if self.peek(1) == Some('/') => self.skip_line_comment(),
                '/' if self.peek(1) == Some('*') => self.skip_block_comment(),
                '"' => self.skip_string_literal(),
                '#' if self.is_raw_string_start() => self.skip_raw_string_literal(),
                '@' => self.scan_attribute(),
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

    fn at_end(&self) -> bool {
        self.index >= self.chars.len()
    }

    fn byte_offset(&self) -> usize {
        self.chars
            .get(self.index)
            .map(|(offset, _)| *offset)
            .unwrap_or(self.source.len())
    }

    fn skip_line_comment(&mut self) {
        while let Some(character) = self.peek(0) {
            if character == '\n' {
                return;
            }
            self.advance();
        }
    }

    fn skip_block_comment(&mut self) {
        self.advance();
        self.advance();
        let mut depth = 1;
        while depth > 0 && !self.at_end() {
            if self.peek(0) == Some('/') && self.peek(1) == Some('*') {
                self.advance();
                self.advance();
                depth += 1;
            } else if self.peek(0) == Some('*') && self.peek(1) == Some('/') {
                self.advance();
                self.advance();
                depth -= 1;
            } else {
                self.advance();
            }
        }
    }

    fn is_raw_string_start(&self) -> bool {
        let mut offset = 0;
        while self.peek(offset) == Some('#') {
            offset += 1;
        }
        self.peek(offset) == Some('"')
    }

    /// Skips a string literal that is not a marker's argument, including
    /// interpolations, so that quotes inside strings never confuse the scan.
    fn skip_string_literal(&mut self) {
        let multiline = self.peek(1) == Some('"') && self.peek(2) == Some('"');
        let delimiter_length = if multiline { 3 } else { 1 };
        for _ in 0..delimiter_length {
            self.advance();
        }
        while !self.at_end() {
            match self.peek(0) {
                Some('\\') => {
                    if self.peek(1) == Some('(') {
                        self.advance();
                        self.advance();
                        self.skip_interpolation();
                    } else {
                        self.advance();
                        self.advance();
                    }
                }
                Some('"') if !multiline => {
                    self.advance();
                    return;
                }
                Some('"') if self.peek(1) == Some('"') && self.peek(2) == Some('"') => {
                    for _ in 0..3 {
                        self.advance();
                    }
                    return;
                }
                Some('\n') if !multiline => return,
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn skip_interpolation(&mut self) {
        let mut depth = 1;
        while depth > 0 && !self.at_end() {
            match self.peek(0) {
                Some('(') => depth += 1,
                Some(')') => depth -= 1,
                Some('"') => {
                    self.skip_string_literal();
                    continue;
                }
                _ => {}
            }
            self.advance();
        }
    }

    fn skip_raw_string_literal(&mut self) {
        let mut hashes = 0;
        while self.peek(0) == Some('#') {
            self.advance();
            hashes += 1;
        }
        let multiline = self.peek(1) == Some('"') && self.peek(2) == Some('"');
        let delimiter_length = if multiline { 3 } else { 1 };
        for _ in 0..delimiter_length {
            self.advance();
        }
        while !self.at_end() {
            if self.peek(0) == Some('"') {
                let closing_quotes = if multiline { 3 } else { 1 };
                let quotes_match = (0..closing_quotes).all(|offset| self.peek(offset) == Some('"'));
                let hashes_match =
                    (0..hashes).all(|offset| self.peek(closing_quotes + offset) == Some('#'));
                if quotes_match && hashes_match {
                    for _ in 0..(closing_quotes + hashes) {
                        self.advance();
                    }
                    return;
                }
            }
            self.advance();
        }
    }

    fn scan_attribute(&mut self) {
        let attribute = self.position();
        self.advance();
        let identifier = self.read_identifier();
        let Some(marker) = Marker::from_identifier(&identifier) else {
            return;
        };
        self.skip_whitespace();
        if self.peek(0) != Some('(') {
            return;
        }
        self.advance();
        self.skip_whitespace();
        if self.peek(0) != Some('"') {
            self.errors.push(ScanError::MissingLiteral {
                marker,
                at: self.position(),
            });
            return;
        }
        let Some((text, start)) = self.read_literal() else {
            return;
        };
        if text.contains('\\') {
            self.errors.push(ScanError::EscapeInLiteral { at: start });
        }
        self.skip_whitespace();
        if self.peek(0) == Some(')') {
            self.advance();
        }
        let property = self.read_property();
        self.documents.push(EmbeddedDocument {
            marker,
            attribute,
            start,
            text,
            property,
        });
    }

    /// Reads the literal at the cursor and returns its verbatim content and the
    /// file position of the content's first character.
    fn read_literal(&mut self) -> Option<(String, Position)> {
        let opening = self.position();
        let multiline = self.peek(1) == Some('"') && self.peek(2) == Some('"');
        if !multiline {
            self.advance();
            let start = self.position();
            let begin = self.byte_offset();
            while let Some(character) = self.peek(0) {
                if character == '"' {
                    let text = self.source[begin..self.byte_offset()].to_string();
                    self.advance();
                    return Some((text, start));
                }
                if character == '\n' {
                    break;
                }
                self.advance();
            }
            self.errors
                .push(ScanError::UnterminatedLiteral { at: opening });
            return None;
        }
        for _ in 0..3 {
            self.advance();
        }
        while matches!(self.peek(0), Some(' ') | Some('\t')) {
            self.advance();
        }
        if self.peek(0) != Some('\n') {
            self.errors
                .push(ScanError::MultilineOpeningNotAlone { at: opening });
            return None;
        }
        self.advance();
        let start = self.position();
        let begin = self.byte_offset();
        let mut line_begin = begin;
        loop {
            if self.at_end() {
                self.errors
                    .push(ScanError::UnterminatedLiteral { at: opening });
                return None;
            }
            if self.peek(0) == Some('"') && self.peek(1) == Some('"') && self.peek(2) == Some('"') {
                // The closing delimiter must be the first non-blank on its line;
                // the content ends before that line's newline.
                let prefix = &self.source[line_begin..self.byte_offset()];
                if prefix.trim().is_empty() {
                    let end = line_begin.saturating_sub(1).max(begin);
                    let text = self.source[begin..end].to_string();
                    for _ in 0..3 {
                        self.advance();
                    }
                    return Some((text, start));
                }
            }
            if self.advance() == Some('\n') {
                line_begin = self.byte_offset();
            }
        }
    }

    /// Reads `var name: Type` after the attribute, skipping modifiers and
    /// further attributes. Returns `None` when the declaration is not a property.
    fn read_property(&mut self) -> Option<Property> {
        let saved = (self.index, self.line, self.column);
        loop {
            self.skip_whitespace();
            match self.peek(0) {
                Some('@') => {
                    self.advance();
                    self.read_identifier();
                    self.skip_whitespace();
                    if self.peek(0) == Some('(') {
                        self.skip_balanced_parentheses();
                    }
                }
                Some(character) if character.is_alphabetic() || character == '_' => {
                    let word = self.read_identifier();
                    if word == "var" || word == "let" {
                        self.skip_whitespace();
                        let name = self.read_identifier();
                        self.skip_whitespace();
                        if self.peek(0) != Some(':') {
                            break;
                        }
                        self.advance();
                        self.skip_whitespace();
                        let type_name = self.read_type();
                        if name.is_empty() || type_name.is_empty() {
                            break;
                        }
                        return Some(Property { name, type_name });
                    }
                    if word.is_empty() {
                        break;
                    }
                    // A modifier such as `private` or `nonisolated(unsafe)`.
                    self.skip_whitespace();
                    if self.peek(0) == Some('(') {
                        self.skip_balanced_parentheses();
                    }
                }
                _ => break,
            }
        }
        (self.index, self.line, self.column) = saved;
        None
    }

    fn skip_balanced_parentheses(&mut self) {
        let mut depth = 0;
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
                '"' => {
                    self.skip_string_literal();
                    continue;
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

    fn read_type(&mut self) -> String {
        let mut type_name = String::new();
        while let Some(character) = self.peek(0) {
            if character.is_alphanumeric()
                || matches!(character, '_' | '.' | '?' | '<' | '>' | '[' | ']')
            {
                type_name.push(character);
                self.advance();
            } else {
                break;
            }
        }
        type_name
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
}

#[cfg(test)]
#[path = "tests/swift_tests.rs"]
mod tests;
