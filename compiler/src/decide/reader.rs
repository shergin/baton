//! The reader half of the decide pass: one `ReaderPlan` per lens, with every
//! name, nullability, read form, guard and check settled, for the lens
//! printer to write as it is.
//!
//! A lens reads its members: the fields, spreads and inline fragments of its
//! selection, merged per response key, fragment and type condition, each with
//! the `@include` and `@skip` conditions it is fetched under. A member's
//! accessor follows from its directives and the error policy around it:
//! `@required` makes it non-optional and, with `THROW`, throwing; `@catch`
//! makes it a `Result` or reads errors as nil; `@throwOnFieldError` or a
//! surrounding `@catch` types `@semanticNonNull` fields non-null.

use std::collections::{BTreeMap, BTreeSet};

use super::keys::SlotRef;
use super::{Guard, any, written_key};
use crate::names::{Kind, NameError, Reserved, Scope, lower_camel};
use crate::pipeline::{
    ArgumentPlan, ArgumentValuePlan, CatchTarget, ConditionClass, ConnectionPlan, ConstantPlan,
    FragmentPlan, Plan, RefetchPlan, RequiredAction, SelectionPlan, StorageKeyPlan, TypeKind,
    VariablePlan,
};

/// A lens type: its accessors, the surface its kind has, and the lenses
/// nested in it.
#[derive(Debug, Clone, PartialEq)]
pub struct ReaderPlan {
    pub name: String,
    /// The GraphQL type it reads, its `typeName`.
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
    /// The module's shared enums that the lens and every lens nested in it
    /// spell in their bodies: `Slots` and `AbstractSlots` where they read a
    /// slot, `Types` where they test a record's type or name one, and
    /// `Sites` where they bind a spread's arguments. A member of the lens,
    /// or of the type it is nested in, named like one of them hides it from
    /// all of those bodies.
    pub fn shared_enums(&self) -> BTreeSet<&'static str> {
        let mut names = BTreeSet::new();
        self.collect_shared_enums(&mut names);
        names
    }

    fn collect_shared_enums(&self, names: &mut BTreeSet<&'static str>) {
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
                        names.insert("Types");
                    }
                }
                Read::Spread(read) => {
                    if read.binding.is_some() {
                        names.insert("Sites");
                    }
                    if read
                        .guards
                        .iter()
                        .any(|guard| matches!(guard, SpreadGuard::Test(_)))
                    {
                        names.insert("Types");
                    }
                }
                Read::Aliased(read) => {
                    if read
                        .guards
                        .iter()
                        .any(|guard| matches!(guard, AliasGuard::Test(_)))
                    {
                        names.insert("Types");
                    }
                }
                Read::Condition(_) => {
                    names.insert("Types");
                }
            }
        }
        if self.connection.is_some() {
            names.insert("Types");
        }
        for entry in self.satisfied.iter().flatten() {
            if let Some(
                SatisfiedCheck::HasValue { slot, .. } | SatisfiedCheck::Linked { slot, .. },
            ) = &entry.item
            {
                names.insert(slot.shared_enum());
            }
        }
        for check in self.field_errors.iter().flatten() {
            match check {
                ErrorCheck::Condition { .. } => {
                    names.insert("Types");
                }
                ErrorCheck::Member(lines) => {
                    for line in &lines.item {
                        match line {
                            ErrorLine::Field(slot)
                            | ErrorLine::Linked { slot, .. }
                            | ErrorLine::List { slot, .. }
                            | ErrorLine::Required { slot, .. } => {
                                names.insert(slot.shared_enum());
                            }
                            ErrorLine::Nested(_) => {}
                        }
                    }
                }
            }
        }
        for presence in self.is_present.iter().flatten() {
            names.insert(presence.item.shared_enum());
        }
        for child in &self.nested {
            child.collect_shared_enums(names);
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
    fn shared_enum(&self) -> &'static str {
        if self.on_record_type && !self.slot.has_variables() {
            "AbstractSlots"
        } else {
            "Slots"
        }
    }
}

/// One accessor: its name, unescaped, the conditions it reads under, and
/// what it reads.
#[derive(Debug, Clone, PartialEq)]
pub struct Accessor {
    pub name: String,
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
}

/// What a scalar field reads as, in no language's terms: each emitter
/// spells the type and picks the reader for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScalarShape {
    pub primitive: Primitive,
    pub list: bool,
}

/// What the store keeps a scalar as. An id, an enum and a custom scalar are
/// kept as their text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Primitive {
    String,
    Int,
    Double,
    Bool,
}

impl ScalarShape {
    /// The shape of a field of `kind`.
    pub fn of(kind: TypeKind, list: bool) -> ScalarShape {
        let primitive = match kind {
            TypeKind::Int => Primitive::Int,
            TypeKind::Float => Primitive::Double,
            TypeKind::Boolean => Primitive::Bool,
            _ => Primitive::String,
        };
        ScalarShape { primitive, list }
    }
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
    /// An aliased selection's lens.
    Nested(String),
}

/// What a spread accessor needs to know about the fragment it produces.
#[derive(Clone, Copy, Default)]
struct FragmentFlags {
    bubbles: bool,
    throws: bool,
}

/// A fragment's type condition: on an interface or union, the concrete
/// types that satisfy it.
#[derive(Clone, Default)]
struct FragmentCondition {
    is_abstract: bool,
    possible_types: Vec<String>,
}

/// What the lens decisions of one program share, and what they allocate.
pub(super) struct Readers {
    /// Every fragment's `@argumentDefinitions`, for binding spreads.
    fragment_arguments: BTreeMap<String, Vec<VariablePlan>>,
    fragment_flags: BTreeMap<String, FragmentFlags>,
    fragment_conditions: BTreeMap<String, FragmentCondition>,
    /// Fragments spread with `@defer` somewhere: their lenses get `isPresent`.
    deferred_fragments: BTreeSet<String>,
    /// Fragments spread alone under `@catch` somewhere: their lenses get
    /// `fieldErrors`, which the catch reads.
    caught_fragments: BTreeSet<String>,
    /// What a nested lens may not be named: the names a lens spells, and
    /// the program's fragments and operations.
    lens_names: Reserved,
    /// The identifiers of the spreads with arguments, numbered in the order
    /// the lenses are decided.
    pub sites: BTreeSet<String>,
    /// Names some lens would have declared twice.
    pub duplicates: Vec<NameError>,
}

