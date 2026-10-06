//! The plan IR: every fragment and operation in Baton's terms, once Relay's
//! front end has checked and transformed them. It is the seam: nothing
//! after it sees a Relay type.

use std::collections::BTreeMap;

/// The plan IR for one compilation: every fragment's reader shape and every
/// operation's reader shape, normalization shape, text and id.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Plan {
    pub fragments: Vec<FragmentPlan>,
    pub operations: Vec<OperationPlan>,
    /// The schema's root types the store knows by another name, such as
    /// `QueryRoot` by `Query`.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub root_names: BTreeMap<String, String>,
    /// The MD5 of the schema's text, which an app passes as its image's
    /// version so a new schema starts the image again.
    #[serde(skip)]
    pub schema_digest: String,
    /// The schema's enums the documents read or pass, with their values in
    /// the schema's order: each is generated as a Swift enum with a case per
    /// value and one for a value the build does not know.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub enums: BTreeMap<String, Vec<String>>,
}

/// Where a document wrote a name it chose: the file, which of the file's
/// documents, and the byte offset of the name in that document's text. A
/// name the generated code also needs is reported here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    pub path: String,
    pub document: usize,
    pub offset: u32,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FragmentPlan {
    pub name: String,
    /// Where the document wrote the fragment's name.
    #[serde(skip)]
    pub origin: Option<Origin>,
    /// The file the fragment was declared in.
    pub source: String,
    /// Which of the file's documents declared it, as the scanner numbered
    /// them.
    pub document: usize,
    pub type_condition: String,
    /// Whether the type condition is an interface or union.
    pub type_is_abstract: bool,
    /// The concrete types the type condition admits, sorted.
    pub possible_types: Vec<String>,
    /// `@argumentDefinitions`, with defaults.
    pub arguments: Vec<VariablePlan>,
    /// `@refetchable`: the generated query and how to bind it.
    pub refetch: Option<RefetchPlan>,
    /// `@throwOnFieldError`: a field error anywhere inside throws at the spread.
    pub throws_on_field_error: bool,
    /// Whether a `@required` field of the fragment can null the whole fragment.
    pub bubbles: bool,
    pub reader: Vec<SelectionPlan>,
}

/// How a `@refetchable` fragment is fetched again: the generated query, the
/// variable carrying the owner's id, and the connection it paginates.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RefetchPlan {
    pub operation: String,
    /// The query's variable names: the fragment's arguments and the globals it uses.
    pub variables: Vec<String>,
    /// The variable the owner's id is passed as (`id`), when the query roots at `node`.
    pub identifier: Option<String>,
    pub connection: Option<PaginationPlan>,
}

/// The variables a fragment's one connection paginates by.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PaginationPlan {
    pub path: Vec<String>,
    pub first: Option<String>,
    pub after: Option<String>,
    pub last: Option<String>,
    pub before: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct OperationPlan {
    pub name: String,
    /// Where the document wrote the operation's name.
    #[serde(skip)]
    pub origin: Option<Origin>,
    /// The file the operation was declared in.
    pub source: String,
    /// Which of the file's documents declared it, as the scanner numbered
    /// them; a refetch query is its fragment's.
    pub document: usize,
    pub kind: OperationKind,
    pub root_type: String,
    pub variables: Vec<VariablePlan>,
    pub text: String,
    pub id: String,
    /// `@throwOnFieldError`: an uncaught field error fails the operation.
    pub throws_on_field_error: bool,
    /// Whether a `@required` field at the root can null the whole result.
    pub bubbles: bool,
    /// Whether any part of the response may arrive incrementally.
    pub has_deferred: bool,
    /// The `onError` value `baton.json` names, as `Baton.ErrorBehavior`'s case.
    pub error_behavior: Option<String>,
    /// `@cacheExpiration(seconds:)`: how old the query's data may be before
    /// it reads as stale; none takes the store's default.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_expiration: Option<f64>,
    pub reader: Vec<SelectionPlan>,
    pub normalization: Vec<SelectionPlan>,
}

/// Relay's three kinds of operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OperationKind {
    Query,
    Mutation,
    Subscription,
}

impl OperationKind {
    /// The keyword GraphQL writes the operation with.
    pub fn keyword(self) -> &'static str {
        match self {
            OperationKind::Query => "query",
            OperationKind::Mutation => "mutation",
            OperationKind::Subscription => "subscription",
        }
    }
}

impl std::fmt::Display for OperationKind {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.keyword())
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct VariablePlan {
    pub name: String,
    /// Where the document wrote the variable's name.
    #[serde(skip)]
    pub origin: Option<Origin>,
    #[serde(rename = "type")]
    pub type_: TypePlan,
    pub default_value: Option<ConstantPlan>,
}

