//! Names in generated code, in no language's terms: what the decide pass
//! asks of a language's names, and the allocator that gives each
//! declaration of a scope a name of its own.
//!
//! A language resolves an unqualified name to the nearest declaration, so a
//! nested type named like a type the generated code spells unqualified
//! shadows it for everything nested in the scope, and two declarations of one
//! name in one scope do not compile. Every name an emitter declares is taken
//! from its scope's allocator, which knows the reserved names and the names
//! already declared, and reports a second declaration of a name rather than
//! writing code that does not compile: at the document's name when the
//! document chose one of the two, as an internal error when the compiler
//! chose both. What a language reserves, escapes and spells is a `Naming`;
//! Swift's is `names::SwiftNaming`.

use std::collections::BTreeSet;

use crate::pipeline::{OperationKind, OperationPlan, Origin};

/// What the decide pass asks of the language it decides names for: how a
/// document's name becomes an identifier, which names a nested type may not
/// take, how the generated families and the members every scope declares
/// are spelled, and the host type a mapped scalar reads as.
pub trait Naming {
    /// The language, as a message calls the code generated in it.
    fn language(&self) -> &'static str;

    /// The accessor a fragment's name, or its owner's prefix, reads as.
    fn accessor(&self, name: &str) -> String;

    /// The name a property's value goes by as a parameter or a local, past
    /// the names in `taken` where the property's own cannot be one.
    fn local(&self, property: &str, taken: &[&str]) -> String;

    /// The names a nested type at `position` may not take beside the
    /// program's own.
    fn reserved(&self, position: Position) -> Vec<&'static str>;

    /// What is written after a name a type at `position` may not take.
    fn suffix(&self, position: Position) -> &'static str;

    /// A name the generated code declares or spells, as it is spelled.
    fn spelling(&self, spelled: Spelled) -> &'static str;

    /// What a message calls a name the generated code declares or spells.
    fn description(&self, spelled: Spelled) -> String;

    /// The names the module's top level keeps for the language itself, its
    /// modules, keywords and standard library, each with what a message
    /// calls it, in the order they are declared.
    fn module_names(&self) -> Vec<(&'static str, String)>;

    /// A schema enum's type, declared at the module's top level.
    fn enum_type(&self, name: &str) -> String;

    /// A schema input object's type, declared at the module's top level.
    fn input_type(&self, name: &str) -> String;

    /// A type's or a field's name in the slot families, unescaped, as its
    /// scope declares it.
    fn slot_name(&self, name: &str) -> String;

    /// A schema type's constant in the family of types, unescaped, as its
    /// scope declares it.
    fn type_constant(&self, name: &str) -> String;

    /// The constant of the types that satisfy `condition`.
    fn possible_types(&self, condition: &str) -> String;

    /// The constant of the members of an abstract type that one value keys.
    fn keyed_types(&self, condition: &str) -> String;

    /// The host type a mapped custom scalar reads as, by the scalar's name,
    /// as the configuration names it for the language.
    fn host_type(&self, scalar: &str) -> Option<&str>;

    /// What an operation's value declares, or spells where a variable would
    /// hide it, beside its variables; `spelled` are the shared families its
    /// plan and root lens read through.
    fn value_names(&self, operation: &OperationPlan, spelled: &BTreeSet<Spelled>) -> ValueNames;

    /// The types an operation's value of `kind` nests, which a fragment its
    /// lenses spread may not be named.
    fn value_types(&self, kind: OperationKind) -> Vec<Spelled>;

    /// What every lens declares beside its fields, each with what a message
    /// calls it.
    fn lens_members(&self) -> Vec<(&'static str, String)>;
}

/// A name the generated code declares in a scope the document's names
/// share, which the compiler chose: the name, how it meets the others, and
/// what a message calls it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Declared {
    pub name: String,
    pub kind: Kind,
    pub what: String,
}

impl Declared {
    pub fn new(name: impl Into<String>, kind: Kind, what: impl Into<String>) -> Declared {
        Declared {
            name: name.into(),
            kind,
            what: what.into(),
        }
    }

    /// The type `naming` spells for `spelled`.
    pub fn spelled(naming: &dyn Naming, spelled: Spelled) -> Declared {
        Declared::new(
            naming.spelling(spelled),
            Kind::Type,
            naming.description(spelled),
        )
    }
}

/// The names an operation's value declares or spells, in the order its
/// scope takes them: those before its variables and those after.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ValueNames {
    pub before: Vec<Declared>,
    pub after: Vec<Declared>,
}

/// A position a nested type is named in from a document's name: each keeps
/// its own names and writes its own suffix after one of them. A schema
/// enum's and an input object's type at the module's top level are named by
/// `Naming::enum_type` and `Naming::input_type`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Position {
    /// A lens nested in a lens.
    Lens,
    /// An optimistic-response builder nested in a builder.
    Builder,
}

/// A name the generated code declares or spells, whatever a language calls
/// it: a family the module declares once, the runtime's module, the type a
/// declaration is in, and the types every operation nests.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Spelled {
    /// The family of interned types.
    Types,
    /// The family of slots read on object types, and of slots with variables.
    Slots,
    /// The family of constant slots read on an interface or union.
    AbstractSlots,
    /// The family of the sites of spreads with arguments.
    Sites,
    /// The family of the conditions `@include` and `@skip` put on selections.
    Guards,
    /// The runtime's module.
    Runtime,
    /// The type a declaration is in, as its body names it.
    OwnType,
    /// An operation's root lens.
    Data,
    /// A mutation's action.
    Action,
    /// A mutation's optimistic-response builder.
    OptimisticResponse,
}

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