/// What the lenses of one document share: the fragment's `@refetchable` data
/// (reached from a nested connection lens through the fragment's name), and
/// the error policy the types follow.
#[derive(Clone, Copy)]
pub(super) struct Context<'a> {
    owner: &'a str,
    /// The lens as Swift names it from the file's top level, for messages.
    path: &'a str,
    refetch: Option<&'a RefetchPlan>,
    arguments: &'a [VariablePlan],
    /// `@throwOnFieldError` on the document.
    throws: bool,
    /// Inside a `@catch` field or aliased inline fragment.
    within_catch: bool,
    /// In a fragment a `@catch` spreads: its lenses scan for field errors
    /// for the catch to read, while their types keep the fragment's own
    /// policy, as the fragment is one type wherever it is spread.
    caught_spread: bool,
}

impl Context<'_> {
    /// Semantic non-null types apply, and lenses scan for field errors.
    fn handles_errors(&self) -> bool {
        self.throws || self.within_catch
    }

    /// Lenses scan for field errors: under an error policy, or for a catch.
    fn scans_errors(&self) -> bool {
        self.handles_errors() || self.caught_spread
    }
}

/// A nested lens still to be decided: name, GraphQL type, abstractness,
/// selections, the connection it reads when the field is one, whether its
/// required children can null it, and whether it sits inside a `@catch`.
struct Nested {
    name: String,
    type_name: String,
    is_abstract: bool,
    selections: Vec<SelectionPlan>,
    connection: Option<ConnectionPlan>,
    bubbles: bool,
    within_catch: bool,
}

/// What a lens declares besides its members' accessors and lenses.
#[derive(Clone, Copy, Default)]
struct LensFacts {
    /// A `@refetchable` fragment's root: `refetchable`.
    refetchable: bool,
    /// A connection's lens: `connection` and the pagination state.
    connection: bool,
    /// A connection's lens that selects `edges { node }`: `nodes`.
    nodes: bool,
}

impl Readers {
    pub(super) fn new(plan: &Plan) -> Readers {
        let mut deferred_fragments = BTreeSet::new();
        let mut caught_fragments = BTreeSet::new();
        for fragment in &plan.fragments {
            collect_deferred(&fragment.reader, &mut deferred_fragments);
            collect_caught(&fragment.reader, &mut caught_fragments);
        }
        for operation in &plan.operations {
            collect_deferred(&operation.reader, &mut deferred_fragments);
            collect_caught(&operation.reader, &mut caught_fragments);
        }
        Readers {
            fragment_arguments: plan
                .fragments
                .iter()
                .map(|fragment| (fragment.name.clone(), fragment.arguments.clone()))
                .collect(),
            fragment_flags: plan
                .fragments
                .iter()
                .map(|fragment| {
                    (
                        fragment.name.clone(),
                        FragmentFlags {
                            bubbles: fragment.bubbles,
                            throws: fragment.throws_on_field_error,
                        },
                    )
                })
                .collect(),
            fragment_conditions: plan
                .fragments
                .iter()
                .map(|fragment| {
                    (
                        fragment.name.clone(),
                        FragmentCondition {
                            is_abstract: fragment.type_is_abstract,
                            possible_types: fragment.possible_types.clone(),
                        },
                    )
                })
                .collect(),
            deferred_fragments,
            caught_fragments,
            lens_names: Reserved::lenses(
                plan.fragments
                    .iter()
                    .map(|fragment| fragment.name.as_str())
                    .chain(
                        plan.operations
                            .iter()
                            .map(|operation| operation.name.as_str()),
                    ),
            ),
            sites: BTreeSet::new(),
            duplicates: Vec::new(),
        }
    }

    /// A fragment's lens.
    pub(super) fn fragment(&mut self, fragment: &FragmentPlan) -> ReaderPlan {
        let context = Context {
            owner: &fragment.name,
            path: &fragment.name,
            refetch: fragment.refetch.as_ref(),
            arguments: &fragment.arguments,
            throws: fragment.throws_on_field_error,
            within_catch: false,
            caught_spread: self.caught_fragments.contains(&fragment.name),
        };
        self.lens(
            &fragment.name,
            &fragment.type_condition,
            fragment.type_is_abstract,
            &fragment.reader,
            context,
            None,
            true,
            fragment.bubbles,
        )
    }

    /// An operation's root lens, `Data`.
    pub(super) fn operation(&mut self, operation: &crate::pipeline::OperationPlan) -> ReaderPlan {
        let path = format!("{}.Data", operation.name);
        let context = Context {
            owner: &operation.name,
            path: &path,
            refetch: None,
            arguments: &operation.variables,
            throws: operation.throws_on_field_error,
            within_catch: false,
            caught_spread: false,
        };
        let mut data = self.lens(
            "Data",
            &operation.root_type,
            false,
            &operation.reader,
            context,
            None,
            false,
            operation.bubbles,
        );
        if operation.bubbles {
            report_missing(&mut data);
        }
        data
    }

    /// A lens over a selection set on `type_name`. A fragment root with
    /// `@refetchable` gets `refetch()`; a connection field's lens gets the
    /// connection state and, inside a refetchable fragment, `loadNext`; a lens
    /// whose required children can null it gets `satisfied`; a lens under an
    /// error policy gets `fieldErrors`, `throwing` and `caught`; a fragment
    /// spread with `@defer` gets `isPresent`. Its accessors are decided before
    /// the lenses nested in it, so sites are numbered parent first.
    #[allow(clippy::too_many_arguments)]
    fn lens(
        &mut self,
        name: &str,
        type_name: &str,
        type_is_abstract: bool,
        selections: &[SelectionPlan],
        context: Context<'_>,
        connection: Option<&ConnectionPlan>,
        is_fragment_root: bool,
        bubbles: bool,
    ) -> ReaderPlan {
        let mut members = members(selections);
        let facts = LensFacts {
            refetchable: is_fragment_root && context.refetch.is_some(),
            connection: connection.is_some(),
            nodes: connection.is_some() && selects_nodes(selections),
        };
        let duplicates = self.name_lens(context.path, facts, selections, type_name, &mut members);
        self.duplicates.extend(duplicates);
        let mut nested: Vec<Nested> = Vec::new();
        let accessors = self.accessors(type_name, type_is_abstract, &members, &mut nested, context);
        let refetch = context
            .refetch
            .filter(|_| is_fragment_root)
            .map(refetch_members);
        let connection = connection.map(|connection| {
            self.connection_members(connection, type_name, &members, facts.nodes, context)
        });
        let satisfied = bubbles.then(|| satisfied(type_name, type_is_abstract, &members));
        let field_errors = context
            .scans_errors()
            .then(|| field_errors(type_name, type_is_abstract, &members));
        let is_present = (is_fragment_root && self.deferred_fragments.contains(name))
            .then(|| is_present(type_name, type_is_abstract, &members));
        let nested = nested
            .into_iter()
            .map(|child| {
                let path = format!("{}.{}", context.path, child.name);
                let child_context = Context {
                    path: &path,
                    within_catch: context.within_catch || child.within_catch,
                    ..context
                };
                self.lens(
                    &child.name,
                    &child.type_name,
                    child.is_abstract,
                    &child.selections,
                    child_context,
                    child.connection.as_ref(),
                    false,
                    child.bubbles,
                )
            })
            .collect();
        let lens = ReaderPlan {
            name: name.to_string(),
            type_name: type_name.to_string(),
            accessors,
            refetch,
            connection,
            satisfied,
            reports_missing: false,
            field_errors,
            is_present,
            nested,
        };
        self.duplicates
            .extend(hidden_enums(context.path, &lens, &members));
        lens
    }

