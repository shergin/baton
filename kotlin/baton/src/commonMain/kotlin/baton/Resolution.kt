package baton

import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi

/**
 * Binds the variables: a field whose guards fail is dropped, a key with
 * variables is rendered and numbered by [keys], the store's, a lookup's key
 * is composed, a connection learns its merge mode and an edit its
 * connections. One resolution serves the ingest and the commit in the store
 * whose keys numbered it. See `spec/runtime.md`, section 2.
 */
internal fun Plan.resolve(variables: Variables, keys: Keys): ResolvedSelection {
    keys.reconcile()
    return Resolver(variables, keys).resolve(root)
}

/** How a page joins its connection, from the cursor arguments it was fetched with, as Relay's connection handler decides. */
internal sealed interface ConnectionMode {
    /** No cursor: the connection becomes this page. */
    data object Replace : ConnectionMode

    /** Fetched after a cursor: appended, when the cursor is still the end. */
    data class Append(val after: String?) : ConnectionMode

    /** Fetched before a cursor: prepended, when the cursor is still the start. */
    data class Prepend(val before: String?) : ConnectionMode
}

/** A bound lookup: the value part of the record key `Type:value`, or the id among the possible types. */
internal class LookupKey(val type: TypeID?, val possibleTypes: Members?, val value: String)

/** A connection with its variables bound: the client key on the parent, its slot there, and how the page joins. */
internal class ResolvedConnection(
    val storageKey: String,
    val rendered: Boolean,
    val slot: Slot,
    val slots: ConnectionSlots,
    val mode: ConnectionMode,
)

/** An edit with its connection ids bound. */
internal class ResolvedEdit(val kind: Edit.Kind, val connections: List<String>, val edgeType: TypeID?)

/** A field with its variables bound and its slot on the variant's concrete type. */
internal class ResolvedField(
    val responseKey: String,
    val keyBytes: ByteArray,
    val storageKey: String,
    /** Whether the key was rendered from variables, which numbers it apart on a concrete type that has not met it. */
    val rendered: Boolean,
    val slot: Slot,
    val kind: Kind,
    val edit: ResolvedEdit?,
    /** The `@defer` label of the part that carries the field, when one does. */
    val deferred: String?,
    val caught: Boolean,
    /** A client field, which no response carries. */
    val client: Boolean,
    /** Which of the record's key fields this is, or -1; set by the variant the field is read in. */
    val keyIndex: Int = -1,
) {
    sealed interface Kind {
        class Scalar(val kind: ScalarKind, val list: Boolean) : Kind
        class Linked(val selection: ResolvedSelection, val plural: Boolean, val lookup: LookupKey?, val connection: ResolvedConnection?) : Kind
    }

    val isTypename: Boolean get() = responseKey == "__typename"

    /** Whether a complete response carries the field: the server's own, outside any deferred part. */
    val isServer: Boolean get() = !client && deferred == null

    fun copy(slot: Slot = this.slot, kind: Kind = this.kind, deferred: String? = this.deferred, keyIndex: Int = this.keyIndex): ResolvedField =
        ResolvedField(responseKey, keyBytes, storageKey, rendered, slot, kind, edit, deferred, caught, client, keyIndex)

    /** The same field on another concrete type: its slot, and its connection's, interned there. */
    fun on(type: TypeID, keys: Keys?): ResolvedField {
        if (slot.type == type) return this
        val moved = when (kind) {
            is Kind.Scalar -> kind
            is Kind.Linked -> {
                val connection = kind.connection?.let {
                    ResolvedConnection(it.storageKey, it.rendered, slotOn(type, it.storageKey, it.rendered, keys), it.slots, it.mode)
                }
                Kind.Linked(kind.selection, kind.plural, kind.lookup, connection)
            }
        }
        return copy(slot = slotOn(type, storageKey, rendered, keys), kind = moved)
    }

    private fun slotOn(type: TypeID, storageKey: String, rendered: Boolean, keys: Keys?): Slot {
        if (!rendered) return Registry.slot(type, storageKey)
        checkNotNull(keys) { "a rendered key is resolved under a selection that reads variables, which holds the store's keys" }
        return keys.slot(type, storageKey)
    }
}

/**
 * The fields a record of one concrete type reads, with their slots on it,
 * its key fields marked, and the lists the walks use made once, so that no
 * walk tests a field for what it is.
 */
