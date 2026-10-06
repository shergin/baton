/// Connections: the merge of a page into its connection record and the edge
/// directives' edits, as functions over a batch, where Relay keeps its
/// connection handler. A connection is a client record on the parent that
/// every page merges into, and it owns the edges inserted into it.
extension Store {
    /// The connection an edit may change: in memory, live, and holding what
    /// the image has or more. One the store holds only as an empty record a
    /// link made, or not at all, would be written back with the edit alone
    /// or keep its old edges in the image: the image forgets it instead, so
    /// the next read fetches it.
    func editable(_ key: String) -> Record? {
        if let connection = existing(key), !connection.deleted, connection.hydrated || !connection.isEmpty {
            return connection
        }
        forgets?.keys.append(key)
        return nil
    }

    static func edges(_ record: Record, _ slot: Slot) -> ContiguousArray<Record?> {
        if case .refs(let edges) = record.peek(slot) { return edges }
        return []
    }

    static func node(of edge: Record, _ slot: Slot) -> ObjectIdentifier? {
        if case .ref(let node) = edge.peek(slot) { return ObjectIdentifier(node) }
        return nil
    }

    /// Edges in order with every node at most once; null edges are dropped.
    static func merged(_ first: ContiguousArray<Record?>, _ second: ContiguousArray<Record?>, nodeSlot: Slot) -> ContiguousArray<Record?> {
        var result = ContiguousArray<Record?>()
        result.reserveCapacity(first.count + second.count)
        var seen = Set<ObjectIdentifier>()
        seen.reserveCapacity(first.count + second.count)
        for case let edge? in first {
            if let node = node(of: edge, nodeSlot), !seen.insert(node).inserted { continue }
            result.append(edge)
        }
        for case let edge? in second {
            if let node = node(of: edge, nodeSlot), !seen.insert(node).inserted { continue }
            result.append(edge)
        }
        return result
    }

    /// Merges a page into its connection record, as Relay's connection handler
    /// does: the connection's own fields follow the page; edges replace,
    /// append or prepend by the cursor the page was fetched with, deduplicated
    /// by node; the page info merges per direction. A page fetched after a
    /// cursor that is no longer the end is ignored.
    func merge(_ connection: Record, page: Record, slots: ConnectionSlots, mode: ConnectionMode, _ batch: inout Batch) {
        page.forEachValue { slot, value in
            if slot.index == slots.edges.index || slot.index == slots.pageInfoLink.index { return }
            set(connection, Slot(type: slots.connection, index: slot.index), value, &batch)
        }

        let pageInfo: Record
        if case .ref(let existing) = connection.peek(slots.pageInfoLink) {
            pageInfo = existing
        } else {
            pageInfo = record(key: connection.key + ":pageInfo", type: slots.pageInfo, entity: false)
            set(connection, slots.pageInfoLink, .ref(pageInfo), &batch)
        }
        let existing = Store.edges(connection, slots.edges)
        let incoming = Store.edges(page, slots.edges)
        let merged: ContiguousArray<Record?>
        let copied: [Slot]
        switch mode {
        case .replace:
            merged = Store.merged(incoming, [], nodeSlot: slots.node)
            copied = [slots.hasNextPage, slots.hasPreviousPage, slots.startCursor, slots.endCursor]
        case .append(let after):
            if let after, !existing.isEmpty, case .string(let end) = pageInfo.peek(slots.endCursor), end != after { return }
            merged = Store.merged(existing, incoming, nodeSlot: slots.node)
            copied = [slots.hasNextPage, slots.endCursor]
        case .prepend(let before):
            if let before, !existing.isEmpty, case .string(let start) = pageInfo.peek(slots.startCursor), start != before { return }
            merged = Store.merged(incoming, existing, nodeSlot: slots.node)
            copied = [slots.hasPreviousPage, slots.startCursor]
        }
        set(connection, slots.edges, .refs(merged), &batch)
        if case .ref(let serverPageInfo) = page.peek(slots.pageInfoLink) {
            for slot in copied {
                let value = serverPageInfo.peek(slot)
                if case .missing = value { continue }
                set(pageInfo, slot, value, &batch)
            }
        }
    }

