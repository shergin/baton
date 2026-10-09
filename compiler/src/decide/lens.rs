//! What the decide pass settles for a lens: its accessors with their read
//! forms and guards, the surface its kind has, its checks and the lenses
//! nested in it. The lens printer writes it as it is.

use std::collections::BTreeSet;

use super::Guard;
use super::keys::SlotRef;
use crate::naming::{Naming, Spelled};
use crate::pipeline::{ArgumentValuePlan, ConstantPlan, StorageKeyPlan, TypeKind, TypePlan};

/// A lens type: its accessors, the surface its kind has, and the lenses
/// nested in it.
#[derive(Debug, Clone, PartialEq)]
pub struct ReaderPlan {
    pub name: String,
    /// The GraphQL type it reads.
    pub type_name: String,
    pub accessors: Vec<Accessor>,
    /// A `@refetchable` fragment's root: its descriptor and `refetch()`.
    pub refetch: Option<RefetchMembers>,
    /// A `@connection` field's lens: the connection state and pagination.
    pub connection: Option<ConnectionMembers>,
    /// `satisfied`, when a required child can null the lens: one entry per
    /// own member, a check when it has one.
    pub satisfied: Option<Vec<Guarded<Option<SatisfiedCheck>>>>,
    /// `missingRequiredField`, the same checks naming the first field that
    /// is missing: on an operation's root that a required field can bubble
    /// to, whose handle's failure names the field, and on the lenses its
    /// checks recurse into.
    pub reports_missing: bool,
    /// `fieldErrors`, `throwing` and `caught`, under an error policy or for
    /// a catch.
    pub field_errors: Option<Vec<ErrorCheck>>,
    /// `isPresent`, for a fragment spread under `@defer`.
    pub is_present: Option<Vec<Guarded<SlotAccess>>>,
    pub nested: Vec<ReaderPlan>,
}

impl ReaderPlan {
    /// The names the lens and every lens nested in it spell in their bodies
    /// that a member of the lens, or of the type it is nested in, named
    /// like one of them would hide from all of those bodies. The module's
    /// shared enums: `Slots` and `AbstractSlots` where they read a slot,
    /// `Types` where they test a record's type or name one, `Sites`
    /// where they bind a spread's arguments, and `Guards` where they test
    /// an `@include` or `@skip`; and the type's own name, Swift's `Self`,
    /// where they reach a static member of their own, a refetchable
    /// fragment's descriptor or a connection's slots.
    pub fn hideable_names(&self) -> BTreeSet<Spelled> {
        let mut names = BTreeSet::new();
        self.collect_hideable_names(&mut names);
        names
    }

    fn collect_hideable_names(&self, names: &mut BTreeSet<Spelled>) {
        for accessor in &self.accessors {
            match &accessor.read {
                Read::Scalar(read) => {
                    names.insert(read.slot.shared_enum());
                }
                Read::Linked(read) => {
                    names.insert(read.slot.shared_enum());
                    // A non-null link reads its type's placeholder when it
                    // has no record.
                    if matches!(
                        read.form,
                        LinkedForm::Required | LinkedForm::Caught { optional: false }
                    ) {
                        names.insert(Spelled::Types);
                    }
                }
                Read::Spread(read) => {
                    if read.binding.is_some() {
                        names.insert(Spelled::Sites);
                    }
                    if read
                        .guards
                        .iter()
                        .any(|guard| matches!(guard, SpreadGuard::Test(_)))
                    {
                        names.insert(Spelled::Types);
                    }
                }
                Read::Aliased(read) => {
                    if read
                        .guards
                        .iter()
                        .any(|guard| matches!(guard, AliasGuard::Test(_)))
                    {
                        names.insert(Spelled::Types);
                    }
                }
                Read::Condition(_) => {
                    names.insert(Spelled::Types);
                }
            }
        }
        if self.connection.is_some() {
            names.insert(Spelled::Types);
        }
        if self.refetch.is_some() || self.connection.is_some() {
            names.insert(Spelled::OwnType);
        }
        for entry in self.satisfied.iter().flatten() {
            if let Some(
                SatisfiedCheck::HasValue { slot, .. }
                | SatisfiedCheck::Converts { slot, .. }
                | SatisfiedCheck::Linked { slot, .. },
            ) = &entry.item
            {
                names.insert(slot.shared_enum());
            }
        }
        for check in self.field_errors.iter().flatten() {
            match check {
                ErrorCheck::Condition { .. } => {
                    names.insert(Spelled::Types);
                }
                ErrorCheck::Member(lines) => {
                    for line in &lines.item {
                        match line {
                            ErrorLine::Field(slot)
                            | ErrorLine::Linked { slot, .. }
                            | ErrorLine::List { slot, .. }
                            | ErrorLine::Required { slot, .. }
                            | ErrorLine::Converts { slot, .. } => {
                                names.insert(slot.shared_enum());
                            }
                            ErrorLine::Nested(_) => {}
                            ErrorLine::Spread(read) => {
                                if read.binding.is_some() {
                                    names.insert(Spelled::Sites);
                                }
                                if read
                                    .guards
                                    .iter()
                                    .any(|guard| matches!(guard, SpreadGuard::Test(_)))
                                {
                                    names.insert(Spelled::Types);
                                }
                            }
                        }
                    }
                }
            }
        }
        for presence in self.is_present.iter().flatten() {
            names.insert(presence.item.shared_enum());
        }
        if !self.own_guards().is_empty() {
            names.insert(Spelled::Guards);
        }
        for child in &self.nested {
            child.collect_hideable_names(names);
        }
    }