    /// The connection surface of a lens over a `@connection` field: Relay's
    /// state read from the store, `nodes`, and pagination when the fragment is
    /// refetchable.
    fn connection_members(
        &self,
        connection: &ConnectionPlan,
        type_name: &str,
        members: &[Member],
        nodes: bool,
        context: Context<'_>,
    ) -> ConnectionMembers {
        let nodes = if nodes {
            self.node_lens(members, context)
        } else {
            None
        };
        let default_count = |variable: &Option<String>| -> Option<i64> {
            variable
                .as_ref()
                .and_then(|name| context.arguments.iter().find(|a| &a.name == name))
                .and_then(|definition| match &definition.default_value {
                    Some(ConstantPlan::Int(count)) => Some(*count),
                    _ => None,
                })
        };
        let load = |refetch: &RefetchPlan, count: &Option<String>, cursor: &Option<String>| {
            (count.is_some() && cursor.is_some()).then(|| LoadMore {
                operation: refetch.operation.clone(),
                owner: context.owner.to_string(),
                default_count: default_count(count),
            })
        };
        let pagination = context
            .refetch
            .and_then(|refetch| Some((refetch, refetch.connection.as_ref()?)));
        let (load_next, load_previous) = match pagination {
            Some((refetch, pagination)) => (
                load(refetch, &pagination.first, &pagination.after),
                load(refetch, &pagination.last, &pagination.before),
            ),
            None => (None, None),
        };
        ConnectionMembers {
            connection_type: type_name.to_string(),
            edge_type: connection.edge_type.clone(),
            page_info_type: connection.page_info_type.clone(),
            nodes,
            load_next,
            load_previous,
        }
    }

    /// The lenses `nodes` reads, the edges' and the node's, as their
    /// accessors named them, and whether the node's required children can
    /// null it: when the connection selects `edges { node }` at its own
    /// level.
    fn node_lens(&self, members: &[Member], context: Context<'_>) -> Option<Nodes> {
        let edges = members.iter().find(|member| {
            matches!(&member.selection, SelectionPlan::Linked { name, alias: None, .. } if name == "edges")
        })?;
        let SelectionPlan::Linked {
            base_type,
            selections,
            ..
        } = &edges.selection
        else {
            unreachable!("the edges member is a linked field");
        };
        // The edges' lens names its members when it is decided; naming them
        // here the same way finds the name its node takes.
        let mut edge_members = self::members(selections);
        let path = format!("{}.{}", context.path, edges.lens_name());
        let _ = self.name_lens(
            &path,
            LensFacts::default(),
            selections,
            base_type,
            &mut edge_members,
        );
        let node = edge_members.into_iter().find(|member| {
            matches!(&member.selection, SelectionPlan::Linked { name, alias: None, .. } if name == "node")
        })?;
        let SelectionPlan::Linked { bubbles, .. } = &node.selection else {
            unreachable!("the node member is a linked field");
        };
        Some(Nodes {
            edges: edges.lens_name().to_string(),
            node: node.lens_name().to_string(),
            keep: *bubbles,
        })
    }

    /// Names a lens's members, and returns the names it would declare
    /// twice. First what every lens of its kind declares, then the accessors
    /// as the document spells them, the spreads' derived accessors around
    /// those, the nested lenses of fields and aliased selections, and last
    /// each type condition's accessor and lens under one number, so a name
    /// the document chose is never the one that moves.
    fn name_lens(
        &self,
        path: &str,
        facts: LensFacts,
        selections: &[SelectionPlan],
        type_name: &str,
        members: &mut [Member],
    ) -> Vec<NameError> {
        let mut scope = Scope::new(path, &self.lens_names);
        scope.declare("anchor", Kind::Instance, "the `anchor` every lens has");
        scope.declare("recordID", Kind::Instance, "the `recordID` every lens has");
        scope.declare("typeName", Kind::Static, "the type name every lens has");
        if facts.refetchable {
            scope.declare(
                "refetchable",
                Kind::Static,
                "the fragment's refetch descriptor",
            );
        }
        if facts.connection {
            scope.declare("connection", Kind::Static, "the connection's slots");
            if facts.nodes {
                scope.declare("nodes", Kind::Instance, "the connection's `nodes`");
            }
            for name in [
                "hasNext",
                "hasPrevious",
                "isLoadingNext",
                "isLoadingPrevious",
                "connectionID",
            ] {
                scope.declare(name, Kind::Instance, format!("the connection's `{name}`"));
            }
        }
        for member in members.iter_mut() {
            if let Some((name, what)) = written_accessor(&member.selection) {
                scope.declare_written(&name, Kind::Instance, what, written_key(&member.selection));
                member.accessor = Some(name);
            }
        }
        let preferred = spread_accessor_names(selections, type_name);
        for member in members.iter_mut() {
            let Some(fragment) = derived_spread(&member.selection) else {
                continue;
            };
            let full = lower_camel(fragment);
            let mut candidates = vec![preferred.get(fragment).cloned().unwrap_or(full.clone())];
            if candidates[0] != full {
                candidates.push(full);
            }
            member.accessor = Some(scope.member(
                &candidates,
                Kind::Instance,
                format!("the spread of `{fragment}`"),
            ));
        }
        for member in members.iter_mut() {
            let property = match &member.selection {
                SelectionPlan::Linked { name, alias, .. } => alias.as_deref().unwrap_or(name),
                SelectionPlan::Inline {
                    alias: Some(alias),
                    selections: child,
                    ..
                } if !matches!(child.as_slice(), [SelectionPlan::Spread { .. }]) => alias,
                _ => continue,
            };
            let lens = scope.nested_type(property, format!("the lens of `{property}`"));
            member.lens = Some(lens);
        }
        for member in members.iter_mut() {
            let SelectionPlan::Inline {
                type_condition: Some(condition),
                condition_class: Some(ConditionClass::Concrete(_) | ConditionClass::Set),
                alias: None,
                deferred,
                selections: child,
                ..
            } = &member.selection
            else {
                continue;
            };
            if deferred.is_some() && matches!(child.as_slice(), [SelectionPlan::Spread { .. }]) {
                continue;
            }
            let (accessor, lens) = scope.member_and_type(
                &format!("as{condition}"),
                &format!("As{condition}"),
                format!("the type condition `... on {condition}`"),
            );
            member.accessor = Some(accessor);
            member.lens = Some(lens);
        }
        scope.finish()
    }

