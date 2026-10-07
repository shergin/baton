package baton

/** What the store tells the environment's log: never a record, a value or a variable. See `spec/runtime.md`, section 10. */
internal sealed interface LogEvent {
    /** A server batch committed, with the slots it changed in records that existed before it. */
    data class Committed(val changed: Int) : LogEvent

    /** An incremental part named a place the store or the plan does not have, and was dropped. */
    data class PartDropped(val path: String) : LogEvent

    /** An id names live records of several types, so a directive by bare id did nothing. */
    data class AmbiguousIdentity(val id: String, val types: List<String>) : LogEvent
}

/**
 * The normalized records. The store belongs to the thread that made it, the
 * main thread in an app: its entry points check the caller's thread, and a
 * commit, the only writer, runs there. The ingest runs off it and hands the
 * commit a change set. See `spec/runtime.md`, sections 1 and 4.
 */
internal class Store {
    private val thread = currentThreadId()
    private val records = HashMap<String, Record>()

    /** The record query root fields hang off, typed `Query` whatever the schema calls its root type. */
    val root: Record = Record(Registry.type("Query"), ROOT_KEY)
    /** The record mutation payloads hang off. */
    val mutationRoot: Record = Record(Registry.type("Mutation"), MUTATION_ROOT_KEY)
    /** The record subscription payloads hang off. */
    val subscriptionRoot: Record = Record(Registry.type("Subscription"), SUBSCRIPTION_ROOT_KEY)

    /** The keys the store's session renders from variables. */
    val keys = Keys()

    /**
     * Slots that hold one key, each the other's twin: the store's number for
     * a text and the constant the build named for it afterwards. A write to
     * either lands in both.
     */
    private val twins = HashMap<Slot, Slot>()

    /** The environment's log. */
    var log: ((LogEvent) -> Unit)? = null

    init {
        records[ROOT_KEY] = root
        records[MUTATION_ROOT_KEY] = mutationRoot
        records[SUBSCRIPTION_ROOT_KEY] = subscriptionRoot
    }

    /** Fails a call from a thread other than the store's. */
    fun checkThread() {
        check(currentThreadId() == thread) { "a store is used on the thread that made it" }
    }

    /** The root a response of the operation kind is committed under. */
    fun root(kind: OperationKind): Record = when (kind) {
        OperationKind.QUERY -> root
        OperationKind.MUTATION -> mutationRoot
        OperationKind.SUBSCRIPTION -> subscriptionRoot
    }

    /** Binds an operation's variables under the store's keys: the resolution the ingest and the commit read. */
    fun resolve(plan: Plan, variables: Variables): ResolvedSelection {
        checkThread()
        return plan.resolve(variables, keys)
    }

    val count: Int get() = records.size

    fun existing(key: String): Record? = records[key]

    /** Every record the store holds, by key. */
    fun recordsByKey(): Map<String, Record> {
        checkThread()
        return records
    }

    /**
     * Every value a record holds, by storage key, with its error. A key the
     * store holds at two slots, a rendering and the constant adopted for it,
     * is one field: the rendered half yields to the constant's.
     */
    fun storedFields(record: Record): List<Triple<String, Value, FieldError?>> {
        checkThread()
        val fields = ArrayList<Triple<String, Value, FieldError?>>()
        for ((slot, value, error) in record.storedSlots()) {
            if (slot.index < 0 && twins.containsKey(slot)) continue
            fields.add(Triple(keys.text(slot), value, error))
        }
        return fields
    }

    /** The record for a key, and whether this call made it. */
    private fun record(key: String, type: TypeID, idOffset: Int): Pair<Record, Boolean> {
        records[key]?.let { found ->
            // A key names one type: an entity's starts with it, and a path key under an interface or union ends with it.
            check(found.type == type) { "$key is a ${found.type.name}, not a ${type.name}" }
            return found to false
        }
        val made = Record(type, key, idOffset)
        records[key] = made
        return made to true
    }