internal class ResolvedVariant(val type: TypeID, val key: List<String>, fields: List<ResolvedField>, typeName: String? = null) {
    val typeName: String = typeName ?: type.name
    val keyBytes: List<ByteArray> = key.map { it.encodeToByteArray() }
    val fields: List<ResolvedField> = fields.toMutableList().also { marked ->
        for ((index, name) in key.withIndex()) {
            val position = marked.indexOfFirst { it.responseKey == name && it.deferred == null }
            if (position >= 0) marked[position] = marked[position].copy(keyIndex = index)
        }
    }

    /** The fields a response is read by: every field but `__typename`, which the ingest reads as the record's identity. */
    val read: List<ResolvedField> = this.fields.filter { !it.isTypename }

    /** Where in [read] the fields are that a complete response carries. */
    val expected: IntArray = read.indices.filter { read[it].isServer }.toIntArray()

    /** The fields the availability check waits for: the server's own, outside any deferred part. */
    val waits: List<ResolvedField> = read.filter { it.isServer }

    /** The client fields, which a payload committed by hand writes: the check waits for none. */
    val payloadFields: List<ResolvedField> = read.filter { it.client }

    /** The connections' client links, which the check walks for their merged pages after the fields, and the collector follows. */
    val clientLinks: List<ResolvedField>

    /** The links the collector follows: every linked field, deferred or not, and the client links. */
    val follows: List<ResolvedField>

    init {
        val links = ArrayList<ResolvedField>()
        val followed = ArrayList<ResolvedField>()
        for (field in read) {
            val kind = field.kind as? ResolvedField.Kind.Linked ?: continue
            followed.add(field)
            val connection = kind.connection ?: continue
            val link = ResolvedField(
                responseKey = connection.storageKey,
                keyBytes = ByteArray(0),
                storageKey = connection.storageKey,
                rendered = connection.rendered,
                slot = connection.slot,
                kind = ResolvedField.Kind.Linked(kind.selection, plural = false, lookup = null, connection = null),
                edit = null,
                deferred = null,
                caught = field.caught,
                client = true,
            )
            links.add(link)
            followed.add(link)
        }
        clientLinks = links
        follows = followed
    }

    /** The field with a response key, for walking a response path. */
    fun field(responseKey: String): ResolvedField? = fields.firstOrNull { it.responseKey == responseKey }

    /** Adds the store's numbers the variant's fields and connections are slotted at, and those below them, to [into]. */
    internal fun renderedSlots(into: MutableSet<Slot>, seen: MutableSet<ResolvedSelection>) {
        for (field in fields) {
            if (field.slot.index < 0) into.add(field.slot)
            val kind = field.kind as? ResolvedField.Kind.Linked ?: continue
            kind.connection?.let { if (it.slot.index < 0) into.add(it.slot) }
            kind.selection.renderedSlots(into, seen)
        }
    }
}