    /// The accessors of a lens's members, in order, and the nested lenses
    /// they read.
    fn accessors(
        &mut self,
        type_name: &str,
        type_is_abstract: bool,
        members: &[Member],
        nested: &mut Vec<Nested>,
        context: Context<'_>,
    ) -> Vec<Accessor> {
        let mut accessors = Vec::new();
        for member in members {
            let read = match &member.selection {
                SelectionPlan::Scalar {
                    name,
                    base_kind,
                    non_null,
                    semantic_non_null,
                    list,
                    storage_key,
                    required,
                    catch,
                    ..
                } => {
                    if name == "__typename" {
                        continue;
                    }
                    let non_null = *non_null
                        || required.is_some()
                        || (*semantic_non_null && context.handles_errors());
                    let form = match (
                        catch.as_ref().map(|catch| catch.to),
                        required.as_ref().map(|required| required.action),
                    ) {
                        (Some(CatchTarget::Result), _) => ScalarForm::Caught { non_null },
                        (Some(CatchTarget::Null), _) => ScalarForm::Nulled,
                        (_, Some(RequiredAction::Throw)) => ScalarForm::Throwing {
                            path: required_path(required),
                        },
                        _ if non_null => ScalarForm::Required,
                        _ => ScalarForm::Optional,
                    };
                    Read::Scalar(ScalarRead {
                        slot: slot_access(type_name, type_is_abstract, storage_key),
                        shape: ScalarShape::of(*base_kind, *list),
                        form,
                    })
                }
                SelectionPlan::Linked {
                    base_type,
                    non_null,
                    semantic_non_null,
                    plural,
                    is_abstract,
                    storage_key,
                    connection,
                    required,
                    catch,
                    bubbles,
                    selections: child,
                    ..
                } => {
                    let lens = member.lens_name().to_string();
                    let non_null = *non_null
                        || required.is_some()
                        || (*semantic_non_null && context.handles_errors());
                    let catch_to = catch.as_ref().map(|catch| catch.to);
                    let required_action = required.as_ref().map(|required| required.action);
                    let path = required_path(required);
                    let form = if *plural {
                        match (catch_to, required_action) {
                            (Some(CatchTarget::Result), _) => LinkedForm::CaughtList { non_null },
                            (_, Some(RequiredAction::Throw)) => LinkedForm::ThrowingList { path },
                            _ if non_null && catch_to != Some(CatchTarget::Null) => {
                                LinkedForm::RequiredList
                            }
                            _ => LinkedForm::List,
                        }
                    } else {
                        // A link whose children can bubble reads as optional
                        // unless it is itself required, when its parent has
                        // checked it.
                        let optional = !non_null
                            || (*bubbles && required.is_none())
                            || catch_to == Some(CatchTarget::Null);
                        match (catch_to, required_action) {
                            (Some(CatchTarget::Result), _) => LinkedForm::Caught { optional },
                            (_, Some(RequiredAction::Throw)) => LinkedForm::Throwing { path },
                            _ if optional => LinkedForm::Optional,
                            _ => LinkedForm::Required,
                        }
                    };
                    nested.push(Nested {
                        name: lens.clone(),
                        type_name: base_type.clone(),
                        is_abstract: *is_abstract,
                        selections: child.clone(),
                        connection: connection.clone(),
                        bubbles: *bubbles,
                        within_catch: catch.is_some(),
                    });
                    Read::Linked(LinkedRead {
                        slot: slot_access(type_name, type_is_abstract, storage_key),
                        lens,
                        base_type: base_type.clone(),
                        bubbles: *bubbles,
                        form,
                    })
                }
                SelectionPlan::Spread {
                    fragment,
                    type_condition,
                    arguments,
                } => Read::Spread(self.spread(
                    context.owner,
                    member,
                    fragment,
                    arguments,
                    type_condition,
                    false,
                    None,
                    type_name,
                    type_is_abstract,
                )),
                SelectionPlan::Inline {
                    type_condition,
                    condition_class,
                    alias,
                    deferred,
                    catch,
                    bubbles,
                    selections: child,
                    ..
                } => {
                    if let [
                        SelectionPlan::Spread {
                            fragment,
                            type_condition: spread_condition,
                            arguments,
                        },
                    ] = child.as_slice()
                        && (alias.is_some() || deferred.is_some())
                    {
                        // `@alias(as:)` or `@defer` around one spread: the spread
                        // keeps its lens, under the alias when given.
                        Read::Spread(self.spread(
                            context.owner,
                            member,
                            fragment,
                            arguments,
                            spread_condition,
                            deferred.is_some(),
                            catch.as_ref().map(|catch| catch.to),
                            type_name,
                            type_is_abstract,
                        ))
                    } else if alias.is_some() {
                        // `@alias(as:)` on other selections: a nested lens.
                        let lens = member.lens_name().to_string();
                        let condition_lens =
                            condition_lens(type_condition, condition_class, member);
                        let (lens_type, lens_abstract) = match &condition_lens {
                            Some((lens_type, lens_abstract, _)) => {
                                (lens_type.clone(), *lens_abstract)
                            }
                            None => (type_name.to_string(), type_is_abstract),
                        };
                        let mut guards = Vec::new();
                        if !member.guards.is_empty() {
                            guards.push(AliasGuard::Selects(member.guards.clone()));
                        }
                        if let Some((_, _, test)) = condition_lens {
                            guards.push(AliasGuard::Test(test));
                        }
                        if *bubbles {
                            guards.push(AliasGuard::Satisfied);
                        }
                        nested.push(Nested {
                            name: lens.clone(),
                            type_name: lens_type,
                            is_abstract: lens_abstract,
                            selections: child.clone(),
                            connection: None,
                            bubbles: *bubbles,
                            within_catch: catch.is_some(),
                        });
                        Read::Aliased(AliasedRead {
                            lens,
                            guards,
                            caught: catch
                                .as_ref()
                                .is_some_and(|catch| catch.to == CatchTarget::Result),
                        })
                    } else if let Some((lens_type, lens_abstract, test)) =
                        condition_lens(type_condition, condition_class, member)
                    {
                        let lens = member.lens_name().to_string();
                        nested.push(Nested {
                            name: lens.clone(),
                            type_name: lens_type,
                            is_abstract: lens_abstract,
                            selections: child.clone(),
                            connection: None,
                            bubbles: false,
                            within_catch: false,
                        });
                        Read::Condition(ConditionRead { lens, test })
                    } else {
                        // `members` folds every other inline fragment into the lens.
                        continue;
                    }
                }
                SelectionPlan::Condition { .. } => {
                    unreachable!("members turns conditions into guards")
                }
            };
            accessors.push(Accessor {
                name: member.accessor_name().to_string(),
                guards: member.guards.clone(),
                read,
            });
        }
        accessors
    }

