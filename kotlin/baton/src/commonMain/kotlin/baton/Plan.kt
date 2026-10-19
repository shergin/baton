package baton

/**
 * The normalization plan of one operation: how a response of its shape
 * becomes records. Generated code builds one per operation, once, from the
 * selections the compiler laid out; the store walks it on every commit. See
 * `spec/runtime.md`, section 2.
 */
@Generated
class Plan(val root: Selection, transient: Transient? = null, val deletions: List<Deletion> = emptyList()) {
    /**
     * The keys of the records the deletions name under [variables], composed
     * as a lookup composes a key from a variable's value; a deletion whose
     * variable is unset or null names none.
     */
    internal fun deletionKeys(variables: Variables): List<String> = deletions.mapNotNull { deletion ->
        val value = variables.values[deletion.variable]
        if (value == null || value == Variable.Null) null else Record.entityKey(deletion.type.name, value.keyText)
    }
}

/**
 * `@deletes(type:id:)` on a mutation: a record the mutation deletes, named
 * by its type and the variable its key is passed as. The commit deletes it
 * as `@deleteRecord` deletes one the payload names
 * (`docs/decisions/a-mutation-names-the-record-it-deletes.md`).
 */
@Generated
class Deletion(val type: TypeID, val variable: String)

/**
 * What never reaches the image: the types whose records are not written, and
 * the root fields whose cells, keys and operations are not.
 */
@Generated
class Transient(types: List<TypeID>, fields: List<Pair<TypeID, String>>) {
    init {
        for (type in types) Registry.markTransient(type)
        for ((type, field) in fields) Registry.markTransient(type, field)
    }
}

/** How a scalar field's JSON value is read into a cell. */
@Generated
enum class ScalarKind { STRING, INT, DOUBLE, BOOL, CUSTOM }

/** A piece of a storage key an argument renders: literal text or a variable's value. */
@Generated
sealed interface KeyPart {
    data class Literal(val text: String) : KeyPart
    data class Variable(val name: String) : KeyPart
}

/** One argument of a rendered storage key, `page:1` in `characters(page:1)`. */
@Generated
class KeyArgument(val name: String, val parts: List<KeyPart>) {
    /** The argument's text under [variables], or null for one left out of the key: an unset or null variable. */
    internal fun render(variables: Variables): String? {
        val only = parts.singleOrNull()
        if (only is KeyPart.Variable) {
            val value = variables.values[only.name]
            if (value == null || value == Variable.Null) return null
            return value.json
        }
        return buildString {
            for (part in parts) {
                when (part) {
                    is KeyPart.Literal -> append(part.text)
                    is KeyPart.Variable -> append(variables.render(part.name))
                }
            }
        }
    }
}

/**
 * A storage key rendered at run time from the operation's variables, as Relay
 * renders `characters(page:1)`: the field's name and its arguments in the
 * document's order, an argument with an unset or null value left out.
 */
@Generated
class DynamicKey(val type: TypeID, val name: String, val arguments: List<KeyArgument>) {
    fun render(variables: Variables): String = buildString {
        append(name)
        var open = false
        for (argument in arguments) {
            val value = argument.render(variables) ?: continue
            append(if (open) ',' else '(')
            open = true
            append(argument.name)
            append(':')
            append(value)
        }
        if (open) append(')')
    }
}

/** Where a field's value is stored: a cell the build numbered, or one named by rendering a key. */
@Generated
sealed interface StorageKey {
    data class Fixed(val slot: Slot) : StorageKey
    data class Dynamic(val key: DynamicKey) : StorageKey
}

/**
 * A field whose argument names the record it links to, so a value can be found
 * in the store before any response: `character(id: $id)` keyed by `Character:<id>`.
 */
@Generated
class Lookup(val type: TypeID?, val possibleTypes: Members? = null, val key: List<Key>) {
    sealed interface Key {
        data class Variable(val name: String) : Key
        data class Literal(val text: String) : Key
    }
}

/** The types that satisfy an abstract type as the build knows them, learned further from responses. */
@Generated
class Members(val condition: TypeID, val types: List<TypeID>) {
    private val compiled: BooleanArray = BooleanArray((types.maxOfOrNull { it.raw } ?: -1) + 1).also { array ->
        for (type in types) array[type.raw] = true
    }