    /// The conditions the lens's own body tests, not those of the lenses
    /// nested in it: on its accessors, its spreads and aliases, and its
    /// checks.
    pub fn own_guards(&self) -> Vec<&Guard> {
        let mut alternatives: Vec<&Vec<Vec<Guard>>> = Vec::new();
        for accessor in &self.accessors {
            alternatives.push(&accessor.guards);
            match &accessor.read {
                Read::Spread(read) => {
                    for guard in &read.guards {
                        if let SpreadGuard::Selects(guards) = guard {
                            alternatives.push(guards);
                        }
                    }
                }
                Read::Aliased(read) => {
                    for guard in &read.guards {
                        if let AliasGuard::Selects(guards) = guard {
                            alternatives.push(guards);
                        }
                    }
                }
                Read::Scalar(_) | Read::Linked(_) | Read::Condition(_) => {}
            }
        }
        for entry in self.satisfied.iter().flatten() {
            alternatives.push(&entry.guards);
        }
        for check in self.field_errors.iter().flatten() {
            match check {
                ErrorCheck::Condition { guards, .. } => alternatives.push(guards),
                ErrorCheck::Member(lines) => alternatives.push(&lines.guards),
            }
        }
        for presence in self.is_present.iter().flatten() {
            alternatives.push(&presence.guards);
        }
        alternatives.into_iter().flatten().flatten().collect()
    }

    /// The fragments the lens and every lens nested in it spread, whose
    /// accessors name them by their types.
    pub fn spread_fragments(&self) -> BTreeSet<&str> {
        let mut fragments = BTreeSet::new();
        self.collect_spread_fragments(&mut fragments);
        fragments
    }

    fn collect_spread_fragments<'a>(&'a self, into: &mut BTreeSet<&'a str>) {
        for accessor in &self.accessors {
            if let Read::Spread(read) = &accessor.read {
                into.insert(read.fragment.as_str());
            }
        }
        for child in &self.nested {
            child.collect_spread_fragments(into);
        }
    }
}

/// Something done only when the conditions on the way to it select: the
/// alternatives of conjunctions of `@include` and `@skip`, none for always.
#[derive(Debug, Clone, PartialEq)]
pub struct Guarded<T> {
    pub guards: Vec<Vec<Guard>>,
    pub item: T,
}

/// A slot as a lens reads it: on an interface or union, the abstract slot
/// taken on the record's type; a key with variables resolved by the anchor's
/// owner.
#[derive(Debug, Clone, PartialEq)]
pub struct SlotAccess {
    pub slot: SlotRef,
    pub on_record_type: bool,
}

impl SlotAccess {
    /// The shared enum the slot is read through: `AbstractSlots` for a
    /// constant key on an interface or union, `Slots` otherwise.
    fn shared_enum(&self) -> Spelled {
        if self.on_record_type && !self.slot.has_variables() {
            Spelled::AbstractSlots
        } else {
            Spelled::Slots
        }
    }