    /// A spread's accessor. The child's scope is the parent's variables with
    /// the fragment's `@argumentDefinitions` bound: the passed argument, else
    /// the default, else null. The accessor is optional when the type may not
    /// match, the spread is deferred, or the fragment's required fields can
    /// null it; it throws when the fragment has `@throwOnFieldError`; it is a
    /// `Result` of the fragment's field errors under `@catch`, and nil when
    /// the fragment has any under `@catch(to: NULL)`.
    #[allow(clippy::too_many_arguments)]
    fn spread(
        &mut self,
        owner: &str,
        member: &Member,
        fragment: &str,
        arguments: &[ArgumentPlan],
        type_condition: &str,
        deferred: bool,
        catch: Option<CatchTarget>,
        type_name: &str,
        type_is_abstract: bool,
    ) -> SpreadRead {
        let flags = self
            .fragment_flags
            .get(fragment)
            .copied()
            .unwrap_or_default();
        let definitions = self
            .fragment_arguments
            .get(fragment)
            .cloned()
            .unwrap_or_default();
        let binding = if definitions.is_empty() {
            None
        } else {
            let arguments = definitions
                .iter()
                .map(|definition| {
                    let value = arguments
                        .iter()
                        .find(|argument| argument.name == definition.name)
                        .map(|argument| BoundArgument::Passed(argument.value.clone()))
                        .or_else(|| definition.default_value.clone().map(BoundArgument::Default))
                        .unwrap_or(BoundArgument::Null);
                    (definition.name.clone(), value)
                })
                .collect();
            Some(Binding {
                site: self.site(owner, member.accessor_name()),
                arguments,
            })
        };
        let mut guards = Vec::new();
        if !member.guards.is_empty() {
            guards.push(SpreadGuard::Selects(member.guards.clone()));
        }
        if type_is_abstract && type_condition != type_name {
            // A condition on an interface or union holds for any of the
            // types that satisfy it; one on an object type for that type.
            let condition = self
                .fragment_conditions
                .get(fragment)
                .cloned()
                .unwrap_or_default();
            guards.push(SpreadGuard::Test(if condition.is_abstract {
                TypeTest::InSet {
                    condition: type_condition.to_string(),
                    types: condition.possible_types,
                }
            } else {
                TypeTest::Is(type_condition.to_string())
            }));
        }
        if deferred {
            guards.push(SpreadGuard::Present);
        }
        if flags.bubbles {
            guards.push(SpreadGuard::Satisfied);
        }
        // `to: NULL` reads a fragment with field errors as nil, and then
        // never throws them.
        let nulls = catch == Some(CatchTarget::Null);
        if nulls {
            guards.push(SpreadGuard::NoErrors);
        }
        let form = if catch == Some(CatchTarget::Result) {
            SpreadForm::Caught
        } else if flags.throws && !nulls {
            SpreadForm::Throwing
        } else {
            SpreadForm::Plain
        };
        SpreadRead {
            fragment: fragment.to_string(),
            binding,
            guards,
            form,
        }
    }

    /// A new site for a spread with arguments, named by its lens's document
    /// and accessor, and numbered when the document has two of the name.
    fn site(&mut self, owner: &str, accessor: &str) -> String {
        let base = format!("{owner}_{accessor}");
        let mut name = base.clone();
        let mut count = 1;
        while self.sites.contains(&name) {
            count += 1;
            name = format!("{base}_{count}");
        }
        self.sites.insert(name.clone());
        name
    }
}

/// The `@refetchable` surface of a fragment lens: the descriptor of its
/// query and `refetch()`.
fn refetch_members(refetch: &RefetchPlan) -> RefetchMembers {
    let pagination = refetch.connection.as_ref();
    RefetchMembers {
        operation: refetch.operation.clone(),
        variables: refetch.variables.clone(),
        identifier: refetch.identifier.clone(),
        first: pagination.and_then(|pagination| pagination.first.clone()),
        after: pagination.and_then(|pagination| pagination.after.clone()),
        last: pagination.and_then(|pagination| pagination.last.clone()),
        before: pagination.and_then(|pagination| pagination.before.clone()),
    }
}

/// Marks `lens` to report the path of its first missing `@required` field,
/// and the lenses its `satisfied` recurses into, which report the paths
/// below it.
fn report_missing(lens: &mut ReaderPlan) {
    lens.reports_missing = true;
    let targets: Vec<String> = lens
        .satisfied
        .iter()
        .flatten()
        .filter_map(|entry| match &entry.item {
            Some(SatisfiedCheck::Linked { lens: target, .. }) => Some(target.clone()),
            _ => None,
        })
        .collect();
    for child in &mut lens.nested {
        if targets.contains(&child.name) {
            report_missing(child);
        }
    }
}