/**
 * A selection with its variables bound: per concrete type, the fields a
 * record of that type reads. A type the plan did not list takes its variant
 * when a record of it first comes, from the fields every type reads and then
 * those of each condition it satisfies, kept per type and per set of
 * conditions; those caches are filled where the response is read, so they
 * are replaced by compare-and-set.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class ResolvedSelection(
    val type: TypeID,
    val key: List<String>,
    val isAbstract: Boolean,
    /** The fields every type reads; on an object type, its fields. */
    val fields: List<ResolvedField>,
    private val listed: Map<TypeID, ResolvedVariant>,
    private val conditions: List<Pair<TypeID, List<ResolvedField>>>,
    memberships: List<Selection.MembershipAnswer>,
    /** The store's keys, for a selection that reads variables; null for one every store shares. */
    private val keys: Keys?,
    /** Whether the selection reads a transient field: an operation selecting a transient root field leaves no fetch stamp in the image. */
    val transient: Boolean = false,
) {
    private val own = ResolvedVariant(type, key, fields)
    val membershipKeys: List<Pair<ByteArray, TypeID>> = memberships.map { it.responseKey.encodeToByteArray() to it.condition }

    /** The listed types' names as bytes, so a `__typename` of a listed type is matched without a string. */
    private val typeNameKeys: List<Pair<ByteArray, TypeID>> =
        (listOf(type) + listed.keys.sortedBy { it.raw }).map { it.name.encodeToByteArray() to it }

    private val others = AtomicReference<Map<Pair<TypeID, Long>, ResolvedVariant>>(emptyMap())
    private val deferredParts = AtomicReference<Map<String, ResolvedSelection?>>(emptyMap())

    /** Whether the plan lists the type, so a record of it needs no membership answer. */
    fun lists(type: TypeID): Boolean = type == this.type || listed.containsKey(type)

    /** The listed type whose name the bytes spell; null for an escaped name or one the plan does not list. */
    fun listedType(bytes: ByteArray, start: Int, end: Int, escaped: Boolean): TypeID? {
        if (escaped) return null
        val length = end - start
        for ((name, type) in typeNameKeys) {
            if (name.size == length && bytes.regionEquals(start, name)) return type
        }
        return null
    }

    /** The variant of a record of [type] as the store knows memberships: on the store's thread. */
    fun variant(type: TypeID): ResolvedVariant {
        if (!isAbstract || type == this.type) return own
        listed[type]?.let { return it }
        return unlisted(type) { condition -> Membership.includes(type, condition) }
    }

    /** The variant where the response is read: a type the plan did not list takes the conditions the response's answers name. */
    fun variant(type: TypeID, answers: List<TypeID>): ResolvedVariant {
        if (!isAbstract || type == this.type) return own
        listed[type]?.let { return it }
        return unlisted(type) { condition -> condition in answers }
    }

    private inline fun unlisted(type: TypeID, satisfies: (TypeID) -> Boolean): ResolvedVariant {
        var satisfied = 0L
        for ((index, condition) in conditions.withIndex()) {
            if (satisfies(condition.first)) satisfied = satisfied or (1L shl minOf(index, 63))
        }
        val cacheKey = type to satisfied
        others.load()[cacheKey]?.let { return it }
        val merged = fields.toMutableList()
        for ((index, condition) in conditions.withIndex()) {
            if (satisfied and (1L shl minOf(index, 63)) == 0L) continue
            for (field in condition.second) {
                if (merged.none { it.responseKey == field.responseKey }) merged.add(field)
            }
        }
        val variant = ResolvedVariant(type, key, merged.map { it.on(type, keys) })
        while (true) {
            val current = others.load()
            current[cacheKey]?.let { return it }
            if (others.compareAndSet(current, current + (cacheKey to variant))) return variant
        }
    }

    /**
     * Adds the store's numbers the selection's variants hold, those its
     * response met since among them, to [into]: what a live resolution keeps
     * from being freed. A selection that reads no variables holds none.
     */
    internal fun renderedSlots(into: MutableSet<Slot>, seen: MutableSet<ResolvedSelection> = HashSet()) {
        if (keys == null || !seen.add(this)) return
        own.renderedSlots(into, seen)
        for (variant in listed.values) variant.renderedSlots(into, seen)
        for (variant in others.load().values) variant.renderedSlots(into, seen)
    }

    /** The selection an incremental part with this `@defer` label fills: the fields the label marks, on the same record; null when none. */
    fun deferred(label: String): ResolvedSelection? {
        val cached = deferredParts.load()
        if (cached.containsKey(label)) return cached[label]
        fun part(fields: List<ResolvedField>) = fields.filter { it.deferred == label }.map { it.copy(deferred = null, keyIndex = -1) }
        val ownFields = part(fields)
        val parts = listed.mapValues { (type, variant) -> ResolvedVariant(type, variant.key, part(variant.fields), variant.typeName) }
        val selection = if (ownFields.isEmpty() && parts.values.all { it.fields.isEmpty() }) {
            null
        } else {
            ResolvedSelection(
                type, key, isAbstract, ownFields, parts,
                conditions.map { it.first to part(it.second) },
                membershipKeys.map { Selection.MembershipAnswer(it.first.decodeToString(), it.second) },
                keys,
                transient,
            )
        }
        while (true) {
            val current = deferredParts.load()
            if (current.containsKey(label)) return current[label]
            if (deferredParts.compareAndSet(current, current + (label to selection))) return selection
        }
    }
}

/** Whether the bytes at [start] are [other]'s; the caller has checked the length. */
internal fun ByteArray.regionEquals(start: Int, other: ByteArray): Boolean {
    if (start + other.size > size) return false
    for (offset in other.indices) {
        if (this[start + offset] != other[offset]) return false
    }
    return true
}

/**
 * The resolution of a selection that reads no variables, made once and
 * shared by every store: it renders no key, so it holds no store's numbers.
 */
@OptIn(ExperimentalAtomicApi::class)
private object SharedResolutions {
    private val resolutions = AtomicReference<Map<Selection, ResolvedSelection>>(emptyMap())

    fun get(selection: Selection): ResolvedSelection? = resolutions.load()[selection]