    init {
        Membership.register(condition, types)
    }

    /** Whether [type] satisfies the condition; read on the main thread, where membership is learned. */
    fun includes(type: TypeID): Boolean {
        if (type.raw < compiled.size && compiled[type.raw]) return true
        return Membership.learned(type, condition)
    }
}

/** The cells a connection, its edges and its page info keep, interned once per connection type. */
@Generated
class ConnectionSlots(val connection: TypeID, val edge: TypeID, val pageInfo: TypeID) {
    val edges: Slot = Registry.slot(connection, "edges")
    val pageInfoLink: Slot = Registry.slot(connection, "pageInfo")
    val node: Slot = Registry.slot(edge, "node")
    val cursor: Slot = Registry.slot(edge, "cursor")
    val hasNextPage: Slot = Registry.slot(pageInfo, "hasNextPage")
    val hasPreviousPage: Slot = Registry.slot(pageInfo, "hasPreviousPage")
    val startCursor: Slot = Registry.slot(pageInfo, "startCursor")
    val endCursor: Slot = Registry.slot(pageInfo, "endCursor")
    val isLoadingNext: Slot = Registry.slot(connection, "__isLoadingNext")
    val isLoadingPrevious: Slot = Registry.slot(connection, "__isLoadingPrevious")
    val nextEdgeIndex: Slot = Registry.slot(connection, "__connection_next_edge_index")

    init {
        Registry.register(this)
    }
}

/**
 * The cells a paged list's merge and state use, on the container type the
 * pages and the merged record share and on its page info type, plus the
 * client fields the merge keeps on the merged record: where the list
 * started, the span of each page in it, and whether a page is loading.
 */
@Generated
class PagedSlots(val container: TypeID, val pageInfo: TypeID) {
    val pageInfoLink: Slot = Registry.slot(container, "pageInfo")
    val hasNextPage: Slot = Registry.slot(pageInfo, "hasNextPage")
    val isLoadingNext: Slot = Registry.slot(container, "__isLoadingNext")
    val firstPage: Slot = Registry.slot(container, "__firstPage")
    val pageLengths: Slot = Registry.slot(container, "__pageLengths")
}

/**
 * A paged list on the field that takes the page, its container: the client
 * record of the container's type its pages merge into, keyed on the
 * container's parent by the list and its arguments; the list field's own key
 * on the container; and the variable that names the page each run. See
 * `docs/decisions/a-paged-list-merges-its-pages-by-number.md`.
 */
@Generated
class PagedPlan(val key: StorageKey, val list: StorageKey, val slots: PagedSlots, val page: String)

/** Where a connection's page boundary comes from: a variable, or a constant in the document. */
@Generated
sealed interface ConnectionCursor {
    data class Variable(val name: String) : ConnectionCursor
    data object Literal : ConnectionCursor
}

/** A `@connection` field: its key, its cells, and the cursors its pages are merged by. */
@Generated
class ConnectionPlan(
    val key: StorageKey,
    val slots: ConnectionSlots,
    val after: ConnectionCursor? = null,
    val before: ConnectionCursor? = null,
) {
    internal val readsVariables: Boolean
        get() = key is StorageKey.Dynamic || after is ConnectionCursor.Variable || before is ConnectionCursor.Variable
}

/** A mutation's edit directive on a field: what it does to which connections. */
@Generated
class Edit(val kind: Kind, val connections: Connections? = null, val edgeType: TypeID? = null) {
    enum class Kind { APPEND_EDGE, PREPEND_EDGE, APPEND_NODE, PREPEND_NODE, DELETE_EDGE, DELETE_RECORD }

    sealed interface Connections {
        data class Variable(val name: String) : Connections
        data class Literal(val ids: List<String>) : Connections
    }
}

/** How a `@refetchable` fragment's query is built: its variables, its identifier and its pagination arguments. */
@Generated
class Refetch(
    val variables: List<String>,
    val identifier: String?,
    val identity: Slot?,
    val first: String?,
    val after: String?,
    val last: String?,
    val before: String?,
)

/** An `@include` or `@skip` condition on a field: the variable and the value that selects the field. */
@Generated
class Guard(val variable: String, val passing: Boolean) {
    internal fun holds(variables: Variables): Boolean = variables[variable] == Variable.Bool(passing)
}