/// `satisfied`: whether every `@required` field (NONE or LOG) of the
/// selection is present, recursing into required links. Relay nulls the
/// enclosing object otherwise; here the parent's accessor returns nil. A
/// field a condition left out cannot null the lens.
fn satisfied(
    type_name: &str,
    type_is_abstract: bool,
    members: &[Member],
) -> Vec<Guarded<Option<SatisfiedCheck>>> {
    own_members(members)
        .map(|member| {
            let check = match &member.selection {
                SelectionPlan::Scalar {
                    required: Some(required),
                    storage_key,
                    ..
                } if required.action != RequiredAction::Throw => Some(SatisfiedCheck::HasValue {
                    slot: slot_access(type_name, type_is_abstract, storage_key),
                    path: required.path.clone(),
                    log: required.action == RequiredAction::Log,
                }),
                SelectionPlan::Linked {
                    required: Some(required),
                    storage_key,
                    plural,
                    bubbles,
                    ..
                } if required.action != RequiredAction::Throw => {
                    let slot = slot_access(type_name, type_is_abstract, storage_key);
                    let path = required.path.clone();
                    let log = required.action == RequiredAction::Log;
                    if *plural || !*bubbles {
                        Some(SatisfiedCheck::HasValue { slot, path, log })
                    } else {
                        Some(SatisfiedCheck::Linked {
                            slot,
                            lens: member.lens_name().to_string(),
                            path,
                            log,
                        })
                    }
                }
                _ => None,
            };
            Guarded {
                guards: member.guards.clone(),
                item: check,
            }
        })
        .collect()
}

/// `fieldErrors`: the field errors in this selection, excluding fields
/// caught by their own `@catch`, plus the `@required(action: THROW)` fields
/// that are null. A field a condition left out has no error to collect.
fn field_errors(type_name: &str, type_is_abstract: bool, members: &[Member]) -> Vec<ErrorCheck> {
    let mut checks = Vec::new();
    for member in members {
        // A type condition's nested lens: its errors count when the record
        // satisfies the condition.
        if let SelectionPlan::Inline {
            alias: None,
            type_condition,
            condition_class,
            ..
        } = &member.selection
        {
            if let Some((_, _, test)) = condition_lens(type_condition, condition_class, member) {
                checks.push(ErrorCheck::Condition {
                    guards: member.guards.clone(),
                    test,
                    lens: member.lens_name().to_string(),
                });
            }
            continue;
        }
        if !collects_errors(&member.selection) {
            continue;
        }
        let mut lines = Vec::new();
        match &member.selection {
            SelectionPlan::Scalar {
                storage_key,
                required,
                ..
            } => {
                let slot = slot_access(type_name, type_is_abstract, storage_key);
                lines.push(ErrorLine::Field(slot.clone()));
                if let Some(required) = required
                    && required.action == RequiredAction::Throw
                {
                    lines.push(ErrorLine::Required {
                        slot,
                        path: required.path.clone(),
                    });
                }
            }
            SelectionPlan::Linked {
                storage_key,
                required,
                plural,
                ..
            } => {
                let slot = slot_access(type_name, type_is_abstract, storage_key);
                let lens = member.lens_name().to_string();
                lines.push(if *plural {
                    ErrorLine::List {
                        slot: slot.clone(),
                        lens,
                    }
                } else {
                    ErrorLine::Linked {
                        slot: slot.clone(),
                        lens,
                    }
                });
                if let Some(required) = required
                    && required.action == RequiredAction::Throw
                {
                    lines.push(ErrorLine::Required {
                        slot,
                        path: required.path.clone(),
                    });
                }
            }
            SelectionPlan::Inline { alias: Some(_), .. } => {
                lines.push(ErrorLine::Nested(member.lens_name().to_string()));
            }
            _ => {}
        }
        checks.push(ErrorCheck::Member(Guarded {
            guards: member.guards.clone(),
            item: lines,
        }));
    }
    checks
}

/// `isPresent`: whether the fragment's own fields have arrived, for a
/// spread under `@defer`. A field a condition left out is not waited for.
fn is_present(
    type_name: &str,
    type_is_abstract: bool,
    members: &[Member],
) -> Vec<Guarded<SlotAccess>> {
    own_members(members)
        .filter_map(|member| {
            let storage_key = match &member.selection {
                SelectionPlan::Scalar {
                    name, storage_key, ..
                } if name != "__typename" => storage_key,
                SelectionPlan::Linked { storage_key, .. } => storage_key,
                _ => return None,
            };
            Some(Guarded {
                guards: member.guards.clone(),
                item: slot_access(type_name, type_is_abstract, storage_key),
            })
        })
        .collect()
}

/// A type condition some of the parent's types satisfy reads as an
/// optional nested lens: on the one type that can, or through the abstract
/// type's keys when several can. The lens's type and whether it is
/// abstract, and the test of the record.
fn condition_lens(
    type_condition: &Option<String>,
    condition_class: &Option<ConditionClass>,
    member: &Member,
) -> Option<(String, bool, TypeTest)> {
    match (type_condition, condition_class) {
        (Some(_), Some(ConditionClass::Concrete(concrete))) => {
            Some((concrete.clone(), false, TypeTest::Is(concrete.clone())))
        }
        (Some(condition), Some(ConditionClass::Set)) => {
            let SelectionPlan::Inline {
                condition_types: Some(types),
                ..
            } = &member.selection
            else {
                unreachable!("a set condition has its possible types");
            };
            Some((
                condition.clone(),
                true,
                TypeTest::InSet {
                    condition: condition.clone(),
                    types: types.clone(),
                },
            ))
        }
        _ => None,
    }
}

/// A slot as a lens on `type_name` reads it.
fn slot_access(
    type_name: &str,
    type_is_abstract: bool,
    storage_key: &StorageKeyPlan,
) -> SlotAccess {
    SlotAccess {
        slot: SlotRef::new(type_name, storage_key),
        on_record_type: type_is_abstract,
    }
}

fn required_path(required: &Option<crate::pipeline::RequiredPlan>) -> String {
    required
        .as_ref()
        .map(|required| required.path.clone())
        .unwrap_or_default()
}