    internal fun recordFor(key: String, type: TypeID, idOffset: Int): Record = record(key, type, idOffset).first

    /**
     * One batch of writes. A plain server batch, the only kind before
     * optimistic layers, notifies as it writes, since nothing in it can
     * change back; it counts the slots it changed in records that existed
     * before it, a twin's write once with its twin.
     */
    internal class Batch {
        var changed = 0
        val flagged = HashMap<Record, Boolean>()

        fun touched(twin: Boolean) {
            if (!twin) changed += 1
        }

        /** The records whose deleted flag differs at the end. */
        fun flipped(): Set<Record> = flagged.filter { (record, was) -> record.deleted != was }.keys
    }

    /**
     * Applies a change set from the server and reports how many slots of
     * records that existed before it changed: the memberships are learned,
     * the records found or made, each record's entries written with its
     * errors cleared where the set answers the slot without one, then the
     * edits in the set's order, then the field errors.
     */
    fun commit(changes: ChangeSet): Int {
        checkThread()
        adoptConstants()
        val batch = Batch()
        apply(changes, batch)
        val flipped = batch.flipped()
        if (flipped.isNotEmpty()) {
            // A link to a deleted record reads as null and a list skips it.
            for (record in records.values) record.notifyLinks(flipped)
        }
        log?.invoke(LogEvent.Committed(batch.changed))
        return batch.changed
    }

    /**
     * Adopts the constants the build named after the store rendered their
     * texts: the two slots become twins, the records' values are copied
     * under the constant, and every later write to either lands in both.
     */
    private fun adoptConstants() {
        for ((rendered, dense) in keys.takeAdoptions()) {
            twins[rendered] = dense
            twins[dense] = rendered
            for (record in records.values) {
                if (record.type == rendered.type) record.twin(rendered, dense)
            }
        }
    }

    /** Writes one slot inside a batch, and its twin when it has one. */
    internal fun set(record: Record, slot: Slot, value: Value, batch: Batch) {
        if (record.write(slot, value) != null) batch.touched(twin = false)
        val twin = twins[slot] ?: return
        if (record.write(twin, value) != null) batch.touched(twin = true)
    }

    private fun setError(record: Record, slot: Slot, error: FieldError?, batch: Batch) {
        if (record.setError(slot, error)) batch.touched(twin = false)
        val twin = twins[slot] ?: return
        if (record.setError(twin, error)) batch.touched(twin = true)
    }

    private fun setDeleted(record: Record, deleted: Boolean, batch: Batch) {
        if (record.deleted == deleted) return
        if (!batch.flagged.containsKey(record)) batch.flagged[record] = record.deleted
        record.setDeleted(deleted)
    }