/** One field of a selection: where its value goes and how it is read. */
@Generated
class PlanField private constructor(
    val responseKey: String,
    val key: StorageKey,
    val kind: Kind,
    val edit: Edit?,
    /** The paged list this field is the container of, when a field of its selection carries `@paged`. */
    val paged: PagedPlan?,
    val deferred: String?,
    /** The `@stream` label the field's items carry, when the list streams. */
    val streamed: String?,
    val caught: Boolean,
    val client: Boolean,
    val transient: Boolean,
    val guards: List<List<Guard>>,
) {
    sealed interface Kind {
        data class Scalar(val kind: ScalarKind, val list: Boolean) : Kind
        data class Linked(val selection: Selection, val plural: Boolean, val lookup: Lookup?, val connection: ConnectionPlan?) : Kind
    }

    internal val keyBytes: ByteArray = responseKey.encodeToByteArray()
    internal val fixedStorageKey: String? = (key as? StorageKey.Fixed)?.let { Registry.storageKey(it.slot) }
    internal val readsVariables: Boolean = run {
        if (guards.isNotEmpty() || key is StorageKey.Dynamic) return@run true
        if (edit?.connections is Edit.Connections.Variable) return@run true
        // A paged list's merge reads the page variable every run.
        if (paged != null) return@run true
        val linked = kind as? Kind.Linked ?: return@run false
        linked.selection.readsVariables ||
            linked.lookup?.key?.any { it is Lookup.Key.Variable } == true ||
            linked.connection?.readsVariables == true
    }

    /** Whether the field is selected under [variables]: no guards, or one conjunction of guards that all hold. */
    internal fun selected(variables: Variables): Boolean =
        guards.isEmpty() || guards.any { conjunction -> conjunction.all { it.holds(variables) } }

    companion object {
        fun scalar(
            responseKey: String,
            key: StorageKey,
            kind: ScalarKind,
            list: Boolean,
            edit: Edit? = null,
            deferred: String? = null,
            caught: Boolean = false,
            client: Boolean = false,
            transient: Boolean = false,
            guards: List<List<Guard>> = emptyList(),
        ): PlanField = PlanField(responseKey, key, Kind.Scalar(kind, list), edit, null, deferred, null, caught, client, transient, guards)

        fun linked(
            responseKey: String,
            key: StorageKey,
            plural: Boolean,
            lookup: Lookup? = null,
            connection: ConnectionPlan? = null,
            paged: PagedPlan? = null,
            edit: Edit? = null,
            deferred: String? = null,
            streamed: String? = null,
            caught: Boolean = false,
            client: Boolean = false,
            transient: Boolean = false,
            guards: List<List<Guard>> = emptyList(),
            selection: Selection,
        ): PlanField = PlanField(
            responseKey, key, Kind.Linked(selection, plural, lookup, connection), edit, paged, deferred, streamed, caught, client, transient, guards,
        )
    }
}

/**
 * A selection set over one type: the fields read from a record of that type,
 * by variant when the set differs by the concrete type, and the questions a
 * response answers about membership.
 */
@Generated
class Selection(
    val type: TypeID,
    val key: List<String>,
    val isAbstract: Boolean = false,
    val memberships: List<MembershipAnswer> = emptyList(),
    val variants: List<Variant>,
) {
    constructor(type: TypeID, key: List<String>, isAbstract: Boolean = false, fields: List<PlanField>) :
        this(type, key, isAbstract, emptyList(), listOf(Variant(types = null, fields = fields)))

    /** The fields read when the record's type is one of [types], or every type when null. */
    class Variant(val types: List<TypeID>?, val key: List<String>? = null, val condition: TypeID? = null, val fields: List<PlanField>)

    /** A response key whose presence says the record satisfies [condition]. */
    class MembershipAnswer(val responseKey: String, val condition: TypeID)

    internal val readsVariables: Boolean = variants.any { variant -> variant.fields.any { it.readsVariables } }
    internal val transient: Boolean = variants.any { variant -> variant.fields.any { it.transient } }

    /** Whether a list somewhere in the selection streams, so that its data is whole only under a root a completed stream dated; decided once here. */
    internal val streams: Boolean = variants.any { variant ->
        variant.fields.any { it.streamed != null || (it.kind as? PlanField.Kind.Linked)?.selection?.streams == true }
    }
}