    /// A slot as a lens on `type_name` reads it.
    pub(super) fn of(
        type_name: &str,
        type_is_abstract: bool,
        storage_key: &StorageKeyPlan,
    ) -> SlotAccess {
        SlotAccess {
            slot: SlotRef::new(type_name, storage_key),
            on_record_type: type_is_abstract,
        }
    }
}

/// One accessor: its name, unescaped, the response key it reads, the
/// conditions it reads under, and what it reads.
#[derive(Debug, Clone, PartialEq)]
pub struct Accessor {
    pub name: String,
    /// The key of the response the accessor reads under: a field's alias or
    /// name, an aliased selection's alias; none for a spread or a type
    /// condition, which read the parent's object.
    pub key: Option<String>,
    pub guards: Vec<Vec<Guard>>,
    pub read: Read,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Read {
    Scalar(ScalarRead),
    Linked(LinkedRead),
    Spread(SpreadRead),
    /// An inline fragment under `@alias(as:)`: a nested lens.
    Aliased(AliasedRead),
    /// A type condition some of the parent's types satisfy: an optional
    /// nested lens.
    Condition(ConditionRead),
}

#[derive(Debug, Clone, PartialEq)]
pub struct ScalarRead {
    pub slot: SlotAccess,
    pub shape: ScalarShape,
    pub form: ScalarForm,
    /// The field's response path from the lens's root, dotted, which a
    /// mapped scalar's conversion failure is reported under.
    pub path: String,
}

/// What a scalar field reads as, in no language's terms: each emitter
/// spells the type and picks the reader for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScalarShape {
    pub primitive: Primitive,
    /// A list of the primitive, when the field is one.
    pub list: Option<ListShape>,
}

/// A list's shape beyond its element: whether the schema types the elements
/// non-null, which decides whether an accessor reads `[T]` or `[T?]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ListShape {
    pub non_null: bool,
}

impl ListShape {
    /// The list shape of a type, when it is a list.
    pub fn of(type_: &TypePlan) -> Option<ListShape> {
        type_.element().map(|element| ListShape {
            non_null: element.non_null(),
        })
    }
}

/// What a scalar reads as. The store keeps an id, an enum and a custom
/// scalar as their text; a custom scalar `baton.json` maps reads as the
/// host type it names for the target, converted from the text at the read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Primitive {
    String,
    Int,
    Double,
    Bool,
    /// A custom scalar read as the host type `baton.json` maps it to for the
    /// target.
    Mapped(String),
    /// A schema enum, read as the enum generated for it.
    Enum(String),
}

impl Primitive {
    /// Whether the read converts the stored text, and so can fail.
    pub fn is_mapped(&self) -> bool {
        matches!(self, Primitive::Mapped(_))
    }
}

/// The anchor's reader a scalar field reads through, one per shape: the
/// primitive's, its list, and its list whose elements the schema types
/// nullable; `mapped` and its lists for a scalar converted at the read,
/// `enumValue` and its lists for an enum. Both runtimes name the readers
/// alike, so the name is decided here and each emitter spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReaderKind {
    String,
    Int,
    Double,
    Bool,
    Mapped,
    EnumValue,
    Strings,
    Ints,
    Doubles,
    Bools,
    MappedList,
    EnumValues,
    NullableStrings,
    NullableInts,
    NullableDoubles,
    NullableBools,
    NullableMappedList,
    NullableEnumValues,
}

impl ReaderKind {
    /// The reader's name on the anchor, as both runtimes declare it.
    pub fn name(self) -> &'static str {
        match self {
            ReaderKind::String => "string",
            ReaderKind::Int => "int",
            ReaderKind::Double => "double",
            ReaderKind::Bool => "bool",
            ReaderKind::Mapped => "mapped",
            ReaderKind::EnumValue => "enumValue",
            ReaderKind::Strings => "strings",
            ReaderKind::Ints => "ints",
            ReaderKind::Doubles => "doubles",
            ReaderKind::Bools => "bools",
            ReaderKind::MappedList => "mappedList",
            ReaderKind::EnumValues => "enumValues",
            ReaderKind::NullableStrings => "nullableStrings",
            ReaderKind::NullableInts => "nullableInts",
            ReaderKind::NullableDoubles => "nullableDoubles",
            ReaderKind::NullableBools => "nullableBools",
            ReaderKind::NullableMappedList => "nullableMappedList",
            ReaderKind::NullableEnumValues => "nullableEnumValues",
        }
    }
}