    private fun apply(changes: ChangeSet, batch: Batch) {
        for ((type, condition) in changes.memberships) Membership.learn(type, condition)
        val objects = arrayOfNulls<Record>(changes.recordCount)
        val created = BooleanArray(changes.recordCount)
        for (index in 0 until changes.recordCount) {
            val (record, made) = record(changes.recordKeys[index], changes.recordTypes[index], changes.recordIDOffsets[index])
            objects[index] = record
            created[index] = made
        }

        // Slots this change set carries an error for keep it below rather than clearing it here.
        val erroring = HashSet<Pair<Int, Int>>()
        for (entry in changes.fieldErrors) erroring.add(entry.record to entry.slotIndex)

        val values = changes.values
        for (index in 0 until changes.recordCount) {
            val record = objects[index]!!
            // A deleted record a payload names again comes back.
            if (record.deleted) setDeleted(record, false, batch)
            for (position in changes.starts[index] until changes.starts[index + 1]) {
                val slot = Slot(record.type, changes.entrySlots[position])
                // A field the payload answers without an error has none, whether or not its value changed.
                if (record.hasErrors && record.peekError(slot) != null && (index to slot.index) !in erroring) {
                    setError(record, slot, null, batch)
                }
                val first = values.first[position]
                val second = values.second[position]
                val value: Value = when (values.kinds[position]) {
                    Raw.NULL -> Value.Null
                    Raw.BOOL -> if (first != 0L) Value.True else Value.False
                    Raw.INT -> Value.Int(first)
                    Raw.DOUBLE -> Value.Double(Double.fromBits(first))
                    Raw.STRING, Raw.ESCAPED_STRING -> {
                        val escaped = values.kinds[position] == Raw.ESCAPED_STRING
                        val existing = record.peek(slot)
                        if (existing is Value.String && changes.stringEquals(first.toInt(), second, escaped, existing.value)) continue
                        Value.String(changes.string(first.toInt(), second, escaped))
                    }
                    Raw.REF -> Value.Ref(objects[first.toInt()]!!)
                    Raw.REFS -> Value.Refs(List(second) { offset -> changes.refs[first.toInt() + offset].let { if (it < 0) null else objects[it] } })
                    else -> Value.List(List(second) { offset -> scalar(changes, first.toInt() + offset) })
                }
                if (created[index]) {
                    // Nobody can have read a record this batch made: its slots count among nothing changed.
                    record.write(slot, value)
                    twins[slot]?.let { record.write(it, value) }
                } else {
                    set(record, slot, value, batch)
                }
            }
        }

        for (edit in changes.edits) {
            when (edit) {
                is ChangeSet.Edit.Merge -> merge(objects[edit.connection]!!, objects[edit.page]!!, edit.slots, edit.mode, batch)
                is ChangeSet.Edit.InsertEdge -> for (key in edit.connections) insertEdge(objects[edit.edge]!!, key, edit.prepend, batch)
                is ChangeSet.Edit.InsertNode -> for (key in edit.connections) insertNode(objects[edit.node]!!, edit.edgeType, key, edit.prepend, batch)
                is ChangeSet.Edit.DeleteEdge -> for (key in edit.connections) deleteEdges(edit.id, key, batch)
                is ChangeSet.Edit.DeleteRecord -> {
                    // The directive names a bare id: the record is the one live entity of any type with it.
                    val found = live(edit.id, Registry.typeNames())
                    when (found.size) {
                        0 -> Unit
                        1 -> delete(found[0], batch)
                        else -> log?.invoke(LogEvent.AmbiguousIdentity(edit.id, found.map { it.type.name }))
                    }
                }
            }
        }

        // Field errors land beside the field; an error arriving counts as a change of the slot.
        for (entry in changes.fieldErrors) {
            val record = objects[entry.record]!!
            setError(record, Slot(record.type, entry.slotIndex), entry.error, batch)
        }
    }

    private fun scalar(changes: ChangeSet, position: Int): Value {
        val scalars = changes.scalars
        val first = scalars.first[position]
        return when (scalars.kinds[position]) {
            Raw.BOOL -> if (first != 0L) Value.True else Value.False
            Raw.INT -> Value.Int(first)
            Raw.DOUBLE -> Value.Double(Double.fromBits(first))
            Raw.STRING -> Value.String(changes.string(first.toInt(), scalars.second[position], false))
            Raw.ESCAPED_STRING -> Value.String(changes.string(first.toInt(), scalars.second[position], true))
            else -> Value.Null
        }
    }

    /** Deletes a record: its values are cleared through the batch, and it is marked deleted, so links to it read as null and lists skip it. */
    private fun delete(record: Record, batch: Batch) {
        val slots = ArrayList<Slot>()
        record.forEachValue { slot, _ -> slots.add(slot) }
        for (slot in slots) set(record, slot, Value.Missing, batch)
        setDeleted(record, true, batch)
    }

    /** The live entities with this id among the named types. */
    private fun live(id: String, typeNames: List<String>): List<Record> =
        typeNames.mapNotNull { name -> records[Record.entityKey(name, id)]?.takeIf { !it.deleted } }

