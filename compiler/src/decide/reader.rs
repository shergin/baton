//! The reader half of the decide pass: one `ReaderPlan` per lens, the model
//! in `lens`, with every name, nullability, read form, guard and check
//! settled, for the lens printer to write as it is.
//!
//! A lens reads its members: the fields, spreads and inline fragments of its
//! selection, merged per response key, fragment and type condition, each with
//! the `@include` and `@skip` conditions it is fetched under. A member's
//! accessor follows from its directives and the error policy around it:
//! `@required` makes it non-optional and, with `THROW`, throwing; `@catch`
//! makes it a `Result` or reads errors as nil; `@throwOnFieldError` or a
//! surrounding `@catch` types `@semanticNonNull` fields non-null.

use std::collections::{BTreeMap, BTreeSet};

use super::checks::{field_errors, is_present, report_missing, satisfied};
use super::lens::{
    Accessor, AliasGuard, AliasedRead, Binding, BoundArgument, ConditionRead, ConnectionMembers,
    ErrorCheck, ErrorLine, Guarded, LinkedForm, LinkedRead, LoadMore, Nodes, Read, ReaderPlan,
    RefetchMembers, ScalarForm, ScalarRead, ScalarShape, SlotAccess, SpreadForm, SpreadGuard,
    SpreadRead, TypeTest, hideable_name,
};
use super::members::{
    Member, collect_caught, collect_deferred, condition_lens, derived_spread, members,
    selects_nodes, spread_accessor_names, written_accessor,
};
use super::written_key;
use crate::names::{
    Kind, NameError, Reserved, Scope, enum_type_name, input_type_name, lower_camel,
};
use crate::pipeline::{
    ArgumentPlan, CatchTarget, ConditionClass, ConnectionPlan, ConstantPlan, FragmentPlan, Plan,
    RefetchPlan, RequiredAction, SelectionPlan, StorageKeyPlan, VariablePlan,
};

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
    /// The fragments marked `@inline`, whose spreads build values.
    inline_fragments: BTreeSet<String>,
    /// The inline fragments whose errors something asks for: a value with
    /// an error policy of its own or spread under a catch, and, since a
    /// value's errors include those of the values it spreads, every value
    /// spread inside one of those or under a `@catch` inside any value.
    scanning_values: BTreeSet<String>,
    /// Fragments spread alone under `@catch` somewhere: their lenses get
    /// `fieldErrors`, which the catch reads.
    caught_fragments: BTreeSet<String>,
    /// What a nested lens may not be named: the names a lens spells, and
    /// the program's fragments and operations.
    lens_names: Reserved,
    /// The Swift type each mapped scalar reads as, by the scalar's name, as
    /// the configuration names it.
    pub host_types: BTreeMap<String, String>,
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
    /// The response path from the lens's root to this lens, dotted and
    /// ending in a dot, or empty at the root: what a field's error is
    /// reported under.
    response_path: &'a str,
    /// In an `@inline` fragment: the reads fill a value's stored
    /// properties, which cannot throw.
    inline: bool,
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
    /// The response key the lens is read under, for a linked field; an
    /// inline fragment adds no step to the response path.
    response_key: Option<String>,
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
    pub(super) fn new(plan: &Plan, host_types: &BTreeMap<String, String>) -> Readers {
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
        let scanning_values = scanning_values(plan, &caught_fragments);
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
            inline_fragments: plan
                .fragments
                .iter()
                .filter(|fragment| fragment.inline)
                .map(|fragment| fragment.name.clone())
                .collect(),
            scanning_values,
            lens_names: Reserved::lenses(
                plan.fragments
                    .iter()
                    .map(|fragment| fragment.name.clone())
                    .chain(
                        plan.operations
                            .iter()
                            .map(|operation| operation.name.clone()),
                    )
                    .chain(plan.enums.keys().map(|name| enum_type_name(name)))
                    .chain(plan.inputs.keys().map(|name| input_type_name(name))),
            ),
            host_types: host_types.clone(),
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
            caught_spread: self.caught_fragments.contains(&fragment.name)
                || self.scanning_values.contains(&fragment.name),
            response_path: "",
            inline: fragment.inline,
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
            response_path: "",
            inline: false,
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
            .map(|refetch| refetch_members(refetch, type_name));
        let connection = connection.map(|connection| {
            self.connection_members(connection, type_name, &members, facts.nodes, context)
        });
        let satisfied =
            bubbles.then(|| satisfied(type_name, type_is_abstract, &members, &self.host_types));
        let mut field_errors = context.scans_errors().then(|| {
            field_errors(
                type_name,
                type_is_abstract,
                &members,
                context.response_path,
                &self.host_types,
            )
        });
        // A value is one frozen selection: the errors inside the values it
        // spreads are its own, but for a spread that catches them itself.
        // A lens's spread keeps its fragment's policy, as the fragment is
        // one live type wherever it is spread.
        if context.inline
            && let Some(checks) = &mut field_errors
        {
            for accessor in &accessors {
                if let Read::Spread(read) = &accessor.read
                    && self.inline_fragments.contains(&read.fragment)
                    && read.form != SpreadForm::Caught
                    && !read
                        .guards
                        .iter()
                        .any(|guard| matches!(guard, SpreadGuard::NoErrors))
                {
                    checks.push(ErrorCheck::Member(Guarded {
                        guards: Vec::new(),
                        item: vec![ErrorLine::Spread(read.clone())],
                    }));
                }
            }
        }
        let is_present = (is_fragment_root && self.deferred_fragments.contains(name))
            .then(|| is_present(type_name, type_is_abstract, &members));
        let nested = nested
            .into_iter()
            .map(|child| {
                let path = format!("{}.{}", context.path, child.name);
                let response_path = match &child.response_key {
                    Some(key) => format!("{}{key}.", context.response_path),
                    None => context.response_path.to_string(),
                };
                let child_context = Context {
                    path: &path,
                    within_catch: context.within_catch || child.within_catch,
                    response_path: &response_path,
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
            .extend(hidden_names(context.path, &lens, &members));
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
            type_, selections, ..
        } = &edges.selection
        else {
            unreachable!("the edges member is a linked field");
        };
        let base_type = type_.base_name();
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
                SelectionPlan::Scalar { name, .. } if name == "__typename" => continue,
                SelectionPlan::Scalar { .. } => scalar_read(
                    member,
                    type_name,
                    type_is_abstract,
                    context,
                    &self.host_types,
                ),
                SelectionPlan::Linked { .. } => {
                    linked_read(member, type_name, type_is_abstract, nested, context)
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
                SelectionPlan::Inline { .. } => {
                    match self.inline_read(member, type_name, type_is_abstract, nested, context) {
                        Some(read) => read,
                        // `members` folds every other inline fragment into the lens.
                        None => continue,
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

    /// An inline fragment's read: one spread under `@alias(as:)` or `@defer`,
    /// a nested lens under an alias, or a type condition's optional lens.
    /// None for one `members` folds into the lens.
    fn inline_read(
        &mut self,
        member: &Member,
        type_name: &str,
        type_is_abstract: bool,
        nested: &mut Vec<Nested>,
        context: Context<'_>,
    ) -> Option<Read> {
        let SelectionPlan::Inline {
            type_condition,
            condition_class,
            alias,
            deferred,
            catch,
            bubbles,
            selections: child,
            ..
        } = &member.selection
        else {
            unreachable!("an inline member is an inline fragment");
        };
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
            return Some(Read::Spread(self.spread(
                context.owner,
                member,
                fragment,
                arguments,
                spread_condition,
                deferred.is_some(),
                catch.as_ref().map(|catch| catch.to),
                type_name,
                type_is_abstract,
            )));
        }
        if alias.is_some() {
            // `@alias(as:)` on other selections: a nested lens.
            let lens = member.lens_name().to_string();
            let condition_lens = condition_lens(type_condition, condition_class, member);
            let (lens_type, lens_abstract) = match &condition_lens {
                Some((lens_type, lens_abstract, _)) => (lens_type.clone(), *lens_abstract),
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
                response_key: None,
            });
            return Some(Read::Aliased(AliasedRead {
                lens,
                guards,
                caught: catch
                    .as_ref()
                    .is_some_and(|catch| catch.to == CatchTarget::Result),
            }));
        }
        let (lens_type, lens_abstract, test) =
            condition_lens(type_condition, condition_class, member)?;
        let lens = member.lens_name().to_string();
        nested.push(Nested {
            name: lens.clone(),
            type_name: lens_type,
            is_abstract: lens_abstract,
            selections: child.clone(),
            connection: None,
            bubbles: false,
            within_catch: false,
            response_key: None,
        });
        Some(Read::Condition(ConditionRead { lens, test }))
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

/// The inline fragments that scan for field errors: those with
/// `@throwOnFieldError` or spread under a catch, then, to a fixed point,
/// every inline fragment spread inside one of those, and every one spread
/// inside a value that holds a `@catch`, whose caught selection scans.
fn scanning_values(plan: &Plan, caught_fragments: &BTreeSet<String>) -> BTreeSet<String> {
    let values: BTreeMap<&str, &FragmentPlan> = plan
        .fragments
        .iter()
        .filter(|fragment| fragment.inline)
        .map(|fragment| (fragment.name.as_str(), fragment))
        .collect();
    let mut scanning: BTreeSet<String> = values
        .values()
        .filter(|fragment| {
            fragment.throws_on_field_error || caught_fragments.contains(&fragment.name)
        })
        .map(|fragment| fragment.name.clone())
        .collect();
    loop {
        let mut reached = Vec::new();
        for fragment in values.values() {
            let mut spreads = Vec::new();
            inline_spreads(
                &fragment.reader,
                scanning.contains(&fragment.name),
                &mut spreads,
            );
            reached.extend(
                spreads
                    .into_iter()
                    .filter(|spread| values.contains_key(spread.as_str())),
            );
        }
        let before = scanning.len();
        scanning.extend(reached);
        if scanning.len() == before {
            return scanning;
        }
    }
}

/// The fragments spread in a selection tree where errors are scanned:
/// everywhere when `scanning`, else under a `@catch`.
fn inline_spreads(selections: &[SelectionPlan], scanning: bool, into: &mut Vec<String>) {
    for selection in selections {
        match selection {
            SelectionPlan::Spread { fragment, .. } => {
                if scanning {
                    into.push(fragment.clone());
                }
            }
            SelectionPlan::Linked {
                catch,
                selections: child,
                ..
            }
            | SelectionPlan::Inline {
                catch,
                selections: child,
                ..
            } => inline_spreads(child, scanning || catch.is_some(), into),
            SelectionPlan::Condition {
                selections: child, ..
            } => inline_spreads(child, scanning, into),
            SelectionPlan::Scalar { .. } => {}
        }
    }
}

/// A scalar field's read: non-null in effect when the schema, `@required`
/// or the error policy around it says so, in the form its directives give.
fn scalar_read(
    member: &Member,
    type_name: &str,
    type_is_abstract: bool,
    context: Context<'_>,
    host_types: &BTreeMap<String, String>,
) -> Read {
    let SelectionPlan::Scalar {
        name,
        alias,
        type_,
        non_null,
        semantic_non_null,
        storage_key,
        required,
        catch,
        ..
    } = &member.selection
    else {
        unreachable!("a scalar member is a scalar field");
    };
    // A mapped scalar's schema promises the text, not the conversion: the
    // read is non-null only where a directive says what a failure does, and
    // there as the schema types the field.
    let non_null = if type_.is_mapped() {
        required.is_some()
            || (*non_null && (context.handles_errors() || catch.is_some()))
            || (*semantic_non_null && context.handles_errors())
    } else {
        *non_null || required.is_some() || (*semantic_non_null && context.handles_errors())
    };
    let form = match (
        catch.as_ref().map(|catch| catch.to),
        required.as_ref().map(|required| required.action),
    ) {
        (Some(CatchTarget::Result), _) => ScalarForm::Caught { non_null },
        (Some(CatchTarget::Null), _) => ScalarForm::Nulled,
        (_, Some(RequiredAction::Throw)) => ScalarForm::Throwing {
            path: required_path(required),
        },
        // A non-null mapped scalar reads throwing, since a text that does
        // not convert has no zero to read as; a value's stored property
        // cannot throw, so in an inline fragment it reads optional, and
        // under `@throwOnFieldError` the failure throws at the spread.
        _ if non_null && type_.is_mapped() && context.inline => ScalarForm::Optional,
        _ if non_null => ScalarForm::Required,
        _ => ScalarForm::Optional,
    };
    Read::Scalar(ScalarRead {
        slot: SlotAccess::of(type_name, type_is_abstract, storage_key),
        shape: ScalarShape::of(type_, host_types),
        form,
        path: format!(
            "{}{}",
            context.response_path,
            alias.as_deref().unwrap_or(name)
        ),
    })
}

/// A linked field's read, singular or plural, and the nested lens it reads
/// as.
fn linked_read(
    member: &Member,
    type_name: &str,
    type_is_abstract: bool,
    nested: &mut Vec<Nested>,
    context: Context<'_>,
) -> Read {
    let SelectionPlan::Linked {
        name,
        alias,
        type_,
        non_null,
        semantic_non_null,
        is_abstract,
        storage_key,
        connection,
        required,
        catch,
        bubbles,
        selections: child,
        ..
    } = &member.selection
    else {
        unreachable!("a linked member is a linked field");
    };
    let base_type = type_.base_name().to_string();
    let plural = type_.is_list();
    let lens = member.lens_name().to_string();
    let non_null =
        *non_null || required.is_some() || (*semantic_non_null && context.handles_errors());
    let catch_to = catch.as_ref().map(|catch| catch.to);
    let required_action = required.as_ref().map(|required| required.action);
    let path = required_path(required);
    let form = if plural {
        match (catch_to, required_action) {
            (Some(CatchTarget::Result), _) => LinkedForm::CaughtList { non_null },
            (_, Some(RequiredAction::Throw)) => LinkedForm::ThrowingList { path },
            _ if non_null && catch_to != Some(CatchTarget::Null) => LinkedForm::RequiredList,
            _ => LinkedForm::List,
        }
    } else {
        // A link whose children can bubble reads as optional
        // unless it is itself required, when its parent has
        // checked it.
        let optional =
            !non_null || (*bubbles && required.is_none()) || catch_to == Some(CatchTarget::Null);
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
        response_key: Some(alias.clone().unwrap_or_else(|| name.clone())),
    });
    Read::Linked(LinkedRead {
        slot: SlotAccess::of(type_name, type_is_abstract, storage_key),
        lens,
        base_type: base_type.clone(),
        bubbles: *bubbles,
        form,
    })
}

/// The `@refetchable` surface of a fragment lens: the descriptor of its
/// query and `refetch()`.
fn refetch_members(refetch: &RefetchPlan, type_name: &str) -> RefetchMembers {
    let pagination = refetch.connection.as_ref();
    let id = StorageKeyPlan {
        name: "id".to_string(),
        arguments: Vec::new(),
    };
    RefetchMembers {
        operation: refetch.operation.clone(),
        variables: refetch.variables.clone(),
        identifier: refetch.identifier.clone(),
        identity: refetch
            .identifier
            .as_ref()
            .map(|_| SlotAccess::of(type_name, false, &id)),
        first: pagination.and_then(|pagination| pagination.first.clone()),
        after: pagination.and_then(|pagination| pagination.after.clone()),
        last: pagination.and_then(|pagination| pagination.last.clone()),
        before: pagination.and_then(|pagination| pagination.before.clone()),
    }
}

fn required_path(required: &Option<crate::pipeline::RequiredPlan>) -> String {
    required
        .as_ref()
        .map(|required| required.path.clone())
        .unwrap_or_default()
}

/// The clashes of a lens's accessors with the names its code spells that
/// they would hide: an accessor the document named `Slots`, say, would hide
/// the enum from every body of the lens and of the lenses nested in it.
fn hidden_names(path: &str, lens: &ReaderPlan, members: &[Member]) -> Vec<NameError> {
    let spelled = lens.hideable_names();
    let none = Reserved::none();
    let mut scope = Scope::new(path, &none);
    for name in &spelled {
        scope.declare(name, Kind::Type, hideable_name(name));
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