/// A field's or a variable's type as the schema writes it: a named type, or
/// a list of a type, each non-null or not. Built once, in the lowering, for
/// the reader side and the normalization side alike, so the two cannot
/// disagree about a shape. The accessor form `@required` and `@catch`
/// produce stays apart from it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "shape", rename_all = "snake_case")]
pub enum TypePlan {
    Named {
        name: String,
        kind: TypeKind,
        non_null: bool,
        /// The Swift type a custom scalar reads as, when `baton.json` maps
        /// it; the store keeps the text either way.
        #[serde(skip_serializing_if = "Option::is_none")]
        mapped: Option<String>,
    },
    List {
        element: Box<TypePlan>,
        non_null: bool,
    },
}

impl TypePlan {
    /// Whether the outermost type is non-null.
    pub fn non_null(&self) -> bool {
        match self {
            TypePlan::Named { non_null, .. } | TypePlan::List { non_null, .. } => *non_null,
        }
    }

    pub fn is_list(&self) -> bool {
        matches!(self, TypePlan::List { .. })
    }

    /// A list's element type.
    pub fn element(&self) -> Option<&TypePlan> {
        match self {
            TypePlan::List { element, .. } => Some(element),
            TypePlan::Named { .. } => None,
        }
    }

    /// The innermost named type.
    pub fn base(&self) -> &TypePlan {
        match self {
            TypePlan::Named { .. } => self,
            TypePlan::List { element, .. } => element.base(),
        }
    }

    pub fn base_name(&self) -> &str {
        match self.base() {
            TypePlan::Named { name, .. } => name,
            TypePlan::List { .. } => unreachable!("the base of a type is named"),
        }
    }

    pub fn base_kind(&self) -> TypeKind {
        match self.base() {
            TypePlan::Named { kind, .. } => *kind,
            TypePlan::List { .. } => unreachable!("the base of a type is named"),
        }
    }

    /// The Swift type the base reads as, when it is a mapped custom scalar.
    pub fn mapped(&self) -> Option<&str> {
        match self.base() {
            TypePlan::Named { mapped, .. } => mapped.as_deref(),
            TypePlan::List { .. } => unreachable!("the base of a type is named"),
        }
    }
}

/// What kind of named type a field or variable has.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TypeKind {
    String,
    Id,
    Int,
    Float,
    Boolean,
    CustomScalar,
    Enum,
    Object,
    Interface,
    Union,
    InputObject,
}

/// A GraphQL constant, as a fragment argument or a variable default.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ConstantPlan {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    List(Vec<ConstantPlan>),
    Object(Vec<(String, ConstantPlan)>),
}

/// An argument value: a variable of the enclosing scope, a constant, or a
/// list or object whose items may be either.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ArgumentValuePlan {
    Variable(String),
    Constant(ConstantPlan),
    List(Vec<ArgumentValuePlan>),
    Object(Vec<(String, ArgumentValuePlan)>),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ArgumentPlan {
    pub name: String,
    pub value: ArgumentValuePlan,
}

/// Relay's storage key, as a tree: the field name and its arguments, sorted
/// by name. The emitter writes it as the runtime renders one; nothing parses
/// it again.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct StorageKeyPlan {
    pub name: String,
    pub arguments: Vec<ArgumentPlan>,
}

/// A root field that returns an entity addressable by one of its arguments,
/// so a cached entity can satisfy the field before it was ever fetched.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct LookupPlan {
    /// `None` resolves by id among `possible_types`.
    pub type_name: Option<String>,
    /// The concrete types the field returns that one value keys, for a
    /// lookup without a type.
    pub possible_types: Vec<String>,
    /// The arguments that carry the key, in the key's order, with the value
    /// the document passes each.
    pub arguments: Vec<LookupArgumentPlan>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct LookupArgumentPlan {
    pub name: String,
    pub value: ArgumentValuePlan,
}

/// A `@connection` field: the client record pages merge into, and the cursor
/// arguments that decide whether a page replaces, appends or prepends.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ConnectionPlan {
    pub key: String,
    /// Relay's handle key with the filters: `__Key_connection(states:"OPEN")`.
    pub storage_key: StorageKeyPlan,
    pub edge_type: String,
    pub page_info_type: String,
    pub after: Option<ArgumentValuePlan>,
    pub before: Option<ArgumentValuePlan>,
}

/// An edge directive on a mutation payload field: the edit the commit makes
/// with the field's records, which Relay runs as a handle.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct EditPlan {
    pub kind: EditKind,
    pub connections: Option<ArgumentValuePlan>,
    pub edge_type_name: Option<String>,
}

/// The edge directives, by the names of the handles Relay runs them as,
/// which the runtime's cases share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EditKind {
    AppendEdge,
    PrependEdge,
    AppendNode,
    PrependNode,
    DeleteEdge,
    DeleteRecord,
}