    /// The connection an edge directive names, with the slots the plans
    /// resolved for its type, so the edit looks no key up by name. A record
    /// of a type no connection field describes is not a connection, and the
    /// edit leaves it alone.
    func editableConnection(_ key: String) -> (record: Record, slots: ConnectionSlots)? {
        guard let connection = editable(key), let slots = Registry.connectionSlots(of: connection.type) else { return nil }
        return (connection, slots)
    }

    /// Inserts a copy of a payload's edge into a connection named by id, unless
    /// an edge for the same node is already there. The copy is the
    /// connection's own record, as in Relay: the payload's edge record is
    /// keyed by its path, so the next mutation of the same kind would alias it.
    /// An edge of another type than the connection's, whose slots the
    /// connection's readers do not read, is not inserted.
    func insert(edge: Record, into connectionKey: String, prepend: Bool, _ batch: inout Batch) {
        guard case let (connection, slots)? = editableConnection(connectionKey), edge.type == slots.edge else { return }
        if contains(connection, node: Store.node(of: edge, slots.node), slots) { return }
        let copy = ownEdge(of: connection, slots, &batch)
        edge.forEachValue { slot, value in
            set(copy, Slot(type: slots.edge, index: slot.index), value, &batch)
        }
        append(copy, to: connection, slots, prepend: prepend, &batch)
    }

    /// Wraps a node in a new edge record of the connection and inserts it,
    /// when the edge type the directive names is the connection's.
    func insert(node: Record, edgeType: TypeID, into connectionKey: String, prepend: Bool, _ batch: inout Batch) {
        guard case let (connection, slots)? = editableConnection(connectionKey), edgeType == slots.edge else { return }
        if contains(connection, node: ObjectIdentifier(node), slots) { return }
        let edge = ownEdge(of: connection, slots, &batch)
        set(edge, slots.node, .ref(node), &batch)
        set(edge, slots.cursor, .null, &batch)
        append(edge, to: connection, slots, prepend: prepend, &batch)
    }

    /// A new edge record owned by the connection, numbered by Relay's
    /// `__connection_next_edge_index` client field.
    func ownEdge(of connection: Record, _ slots: ConnectionSlots, _ batch: inout Batch) -> Record {
        let index: Int = if case .int(let index) = connection.peek(slots.nextEdgeIndex) { index } else { 0 }
        set(connection, slots.nextEdgeIndex, .int(index + 1), &batch)
        return record(key: connection.key + ":edges:" + String(index), type: slots.edge, entity: false)
    }

    func contains(_ connection: Record, node: ObjectIdentifier?, _ slots: ConnectionSlots) -> Bool {
        guard let node else { return false }
        for case let edge? in Store.edges(connection, slots.edges) where Store.node(of: edge, slots.node) == node {
            return true
        }
        return false
    }

    func append(_ edge: Record, to connection: Record, _ slots: ConnectionSlots, prepend: Bool, _ batch: inout Batch) {
        var edges = Store.edges(connection, slots.edges)
        if prepend { edges.insert(edge, at: 0) } else { edges.append(edge) }
        set(connection, slots.edges, .refs(edges), &batch)
    }

    /// Removes every edge whose node is an entity with this id, of whatever
    /// type, from a connection named by id.
    func deleteEdges(of id: String, from connectionKey: String, _ batch: inout Batch) {
        guard case let (connection, slots)? = editableConnection(connectionKey) else { return }
        let edges = Store.edges(connection, slots.edges)
        let kept = edges.filter { edge in
            guard let edge, case .ref(let node) = edge.peek(slots.node) else { return true }
            return !node.hasID(id)
        }
        if kept.count == edges.count { return }
        set(connection, slots.edges, .refs(ContiguousArray(kept)), &batch)
    }
}