/// The fragments spread under `@defer`, anywhere in a selection tree.
fn collect_deferred(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Inline {
                deferred,
                selections: child,
                ..
            } => {
                if deferred.is_some() {
                    for inner in child {
                        if let SelectionPlan::Spread { fragment, .. } = inner {
                            into.insert(fragment.clone());
                        }
                    }
                }
                collect_deferred(child, into);
            }
            SelectionPlan::Linked {
                selections: child, ..
            }
            | SelectionPlan::Condition {
                selections: child, ..
            } => collect_deferred(child, into),
            _ => {}
        }
    }
}

/// The fragments spread alone under an aliased or deferred `@catch`,
/// anywhere in a selection tree: the spread's accessor reads their field
/// errors.
fn collect_caught(selections: &[SelectionPlan], into: &mut BTreeSet<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Inline {
                alias,
                deferred,
                catch,
                selections: child,
                ..
            } => {
                if let (Some(_), [SelectionPlan::Spread { fragment, .. }]) =
                    (catch, child.as_slice())
                    && (alias.is_some() || deferred.is_some())
                {
                    into.insert(fragment.clone());
                }
                collect_caught(child, into);
            }
            SelectionPlan::Linked {
                selections: child, ..
            }
            | SelectionPlan::Condition {
                selections: child, ..
            } => collect_caught(child, into),
            _ => {}
        }
    }
}

/// The clashes of a lens's accessors with the shared enums its code spells:
/// an accessor the document named `Slots`, say, would hide the enum from
/// every body of the lens and of the lenses nested in it.
fn hidden_enums(path: &str, lens: &ReaderPlan, members: &[Member]) -> Vec<NameError> {
    let spelled = lens.shared_enums();
    let none = Reserved::none();
    let mut scope = Scope::new(path, &none);
    for name in &spelled {
        scope.declare(name, Kind::Type, format!("the shared enum `{name}`"));
    }
    for member in members {
        let Some((name, what)) = written_accessor(&member.selection) else {
            continue;
        };
        if spelled.contains(name.as_str()) {
            scope.declare_written(&name, Kind::Instance, what, written_key(&member.selection));
        }
    }
    scope.finish()
}

/// The accessor a member's document spells, and what it is, for messages: a
/// field's response key, or an inline fragment's alias.
fn written_accessor(selection: &SelectionPlan) -> Option<(String, String)> {
    match selection {
        SelectionPlan::Scalar { name, .. } if name == "__typename" => None,
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            let key = alias.as_deref().unwrap_or(name);
            Some((key.to_string(), format!("the field `{key}`")))
        }
        SelectionPlan::Inline {
            alias: Some(alias), ..
        } => Some((alias.clone(), format!("the selection aliased `{alias}`"))),
        _ => None,
    }
}

/// The fragment of a spread whose accessor the compiler names: a spread, or
/// one deferred without an alias.
fn derived_spread(selection: &SelectionPlan) -> Option<&str> {
    match selection {
        SelectionPlan::Spread { fragment, .. } => Some(fragment),
        SelectionPlan::Inline {
            alias: None,
            deferred: Some(_),
            selections,
            ..
        } => match selections.as_slice() {
            [SelectionPlan::Spread { fragment, .. }] => Some(fragment),
            _ => None,
        },
        _ => None,
    }
}

/// One thing a lens reads, after its occurrences merged: a field, a spread
/// or an inline fragment, and the `@include` and `@skip` conditions it is
/// fetched under (empty: always).
struct Member {
    /// The first occurrence; a linked field's or an inline fragment's
    /// selections are those of every occurrence.
    selection: SelectionPlan,
    guards: Vec<Vec<Guard>>,
    /// The accessor's name, unescaped, set by `name_lens` for every member
    /// that has one.
    accessor: Option<String>,
    /// The nested lens a linked field, an aliased inline fragment or a type
    /// condition reads as, set by `name_lens`: the accessors and the checks
    /// that follow take it rather than deriving it again.
    lens: Option<String>,
}

impl Member {
    fn accessor_name(&self) -> &str {
        self.accessor
            .as_deref()
            .expect("`name_lens` names the accessor of every member that has one")
    }

    fn lens_name(&self) -> &str {
        self.lens
            .as_deref()
            .expect("`name_lens` names the nested lens of every member that has one")
    }
}

/// A selection at a lens's own level and the conditions on the way to it.
type Occurrence = (SelectionPlan, Vec<Guard>);

/// What a lens over `selections` reads, each thing once: conditions become
/// guards, an inline fragment every type satisfies folds into the lens, and
/// a field per response key, a spread per fragment and an inline fragment
/// per type condition merge their occurrences. A merged field's children
/// keep the conditions of the occurrence that selected them, when the
/// occurrences' conditions differ.
fn members(selections: &[SelectionPlan]) -> Vec<Member> {
    let mut occurrences: Vec<Occurrence> = Vec::new();
    gather(selections, &[], &mut occurrences);
    let mut groups: Vec<(Option<String>, Vec<Occurrence>)> = Vec::new();
    for (selection, guard) in occurrences {
        let identity = member_identity(&selection);
        match groups
            .iter_mut()
            .find(|(existing, _)| identity.is_some() && *existing == identity)
        {
            Some((_, members)) => members.push((selection, guard)),
            None => groups.push((identity, vec![(selection, guard)])),
        }
    }
    groups
        .into_iter()
        .map(|(_, occurrences)| {
            let guards = any(occurrences.iter().map(|(_, guard)| guard.clone()).collect());
            let differ = occurrences
                .iter()
                .any(|(_, guard)| *guard != occurrences[0].1);
            let mut selection = occurrences[0].0.clone();
            if let SelectionPlan::Linked { selections, .. }
            | SelectionPlan::Inline { selections, .. } = &mut selection
            {
                *selections = occurrences
                    .iter()
                    .flat_map(|(occurrence, guard)| {
                        let children = match occurrence {
                            SelectionPlan::Linked { selections, .. }
                            | SelectionPlan::Inline { selections, .. } => selections.clone(),
                            _ => Vec::new(),
                        };
                        if differ {
                            under(guard, children)
                        } else {
                            children
                        }
                    })
                    .collect();
            }
            Member {
                selection,
                guards,
                accessor: None,
                lens: None,
            }
        })
        .collect()
}