    // Connections: the merge of a page into its connection record and the edge directives' edits, where Relay keeps its connection handler.

    /** The connection an edit may change: in memory, live, and holding something. */
    private fun editable(key: String): Pair<Record, ConnectionSlots>? {
        val connection = records[key] ?: return null
        if (connection.deleted || connection.isEmpty) return null
        val slots = Registry.connection(connection.type) ?: return null
        return connection to slots
    }

    private fun edges(record: Record, slot: Slot): List<Record?> = (record.peek(slot) as? Value.Refs)?.records ?: emptyList()

    private fun node(edge: Record, slot: Slot): Record? = (edge.peek(slot) as? Value.Ref)?.record

    /** Edges in order with every node at most once; null edges dropped. */
    private fun merged(first: List<Record?>, second: List<Record?>, nodeSlot: Slot): List<Record?> {
        val result = ArrayList<Record?>(first.size + second.size)
        val seen = HashSet<Record>()
        for (edge in first + second) {
            if (edge == null) continue
            val node = node(edge, nodeSlot)
            if (node != null && !seen.add(node)) continue
            result.add(edge)
        }
        return result
    }

    /**
     * Merges a page into its connection record as Relay's connection handler
     * does: the connection's own fields follow the page's; edges replace,
     * append or prepend by the cursor the page was fetched with,
     * deduplicated by node; the page info merges per direction. A page
     * fetched after a cursor that is no longer the end, or before one no
     * longer the start, is ignored.
     */
    private fun merge(connection: Record, page: Record, slots: ConnectionSlots, mode: ConnectionMode, batch: Batch) {
        val own = ArrayList<Pair<Slot, Value>>()
        page.forEachValue { slot, value ->
            if (slot.index != slots.edges.index && slot.index != slots.pageInfoLink.index) own.add(Slot(slots.connection, slot.index) to value)
        }
        for ((slot, value) in own) set(connection, slot, value, batch)

        val pageInfo = (connection.peek(slots.pageInfoLink) as? Value.Ref)?.record
            ?: recordFor(connection.key + ":pageInfo", slots.pageInfo, -1).also { set(connection, slots.pageInfoLink, Value.Ref(it), batch) }
        val existing = edges(connection, slots.edges)
        val incoming = edges(page, slots.edges)
        val edges: List<Record?>
        val copied: List<Slot>
        when (mode) {
            ConnectionMode.Replace -> {
                edges = merged(incoming, emptyList(), slots.node)
                copied = listOf(slots.hasNextPage, slots.hasPreviousPage, slots.startCursor, slots.endCursor)
            }
            is ConnectionMode.Append -> {
                val end = pageInfo.peek(slots.endCursor)
                if (mode.after != null && existing.isNotEmpty() && end is Value.String && end.value != mode.after) return
                edges = merged(existing, incoming, slots.node)
                copied = listOf(slots.hasNextPage, slots.endCursor)
            }
            is ConnectionMode.Prepend -> {
                val start = pageInfo.peek(slots.startCursor)
                if (mode.before != null && existing.isNotEmpty() && start is Value.String && start.value != mode.before) return
                edges = merged(incoming, existing, slots.node)
                copied = listOf(slots.hasPreviousPage, slots.startCursor)
            }
        }
        set(connection, slots.edges, Value.Refs(edges), batch)
        val serverPageInfo = (page.peek(slots.pageInfoLink) as? Value.Ref)?.record ?: return
        for (slot in copied) {
            val value = serverPageInfo.peek(slot)
            if (value == Value.Missing) continue
            set(pageInfo, slot, value, batch)
        }
    }