impl ScalarShape {
    /// The shape of a field of the type, a mapped scalar read as the host
    /// type `naming` names for it.
    pub fn of(type_: &TypePlan, naming: &dyn Naming) -> ScalarShape {
        ScalarShape {
            primitive: Self::primitive(type_, naming),
            list: ListShape::of(type_),
        }
    }

    /// The reader the shape reads through.
    pub fn reader(&self) -> ReaderKind {
        match (&self.primitive, self.list.map(|list| list.non_null)) {
            (Primitive::String, None) => ReaderKind::String,
            (Primitive::Int, None) => ReaderKind::Int,
            (Primitive::Double, None) => ReaderKind::Double,
            (Primitive::Bool, None) => ReaderKind::Bool,
            (Primitive::Mapped(_), None) => ReaderKind::Mapped,
            (Primitive::Enum(_), None) => ReaderKind::EnumValue,
            (Primitive::String, Some(true)) => ReaderKind::Strings,
            (Primitive::Int, Some(true)) => ReaderKind::Ints,
            (Primitive::Double, Some(true)) => ReaderKind::Doubles,
            (Primitive::Bool, Some(true)) => ReaderKind::Bools,
            (Primitive::Mapped(_), Some(true)) => ReaderKind::MappedList,
            (Primitive::Enum(_), Some(true)) => ReaderKind::EnumValues,
            (Primitive::String, Some(false)) => ReaderKind::NullableStrings,
            (Primitive::Int, Some(false)) => ReaderKind::NullableInts,
            (Primitive::Double, Some(false)) => ReaderKind::NullableDoubles,
            (Primitive::Bool, Some(false)) => ReaderKind::NullableBools,
            (Primitive::Mapped(_), Some(false)) => ReaderKind::NullableMappedList,
            (Primitive::Enum(_), Some(false)) => ReaderKind::NullableEnumValues,
        }
    }

    pub fn primitive(type_: &TypePlan, naming: &dyn Naming) -> Primitive {
        if type_.is_mapped() {
            return Primitive::Mapped(host_type(type_.base_name(), naming));
        }
        match type_.base_kind() {
            TypeKind::Int => Primitive::Int,
            TypeKind::Float => Primitive::Double,
            TypeKind::Boolean => Primitive::Bool,
            TypeKind::Enum => Primitive::Enum(type_.base_name().to_string()),
            _ => Primitive::String,
        }
    }
}