impl EditKind {
    /// The edit Relay's handle `name` makes; `None` for a handle that is not
    /// an edge directive.
    pub(super) fn of(name: &str) -> Option<EditKind> {
        Some(match name {
            "appendEdge" => EditKind::AppendEdge,
            "prependEdge" => EditKind::PrependEdge,
            "appendNode" => EditKind::AppendNode,
            "prependNode" => EditKind::PrependNode,
            "deleteEdge" => EditKind::DeleteEdge,
            "deleteRecord" => EditKind::DeleteRecord,
            _ => return None,
        })
    }

    /// Relay's name for the handle, which the runtime's case shares.
    pub fn name(self) -> &'static str {
        match self {
            EditKind::AppendEdge => "appendEdge",
            EditKind::PrependEdge => "prependEdge",
            EditKind::AppendNode => "appendNode",
            EditKind::PrependNode => "prependNode",
            EditKind::DeleteEdge => "deleteEdge",
            EditKind::DeleteRecord => "deleteRecord",
        }
    }
}

/// `@required(action:)`: the action and Relay's dotted path for messages.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RequiredPlan {
    pub action: RequiredAction,
    pub path: String,
}

/// What a `@required` field does when it is null.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum RequiredAction {
    /// Nulls the enclosing lens.
    None,
    /// Nulls the enclosing lens and reports the path.
    Log,
    /// Throws at the field's read.
    Throw,
}

/// `@catch(to:)`.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CatchPlan {
    pub to: CatchTarget,
}

/// What a `@catch` reads an error as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum CatchTarget {
    /// A `Result` whose failure holds the errors.
    Result,
    /// Null.
    Null,
}

/// The plan IR is built once per compilation and read by the emitters, so the
/// size difference between a scalar and a linked field is of no account.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SelectionPlan {
    Scalar {
        name: String,
        alias: Option<String>,
        /// Where the document wrote the response key: the alias, or else
        /// the name.
        #[serde(skip)]
        origin: Option<Origin>,
        #[serde(rename = "type")]
        type_: TypePlan,
        /// Non-null in effect: the schema says so, and the error policy does
        /// not make every field nullable.
        non_null: bool,
        /// `@semanticNonNull` in the schema: null only when an error occurred.
        semantic_non_null: bool,
        storage_key: StorageKeyPlan,
        edit: Option<EditPlan>,
        required: Option<RequiredPlan>,
        catch: Option<CatchPlan>,
        /// Whether the field or an ancestor carries `@catch`, so an error on
        /// it does not fail a `@throwOnFieldError` operation.
        caught: bool,
    },
    Linked {
        name: String,
        alias: Option<String>,
        #[serde(skip)]
        origin: Option<Origin>,
        #[serde(rename = "type")]
        type_: TypePlan,
        non_null: bool,
        semantic_non_null: bool,
        /// The key fields of each keyed concrete type the field can return,
        /// by the type's name, in the configured order; a type absent here is
        /// keyed by its path.
        keys: BTreeMap<String, Vec<String>>,
        /// Whether the target type is an interface or union: records are then
        /// keyed and sloted by the payload's `__typename`.
        is_abstract: bool,
        /// The concrete types the target type admits, sorted: itself for an
        /// object type.
        possible_types: Vec<String>,
        storage_key: StorageKeyPlan,
        lookup: Option<LookupPlan>,
        connection: Option<ConnectionPlan>,
        edit: Option<EditPlan>,
        required: Option<RequiredPlan>,
        catch: Option<CatchPlan>,
        caught: bool,
        /// Whether a `@required` child can null this field.
        bubbles: bool,
        selections: Vec<SelectionPlan>,
    },
    Inline {
        type_condition: Option<String>,
        /// The concrete types the type condition admits, sorted.
        condition_types: Option<Vec<String>>,
        /// How the type condition stands to the parent's possible types.
        condition_class: Option<ConditionClass>,
        /// An explicit `@alias(as:)` name.
        alias: Option<String>,
        /// Where the document wrote the alias.
        #[serde(skip)]
        origin: Option<Origin>,
        /// `@defer`: the label the incremental part carries.
        deferred: Option<String>,
        catch: Option<CatchPlan>,
        bubbles: bool,
        selections: Vec<SelectionPlan>,
    },
    Spread {
        fragment: String,
        type_condition: String,
        /// `@arguments`, bound by the parent lens into the child's scope.
        arguments: Vec<ArgumentPlan>,
    },
    Condition {
        variable: Option<String>,
        passing: bool,
        selections: Vec<SelectionPlan>,
    },
}

/// How an inline fragment's type condition stands to the types its parent
/// admits: every one of them satisfies it, one does, or several do.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "type", rename_all = "snake_case")]
pub enum ConditionClass {
    /// The fields fold into the parent's lens.
    Always,
    /// A record of this concrete type, and only of it, satisfies it.
    Concrete(String),
    /// Records of several concrete types satisfy it.
    Set,
}
