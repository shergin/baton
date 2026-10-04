//! Names in generated Swift: the identifiers a document's names become, and
//! the allocator that gives each declaration of a scope a name of its own.
//!
//! Swift resolves an unqualified name to the nearest declaration, so a nested
//! type named like a type the generated code spells unqualified shadows it
//! for everything nested in the scope, and two declarations of one name in one
//! scope do not compile. Every name an emitter declares is taken from its
//! scope's allocator, which knows the reserved names and the names already
//! declared, and reports a second declaration of a name rather than writing
//! Swift that does not compile.

use std::collections::BTreeSet;

/// How a declaration's name meets the others of its scope. Instance
/// properties clash with instance properties and static ones with static
/// ones, while Swift tells either from a method by its argument labels, so
/// methods are not declared here. A nested type clashes with any
/// declaration, since an expression that names it would be ambiguous.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Instance,
    Static,
    Type,
}

impl Kind {
    fn clashes(self, other: Kind) -> bool {
        self == other || self == Kind::Type || other == Kind::Type
    }
}

/// A name two declarations of one scope would take.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "internal error: `{scope}` would declare `{name}` twice, as {first} and as {second}; please report it"
)]
pub struct DuplicateName {
    pub scope: String,
    pub name: String,
    pub first: String,
    pub second: String,
}

/// Every type and attribute name the emitter writes unqualified inside a
/// lens, and the names Swift keeps for itself. A nested lens of one of
/// these names would shadow it for the lens and everything nested in it, or
/// not compile; an identifier a lens comes to spell unqualified joins the
/// list in the same change.
pub const RESERVED_TYPE_NAMES: [&str; 16] = [
    // Swift lets no type member take these names.
    "Type",
    "Self",
    "Protocol",
    "Any",
    // The attribute on every accessor and check.
    "MainActor",
    // The runtime's module and the module's shared enums.
    "Baton",
    "Types",
    "Slots",
    "AbstractSlots",
    "Sites",
    // What the accessors return: a `@catch` field's `Result`, the
    // `Optional` every optional accessor's type stands for, and the
    // scalars.
    "Result",
    "Optional",
    "String",
    "Int",
    "Double",
    "Bool",
];

/// What an optimistic-response builder writes unqualified, and the names
/// Swift keeps for itself: a nested builder of one of these names would
/// shadow it, or conform to itself.
pub const BUILDER_RESERVED_NAMES: [&str; 10] = [
    "Type", "Self", "Protocol", "Any", "Sendable", "Baton", "String", "Int", "Double", "Bool",
];

/// The names a nested type of one kind of scope may not take, and what is
/// written after a name that would be one of them.
pub struct Reserved {
    names: BTreeSet<String>,
    suffix: &'static str,
}

impl Reserved {
    /// For lenses: the names a lens spells, and every fragment and
    /// operation of the program, which a lens refers to unqualified; `Lens`
    /// goes after one of them.
    pub fn lenses<'a>(program: impl IntoIterator<Item = &'a str>) -> Reserved {
        let mut names: BTreeSet<String> = RESERVED_TYPE_NAMES
            .iter()
            .map(|name| name.to_string())
            .collect();
        names.extend(program.into_iter().map(str::to_string));
        Reserved {
            names,
            suffix: "Lens",
        }
    }

    /// For optimistic-response builders, `Response` after a reserved name.
    pub fn builders() -> Reserved {
        Reserved {
            names: BUILDER_RESERVED_NAMES
                .iter()
                .map(|name| name.to_string())
                .collect(),
            suffix: "Response",
        }
    }

    /// For scopes that name nothing they nest after a document's names.
    pub fn none() -> Reserved {
        Reserved {
            names: BTreeSet::new(),
            suffix: "",
        }
    }

    /// The type name for `property`: capitalized, with the suffix after a
    /// reserved name.
    pub fn type_name(&self, property: &str) -> String {
        let name = capitalize(property);
        if self.names.contains(&name) {
            name + self.suffix
        } else {
            name
        }
    }
}

/// The declarations of one Swift scope: a lens, an operation, a builder or
/// one of the shared enums.
pub struct Scope<'a> {
    /// The scope as Swift names it, for messages.
    path: String,
    reserved: &'a Reserved,
    declared: Vec<(String, Kind, String)>,
    duplicates: Vec<DuplicateName>,
}