/// The host type `naming` names for the mapped scalar `scalar`. The
/// lowering marks a scalar mapped only when the configuration names it, and
/// the configuration's validation refuses a mapping without a type for the
/// language.
pub(super) fn host_type(scalar: &str, naming: &dyn Naming) -> String {
    naming
        .host_type(scalar)
        .unwrap_or_else(|| {
            panic!(
                "the configuration names no {} type for `{scalar}`",
                naming.language()
            )
        })
        .to_string()
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScalarForm {
    /// `@catch`: a `Result`, of a non-optional value when the field is
    /// non-null in effect.
    Caught {
        non_null: bool,
    },
    /// `@catch(to: NULL)`: optional whatever the type.
    Nulled,
    /// `@required(action: THROW)`.
    Throwing {
        path: String,
    },
    /// Non-null in effect.
    Required,
    Optional,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LinkedRead {
    pub slot: SlotAccess,
    pub lens: String,
    pub base_type: String,
    /// Whether the nested lens's required children can null it.
    pub bubbles: bool,
    pub form: LinkedForm,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LinkedForm {
    CaughtList { non_null: bool },
    ThrowingList { path: String },
    RequiredList,
    List,
    Caught { optional: bool },
    Throwing { path: String },
    Optional,
    Required,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SpreadRead {
    pub fragment: String,
    /// The fragment's `@argumentDefinitions` bound into its scope.
    pub binding: Option<Binding>,
    /// What must hold for the fragment to be read; the accessor is optional
    /// when anything must.
    pub guards: Vec<SpreadGuard>,
    pub form: SpreadForm,
}

/// A spread's arguments, bound once per owner at its site.
#[derive(Debug, Clone, PartialEq)]
pub struct Binding {
    pub site: String,
    pub arguments: Vec<(String, BoundArgument)>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BoundArgument {
    Passed(ArgumentValuePlan),
    Default(ConstantPlan),
    Null,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SpreadGuard {
    /// The conditions the spread is fetched under.
    Selects(Vec<Vec<Guard>>),
    /// The record's type satisfies the fragment's type condition.
    Test(TypeTest),
    /// The deferred part that carries the fragment has arrived.
    Present,
    /// The fragment's required fields are present.
    Satisfied,
    /// `@catch(to: NULL)`: the fragment has no field errors.
    NoErrors,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpreadForm {
    /// `@catch`: a `Result` of the fragment's field errors.
    Caught,
    /// `@throwOnFieldError` on the fragment.
    Throwing,
    Plain,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AliasedRead {
    pub lens: String,
    pub guards: Vec<AliasGuard>,
    /// `@catch`: a `Result` of the lens's field errors.
    pub caught: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AliasGuard {
    Selects(Vec<Vec<Guard>>),
    Test(TypeTest),
    /// The nested lens's required fields are present.
    Satisfied,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConditionRead {
    pub lens: String,
    pub test: TypeTest,
}

/// How a record is tested against a type condition.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeTest {
    /// It is of the one concrete type that satisfies it.
    Is(String),
    /// Its type is one of the condition's possible types.
    InSet {
        condition: String,
        types: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct RefetchMembers {
    pub operation: String,
    pub variables: Vec<String>,
    pub identifier: Option<String>,
    /// The slot the owner's id is read from, when the query takes one.
    pub identity: Option<SlotAccess>,
    pub first: Option<String>,
    pub after: Option<String>,
    pub last: Option<String>,
    pub before: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConnectionMembers {
    pub connection_type: String,
    pub edge_type: String,
    pub page_info_type: String,
    pub nodes: Option<Nodes>,
    pub load_next: Option<LoadMore>,
    pub load_previous: Option<LoadMore>,
}

/// `nodes`: the lenses it reads, as their accessors named them.
#[derive(Debug, Clone, PartialEq)]
pub struct Nodes {
    pub edges: String,
    pub node: String,
    /// Whether the node's required children can null it.
    pub keep: bool,
}

/// `loadNext` or `loadPrevious` through the fragment's refetch query.
#[derive(Debug, Clone, PartialEq)]
pub struct LoadMore {
    pub operation: String,
    pub owner: String,
    /// The count argument's default, when the fragment defines one.
    pub default_count: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SatisfiedCheck {
    /// The field has a value.
    HasValue {
        slot: SlotAccess,
        path: String,
        log: bool,
    },
    /// The field has a value that converts to the host type a mapped scalar
    /// reads as.
    Converts {
        slot: SlotAccess,
        path: String,
        log: bool,
        host_type: String,
    },
    /// The link has a value and its lens is satisfied.
    Linked {
        slot: SlotAccess,
        lens: String,
        path: String,
        log: bool,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ErrorCheck {
    /// A type condition's lens counts when the record satisfies it.
    Condition {
        guards: Vec<Vec<Guard>>,
        test: TypeTest,
        lens: String,
    },
    /// A member's errors, under its conditions.
    Member(Guarded<Vec<ErrorLine>>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ErrorLine {
    /// The field's own error.
    Field(SlotAccess),
    /// A link's errors and its lens's.
    Linked { slot: SlotAccess, lens: String },
    /// A list's errors and each element lens's.
    List { slot: SlotAccess, lens: String },
    /// A `@required(action: THROW)` field that is null.
    Required { slot: SlotAccess, path: String },
    /// A mapped scalar whose text does not convert.
    Converts {
        slot: SlotAccess,
        path: String,
        host_type: String,
    },
    /// An aliased selection's lens.
    Nested(String),
    /// A spread of an inline fragment inside a value: the value is one
    /// frozen selection, so the errors inside what it spreads are its own,
    /// read in the scope the spread binds and under its guards.
    Spread(SpreadRead),
}