/// Why a scope cannot declare a name.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NameError {
    /// A name the document chose that another declaration takes.
    #[error(transparent)]
    Clash(#[from] Clash),
    /// A name the compiler chose for two declarations: its own fault.
    #[error(transparent)]
    Duplicate(#[from] DuplicateName),
}

/// A name the document chose that its scope declares otherwise, said at
/// the document's name with what the document can change.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{what} clashes with {other}; {remedy}")]
pub struct Clash {
    pub origin: Origin,
    pub what: String,
    pub other: String,
    pub remedy: String,
}

/// A name two declarations the compiler chose would take.
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

/// A name the document chose: where it wrote the name, and what changing
/// it takes, such as "alias the field".
#[derive(Debug, Clone)]
pub struct Written {
    pub origin: Origin,
    pub remedy: &'static str,
}

/// One declaration of a scope.
struct Declaration {
    name: String,
    kind: Kind,
    what: String,
    /// None for a name the compiler chose.
    written: Option<Written>,
}

/// The names a nested type of one kind of scope may not take, and what is
/// written after a name that would be one of them.
pub struct Reserved {
    names: BTreeSet<String>,
    suffix: &'static str,
    /// The language the scope is declared in, for messages.
    language: &'static str,
}

impl Reserved {
    /// For nested types at `position`: the names `naming` keeps there, and
    /// the program's own, which a nested type would hide.
    pub fn new<S: Into<String>>(
        naming: &dyn Naming,
        position: Position,
        program: impl IntoIterator<Item = S>,
    ) -> Reserved {
        let mut names: BTreeSet<String> = naming
            .reserved(position)
            .into_iter()
            .map(|name| name.to_string())
            .collect();
        names.extend(program.into_iter().map(Into::into));
        Reserved {
            names,
            suffix: naming.suffix(position),
            language: naming.language(),
        }
    }

    /// For scopes that name nothing they nest after a document's names.
    pub fn none(naming: &dyn Naming) -> Reserved {
        Reserved {
            names: BTreeSet::new(),
            suffix: "",
            language: naming.language(),
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

/// The declarations of one scope of the generated code: a lens, an operation, a builder or
/// one of the shared enums.
pub struct Scope<'a> {
    /// The scope as the generated code names it, for messages.
    path: String,
    reserved: &'a Reserved,
    declared: Vec<Declaration>,
    errors: Vec<NameError>,
}

impl<'a> Scope<'a> {
    pub fn new(path: impl Into<String>, reserved: &'a Reserved) -> Scope<'a> {
        Scope {
            path: path.into(),
            reserved,
            declared: Vec::new(),
            errors: Vec::new(),
        }
    }

    /// Declares `name`, which the compiler chose, as it is, for `what`; a
    /// name the scope declared already is an error.
    pub fn declare(&mut self, name: &str, kind: Kind, what: impl Into<String>) {
        self.declare_written(name, kind, what, None);
    }

    /// Declares `declared`, which the compiler chose.
    pub fn declare_chosen(&mut self, declared: Declared) {
        self.declare(&declared.name, declared.kind, declared.what);
    }

    /// Declares the type `naming` spells for `spelled`, which the compiler
    /// chose.
    pub fn declare_spelled(&mut self, naming: &dyn Naming, spelled: Spelled) {
        self.declare(
            naming.spelling(spelled),
            Kind::Type,
            naming.description(spelled),
        );
    }

    /// Declares `name` as it is, for `what`; the document chose it when it
    /// is `written`. A name the scope declared already is a clash at the
    /// document's name when the document chose either, else a duplicate.
    pub fn declare_written(
        &mut self,
        name: &str,
        kind: Kind,
        what: impl Into<String>,
        written: Option<Written>,
    ) {
        let declaration = Declaration {
            name: name.to_string(),
            kind,
            what: what.into(),
            written,
        };
        if let Some(first) = self.declared.iter().find(|existing| {
            existing.name == declaration.name && existing.kind.clashes(declaration.kind)
        }) {
            self.errors.push(error(
                &self.path,
                self.reserved.language,
                first,
                &declaration,
            ));
        }
        self.declared.push(declaration);
    }

    /// Whether a declaration of `kind` can take `name`.
    fn is_free(&self, name: &str, kind: Kind) -> bool {
        if kind == Kind::Type && self.reserved.names.contains(name) {
            return false;
        }
        !self
            .declared
            .iter()
            .any(|existing| existing.name == name && existing.kind.clashes(kind))
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
    pub fn finish(self) -> Vec<NameError> {
        self.errors
    }
}

/// The error for `second`, a declaration of a name `first` took already: a
/// clash at the name the document chose, the second's when it chose both,
/// or a duplicate when the compiler chose both.
fn error(scope: &str, language: &str, first: &Declaration, second: &Declaration) -> NameError {
    let (written, at, other) = match (&second.written, &first.written) {
        (Some(written), _) => (written, second, first),
        (None, Some(written)) => (written, first, second),
        (None, None) => {
            return DuplicateName {
                scope: scope.to_string(),
                name: second.name.clone(),
                first: first.what.clone(),
                second: second.what.clone(),
            }
            .into();
        }
    };
    let other = match other.written {
        Some(_) => other.what.clone(),
        None => format!("{} in the generated {language}", other.what),
    };
    Clash {
        origin: written.origin.clone(),
        what: at.what.clone(),
        other,
        remedy: written.remedy.to_string(),
    }
    .into()
}

pub fn capitalize(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// `base`, or the first of `base2`, `base3` and on that is none of `taken`.
pub fn numbered(base: &str, taken: &[&str]) -> String {
    let mut name = base.to_string();
    let mut number = 2;
    while taken.contains(&name.as_str()) {
        name = format!("{base}{number}");
        number += 1;
    }
    name
}

#[cfg(test)]
#[path = "tests/naming_tests.rs"]
mod tests;