impl<'a> Scope<'a> {
    pub fn new(path: impl Into<String>, reserved: &'a Reserved) -> Scope<'a> {
        Scope {
            path: path.into(),
            reserved,
            declared: Vec::new(),
            duplicates: Vec::new(),
        }
    }

    /// Declares `name` as it is, for `what`; a name the scope declared
    /// already is recorded as a duplicate.
    pub fn declare(&mut self, name: &str, kind: Kind, what: impl Into<String>) {
        let what = what.into();
        if let Some((_, _, first)) = self
            .declared
            .iter()
            .find(|(existing, existing_kind, _)| existing == name && existing_kind.clashes(kind))
        {
            self.duplicates.push(DuplicateName {
                scope: self.path.clone(),
                name: name.to_string(),
                first: first.clone(),
                second: what.clone(),
            });
        }
        self.declared.push((name.to_string(), kind, what));
    }

    /// Whether a declaration of `kind` can take `name`.
    fn is_free(&self, name: &str, kind: Kind) -> bool {
        if kind == Kind::Type && self.reserved.names.contains(name) {
            return false;
        }
        !self
            .declared
            .iter()
            .any(|(existing, existing_kind, _)| existing == name && existing_kind.clashes(kind))
    }

    /// A member: the first of `candidates` the scope has free, else the last
    /// with the first number after it that is.
    pub fn member(&mut self, candidates: &[String], kind: Kind, what: impl Into<String>) -> String {
        let name = match candidates
            .iter()
            .find(|candidate| self.is_free(candidate, kind))
        {
            Some(free) => free.clone(),
            None => {
                let base = candidates.last().expect("a member has a candidate name");
                self.numbered(|number| vec![(format!("{base}{number}"), kind)])
                    .remove(0)
            }
        };
        self.declare(&name, kind, what);
        name
    }

    /// The nested type for `property`, as `Reserved::type_name` spells it,
    /// numbered when the scope has the name.
    pub fn nested_type(&mut self, property: &str, what: impl Into<String>) -> String {
        let base = self.reserved.type_name(property);
        let name = if self.is_free(&base, Kind::Type) {
            base
        } else {
            self.numbered(|number| vec![(format!("{base}{number}"), Kind::Type)])
                .remove(0)
        };
        self.declare(&name, Kind::Type, what);
        name
    }

    /// An instance property and the nested type it reads as, under one
    /// number when either name is taken: `asCharacter2` and `AsCharacter2`.
    pub fn member_and_type(
        &mut self,
        member: &str,
        type_name: &str,
        what: impl Into<String>,
    ) -> (String, String) {
        let what = what.into();
        let type_base = self.reserved.type_name(type_name);
        let (member, type_name) =
            if self.is_free(member, Kind::Instance) && self.is_free(&type_base, Kind::Type) {
                (member.to_string(), type_base)
            } else {
                let mut names = self.numbered(|number| {
                    vec![
                        (format!("{member}{number}"), Kind::Instance),
                        (format!("{type_base}{number}"), Kind::Type),
                    ]
                });
                let type_name = names.remove(1);
                (names.remove(0), type_name)
            };
        self.declare(&member, Kind::Instance, what.clone());
        self.declare(&type_name, Kind::Type, what);
        (member, type_name)
    }

    /// The names `make` spells for the first number from 2 at which the
    /// scope has all of them free.
    fn numbered(&self, make: impl Fn(usize) -> Vec<(String, Kind)>) -> Vec<String> {
        let mut number = 2;
        loop {
            let names = make(number);
            if names.iter().all(|(name, kind)| self.is_free(name, *kind)) {
                return names.into_iter().map(|(name, _)| name).collect();
            }
            number += 1;
        }
    }

    /// The names declared twice.
    pub fn finish(self) -> Vec<DuplicateName> {
        self.duplicates
    }
}

pub fn capitalize(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

pub fn lower_camel(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_lowercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// A type's or a field's name in `Slots` and `AbstractSlots`. Swift reads
/// `Type` and `Protocol` after a dot as metatypes, and a scope or a member
/// named `Types` or `Baton` hides the enum or the module the slots are built
/// from, so these names take an underscore. One of them followed by
/// underscores takes one more, so no two names meet.
pub fn slot_name(name: &str) -> String {
    const HIDDEN: [&str; 4] = ["Type", "Protocol", "Types", "Baton"];
    if HIDDEN.contains(&name.trim_end_matches('_')) {
        return format!("{name}_");
    }
    escape(name)
}

/// Escapes a property name that is a Swift keyword.
pub fn escape(name: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "Type",
        "Protocol",
        "self",
        "Self",
        "init",
        "deinit",
        "subscript",
        "class",
        "struct",
        "enum",
        "func",
        "var",
        "let",
        "import",
        "extension",
        "operator",
        "static",
        "default",
        "case",
        "switch",
        "if",
        "else",
        "for",
        "in",
        "while",
        "repeat",
        "return",
        "break",
        "continue",
        "where",
        "is",
        "as",
        "try",
        "throw",
        "throws",
        "guard",
        "defer",
        "do",
        "catch",
        "true",
        "false",
        "nil",
        "super",
        "internal",
        "private",
        "public",
        "fileprivate",
        "open",
        "inout",
        "typealias",
        "associatedtype",
        "protocol",
        "some",
        "any",
    ];
    if KEYWORDS.contains(&name) {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

#[cfg(test)]
#[path = "tests/names_tests.rs"]
mod tests;