/// The selections at a lens's own level, each with the conditions on the
/// way to it: through conditions, and through inline fragments that fold
/// into the lens.
fn gather(
    selections: &[SelectionPlan],
    guard: &[Guard],
    into: &mut Vec<(SelectionPlan, Vec<Guard>)>,
) {
    for selection in selections {
        match selection {
            SelectionPlan::Condition {
                variable,
                passing,
                selections: child,
            } => {
                let mut inner = guard.to_vec();
                if let Some(variable) = variable {
                    inner.push(Guard {
                        variable: variable.clone(),
                        passing: *passing,
                    });
                }
                gather(child, &inner, into);
            }
            SelectionPlan::Inline {
                condition_class,
                alias: None,
                deferred,
                selections: child,
                ..
            } if !(deferred.is_some()
                && matches!(child.as_slice(), [SelectionPlan::Spread { .. }]))
                && matches!(condition_class, None | Some(ConditionClass::Always)) =>
            {
                gather(child, guard, into)
            }
            other => into.push((other.clone(), guard.to_vec())),
        }
    }
}

/// What makes two occurrences one member; `None` for one that stays apart.
fn member_identity(selection: &SelectionPlan) -> Option<String> {
    match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            Some(format!("field {}", alias.as_deref().unwrap_or(name)))
        }
        SelectionPlan::Spread { fragment, .. } => Some(format!("spread {fragment}")),
        SelectionPlan::Inline {
            type_condition: Some(condition),
            alias: None,
            deferred: None,
            ..
        } => Some(format!("on {condition}")),
        _ => None,
    }
}

/// `selections` under a conjunction of conditions, as nested conditions.
fn under(guard: &[Guard], selections: Vec<SelectionPlan>) -> Vec<SelectionPlan> {
    guard
        .iter()
        .rev()
        .fold(selections, |selections, condition| {
            vec![SelectionPlan::Condition {
                variable: Some(condition.variable.clone()),
                passing: condition.passing,
                selections,
            }]
        })
}

/// Whether a member has field errors its lens collects. `__typename` has
/// none, a `@catch` field keeps its own, and an aliased spread is a masking
/// boundary with its own policy; an aliased selection set is a nested lens
/// whose errors are this lens's.
fn collects_errors(selection: &SelectionPlan) -> bool {
    match selection {
        SelectionPlan::Scalar { name, catch, .. } => name != "__typename" && catch.is_none(),
        SelectionPlan::Linked { catch, .. } => catch.is_none(),
        SelectionPlan::Inline {
            alias: Some(_),
            catch: None,
            selections,
            ..
        } => !matches!(selections.as_slice(), [SelectionPlan::Spread { .. }]),
        _ => false,
    }
}

/// The members a lens's own checks cover: its fields, and inline fragments
/// it names with an alias. Spreads and lenses on other types check
/// themselves.
fn own_members(members: &[Member]) -> impl Iterator<Item = &Member> {
    members.iter().filter(|member| match &member.selection {
        SelectionPlan::Scalar { .. } | SelectionPlan::Linked { .. } => true,
        SelectionPlan::Inline { alias, .. } => alias.is_some(),
        _ => false,
    })
}

/// Whether a connection's lens gets `nodes`: it selects `edges { node }`
/// and no field `nodes` itself.
fn selects_nodes(selections: &[SelectionPlan]) -> bool {
    let flat = fields_within(selections);
    let has_nodes_field = flat.iter().any(|selection| match selection {
        SelectionPlan::Scalar { name, alias, .. } | SelectionPlan::Linked { name, alias, .. } => {
            alias.as_deref().unwrap_or(name) == "nodes"
        }
        _ => false,
    });
    if has_nodes_field {
        return false;
    }
    flat.iter().any(|selection| {
        match selection {
        SelectionPlan::Linked {
            name,
            alias: None,
            selections,
            ..
        } if name == "edges" => fields_within(selections).iter().any(|selection| {
            matches!(selection, SelectionPlan::Linked { name, alias: None, .. } if name == "node")
        }),
        _ => false,
    }
    })
}

/// The fields a reader selection reaches without entering another field:
/// its own, and those inside its inline fragments and conditions.
fn fields_within(selections: &[SelectionPlan]) -> Vec<&SelectionPlan> {
    let mut result = Vec::new();
    for selection in selections {
        match selection {
            SelectionPlan::Inline { selections, .. }
            | SelectionPlan::Condition { selections, .. } => {
                result.extend(fields_within(selections))
            }
            SelectionPlan::Spread { .. } => {}
            other => result.push(other),
        }
    }
    result
}

/// The spreads a lens exposes under derived names: its own, and those inside
/// inline fragments and conditions that flatten into it (an inline fragment
/// on the lens's own type, as `@alias` produces; one on another type is a
/// nested lens with its own table). Spreads under an explicit `@alias(as:)`
/// are named by it and left out.
fn collect_spreads<'a>(selections: &'a [SelectionPlan], type_name: &str, into: &mut Vec<&'a str>) {
    for selection in selections {
        match selection {
            SelectionPlan::Spread { fragment, .. } => into.push(fragment.as_str()),
            SelectionPlan::Inline {
                type_condition,
                alias,
                selections: child,
                ..
            } => {
                if alias.is_some() {
                    continue;
                }
                match type_condition {
                    Some(condition) if condition != type_name => {}
                    _ => collect_spreads(child, type_name, into),
                }
            }
            SelectionPlan::Condition {
                selections: child, ..
            } => collect_spreads(child, type_name, into),
            _ => {}
        }
    }
}

/// Default spread accessor names: the fragment's owner prefix in lower camel
/// case, falling back to the whole name when two spreads would collide.
fn spread_accessor_names(
    selections: &[SelectionPlan],
    type_name: &str,
) -> BTreeMap<String, String> {
    let mut fragments: Vec<&str> = Vec::new();
    collect_spreads(selections, type_name, &mut fragments);
    let mut by_prefix: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for fragment in &fragments {
        let prefix = fragment.split('_').next().unwrap_or(fragment);
        by_prefix
            .entry(lower_camel(prefix))
            .or_default()
            .push(fragment);
    }
    let mut names = BTreeMap::new();
    for (prefix, owners) in by_prefix {
        if owners.len() == 1 {
            names.insert(owners[0].to_string(), prefix);
        } else {
            for owner in owners {
                names.insert(owner.to_string(), lower_camel(owner));
            }
        }
    }
    names
}