    fun put(selection: Selection, resolved: ResolvedSelection): ResolvedSelection {
        while (true) {
            val current = resolutions.load()
            current[selection]?.let { return it }
            if (resolutions.compareAndSet(current, current + (selection to resolved))) return resolved
        }
    }
}

/** One resolution's binding of variables over the store's keys. */
private class Resolver(private val variables: Variables, private val keys: Keys) {
    fun resolve(selection: Selection): ResolvedSelection {
        if (selection.readsVariables) return resolving(selection)
        SharedResolutions.get(selection)?.let { return it }
        return SharedResolutions.put(selection, resolving(selection))
    }

    private fun resolving(selection: Selection): ResolvedSelection {
        val held = if (selection.readsVariables) keys else null
        val listed = HashMap<TypeID, ResolvedVariant>()
        val conditions = ArrayList<Pair<TypeID, List<ResolvedField>>>()
        var others: List<ResolvedField> = emptyList()
        for (variant in selection.variants) {
            val fields = variant.fields.filter { it.selected(variables) }.map { field(it, selection.type) }
            val types = variant.types
            if (types == null) {
                val condition = variant.condition
                if (condition != null) conditions.add(condition to fields) else others = fields
                continue
            }
            for (concrete in types) {
                listed[concrete] = ResolvedVariant(concrete, variant.key ?: selection.key, fields.map { it.on(concrete, held) })
            }
        }
        return ResolvedSelection(selection.type, selection.key, selection.isAbstract, others, listed, conditions, selection.memberships, held, selection.transient)
    }

    private fun field(field: PlanField, type: TypeID): ResolvedField {
        val storageKey = field.fixedStorageKey ?: render(field.key)
        val kind = when (val kind = field.kind) {
            is PlanField.Kind.Scalar -> ResolvedField.Kind.Scalar(kind.kind, kind.list)
            is PlanField.Kind.Linked -> ResolvedField.Kind.Linked(
                resolve(kind.selection),
                kind.plural,
                kind.lookup?.let { lookup ->
                    val parts = lookup.key.map { part ->
                        when (part) {
                            is Lookup.Key.Variable -> variables.keyText(part.name)
                            is Lookup.Key.Literal -> part.text
                        }
                    }
                    LookupKey(lookup.type, lookup.possibleTypes, Record.keyValue(parts))
                },
                kind.connection?.let { connection ->
                    val key = render(connection.key)
                    ResolvedConnection(key, connection.key is StorageKey.Dynamic, slot(connection.key, key, type), connection.slots, mode(connection))
                },
            )
        }
        return ResolvedField(
            responseKey = field.responseKey,
            keyBytes = field.keyBytes,
            storageKey = storageKey,
            rendered = field.key is StorageKey.Dynamic,
            slot = slot(field.key, storageKey, type),
            kind = kind,
            edit = field.edit?.let { ResolvedEdit(it.kind, connections(it.connections), it.edgeType) },
            deferred = field.deferred,
            caught = field.caught,
            client = field.client,
        )
    }

    private fun render(key: StorageKey): String = when (key) {
        is StorageKey.Fixed -> Registry.storageKey(key.slot)
        is StorageKey.Dynamic -> key.key.render(variables)
    }

    private fun slot(key: StorageKey, storageKey: String, type: TypeID): Slot = when (key) {
        is StorageKey.Fixed -> if (key.slot.type == type) key.slot else Registry.slot(type, storageKey)
        is StorageKey.Dynamic -> keys.slot(type, storageKey)
    }

    /** A present `after` appends, a present `before` prepends, neither replaces; a variable given null is not present. */
    private fun mode(connection: ConnectionPlan): ConnectionMode {
        cursor(connection.after)?.let { return ConnectionMode.Append(it.value) }
        cursor(connection.before)?.let { return ConnectionMode.Prepend(it.value) }
        return ConnectionMode.Replace
    }

    private class Present(val value: String?)

    private fun cursor(argument: ConnectionCursor?): Present? = when (argument) {
        null -> null
        ConnectionCursor.Literal -> Present(null)
        is ConnectionCursor.Variable -> {
            val value = variables[argument.name]
            if (value == null || value == Variable.Null) null else Present(value.keyText)
        }
    }

    private fun connections(connections: Edit.Connections?): List<String> = when (connections) {
        null -> emptyList()
        is Edit.Connections.Literal -> connections.ids
        is Edit.Connections.Variable -> when (val value = variables[connections.name]) {
            is Variable.List -> value.values.map { it.keyText }
            is Variable.String -> listOf(value.value)
            else -> emptyList()
        }
    }
}
