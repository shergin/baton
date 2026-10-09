package baton

// Connections: the merge of a page into its connection record and the edge
// directives' edits, as functions over the store and a batch, where Relay
// keeps its connection handler. A connection is a client record on the
// parent that every page merges into, and it owns the edges inserted into
// it. See `spec/runtime.md`, section 4.

/**
 * The connection an edit may change: in memory, live, and holding what
 * the image has or more. One the store holds only as an empty record a
 * link made, or not at all, would be written back with the edit alone or
 * keep its old edges in the image: the image forgets it instead, so the
 * next read fetches it.
 */
internal fun Store.editable(key: String): Pair<Record, ConnectionSlots>? {
    val connection = existing(key)
    if (connection == null || connection.deleted || (connection.isEmpty && !connection.hydrated)) {
        forgets?.keys?.add(key)
        return null
    }
    val slots = Registry.connection(connection.type) ?: return null
    return connection to slots
}

internal fun Store.edges(record: Record, slot: Slot): List<Record?> = (record.peek(slot) as? Value.Refs)?.records ?: emptyList()

internal fun Store.node(edge: Record, slot: Slot): Record? = (edge.peek(slot) as? Value.Ref)?.record

/** Edges in order with every node at most once; null edges dropped. */
internal fun Store.merged(first: List<Record?>, second: List<Record?>, nodeSlot: Slot): List<Record?> {
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
internal fun Store.merge(connection: Record, page: Record, slots: ConnectionSlots, mode: ConnectionMode, batch: Store.Batch) {
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
internal fun Store.insertEdge(edge: Record, connectionKey: String, prepend: Boolean, batch: Store.Batch) {
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
internal fun Store.insertNode(node: Record, edgeType: TypeID, connectionKey: String, prepend: Boolean, batch: Store.Batch) {
    val (connection, slots) = editable(connectionKey) ?: return
    if (edgeType != slots.edge) return
    if (contains(connection, node, slots)) return
    val edge = ownEdge(connection, slots, batch)
    set(edge, slots.node, Value.Ref(node), batch)
    set(edge, slots.cursor, Value.Null, batch)
    append(edge, connection, slots, prepend, batch)
}

/** A new edge record the connection owns, numbered by Relay's `__connection_next_edge_index` client field. */
internal fun Store.ownEdge(connection: Record, slots: ConnectionSlots, batch: Store.Batch): Record {
    val index = (connection.peek(slots.nextEdgeIndex) as? Value.Int)?.value ?: 0L
    set(connection, slots.nextEdgeIndex, Value.Int(index + 1), batch)
    return recordFor(connection.key + ":edges:" + index, slots.edge, -1)
}

internal fun Store.contains(connection: Record, node: Record?, slots: ConnectionSlots): Boolean {
    if (node == null) return false
    return edges(connection, slots.edges).any { edge -> edge != null && node(edge, slots.node) === node }
}

internal fun Store.append(edge: Record, connection: Record, slots: ConnectionSlots, prepend: Boolean, batch: Store.Batch) {
    val edges = edges(connection, slots.edges)
    set(connection, slots.edges, Value.Refs(if (prepend) listOf(edge) + edges else edges + edge), batch)
}

/** Removes every edge whose node is an entity with this id, of whatever type, from a connection named by key. */
internal fun Store.deleteEdges(id: String, connectionKey: String, batch: Store.Batch) {
    val (connection, slots) = editable(connectionKey) ?: return
    val edges = edges(connection, slots.edges)
    val kept = edges.filter { edge -> edge == null || node(edge, slots.node)?.hasID(id) != true }
    if (kept.size == edges.size) return
    set(connection, slots.edges, Value.Refs(kept), batch)
}