    /**
     * Inserts a copy of a payload's edge into a connection named by key,
     * unless an edge for the same node is there. The copy is the
     * connection's own record, as in Relay, since the payload's edge is keyed
     * by its path and the next mutation of the kind would alias it.
     */
    private fun insertEdge(edge: Record, connectionKey: String, prepend: Boolean, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        if (edge.type != slots.edge) return
        if (contains(connection, node(edge, slots.node), slots)) return
        val copy = ownEdge(connection, slots, batch)
        val values = ArrayList<Pair<Slot, Value>>()
        edge.forEachValue { slot, value -> values.add(Slot(slots.edge, slot.index) to value) }
        for ((slot, value) in values) set(copy, slot, value, batch)
        append(copy, connection, slots, prepend, batch)
    }

    /** Wraps a node in a new edge of the connection and inserts it, when the edge type the directive names is the connection's. */
    private fun insertNode(node: Record, edgeType: TypeID, connectionKey: String, prepend: Boolean, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        if (edgeType != slots.edge) return
        if (contains(connection, node, slots)) return
        val edge = ownEdge(connection, slots, batch)
        set(edge, slots.node, Value.Ref(node), batch)
        set(edge, slots.cursor, Value.Null, batch)
        append(edge, connection, slots, prepend, batch)
    }

    /** A new edge record the connection owns, numbered by Relay's `__connection_next_edge_index` client field. */
    private fun ownEdge(connection: Record, slots: ConnectionSlots, batch: Batch): Record {
        val index = (connection.peek(slots.nextEdgeIndex) as? Value.Int)?.value ?: 0L
        set(connection, slots.nextEdgeIndex, Value.Int(index + 1), batch)
        return recordFor(connection.key + ":edges:" + index, slots.edge, -1)
    }

    private fun contains(connection: Record, node: Record?, slots: ConnectionSlots): Boolean {
        if (node == null) return false
        return edges(connection, slots.edges).any { edge -> edge != null && node(edge, slots.node) === node }
    }

    private fun append(edge: Record, connection: Record, slots: ConnectionSlots, prepend: Boolean, batch: Batch) {
        val edges = edges(connection, slots.edges)
        set(connection, slots.edges, Value.Refs(if (prepend) listOf(edge) + edges else edges + edge), batch)
    }

    /** Removes every edge whose node is an entity with this id, of whatever type, from a connection named by key. */
    private fun deleteEdges(id: String, connectionKey: String, batch: Batch) {
        val (connection, slots) = editable(connectionKey) ?: return
        val edges = edges(connection, slots.edges)
        val kept = edges.filter { edge -> edge == null || node(edge, slots.node)?.hasID(id) != true }
        if (kept.size == edges.size) return
        set(connection, slots.edges, Value.Refs(kept), batch)
    }

    /**
     * The record and selection a response path names, from the root: for an
     * incremental part's `path`. Null when the path leads through data the
     * store never received.
     */
    fun walk(path: List<PathSegment>, selection: ResolvedSelection, from: Record = root): Pair<Record, ResolvedSelection>? {
        checkThread()
        var record = from
        var current = selection
        var position = 0
        while (position < path.size) {
            val segment = path[position] as? PathSegment.Name ?: return null
            position += 1
            val field = current.variant(record.type).field(segment.name) ?: return null
            val kind = field.kind as? ResolvedField.Kind.Linked ?: return null
            record = when (val value = record.peek(field.slot)) {
                is Value.Ref -> value.record
                is Value.Refs -> {
                    val index = path.getOrNull(position) as? PathSegment.Index ?: return null
                    position += 1
                    value.records.getOrNull(index.index) ?: return null
                }
                else -> return null
            }
            current = kind.selection
        }
        return record to current
    }

    companion object {
        const val ROOT_KEY = "client:root"
        const val MUTATION_ROOT_KEY = "client:root:mutation"
        const val SUBSCRIPTION_ROOT_KEY = "client:root:subscription"

        /** The key of the root a response of the operation kind is committed under. */
        fun rootKey(kind: OperationKind): String = when (kind) {
            OperationKind.QUERY -> ROOT_KEY
            OperationKind.MUTATION -> MUTATION_ROOT_KEY
            OperationKind.SUBSCRIPTION -> SUBSCRIPTION_ROOT_KEY
        }
    }
}
