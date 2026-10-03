import Foundation

/// A normalized response, not yet in the store: records by key, one flat list
/// of (record, slot, value) entries in arrival order, reference lists in a
/// shared arena, strings as byte ranges into the response, the edits the
/// plan's connections and edge directives ask for, and the field errors the
/// response carried, resolved to the records and slots they name. Nothing is
/// materialized until the commit decides which values won and which changed.
public struct ChangeSet: Sendable {
    public enum RawValue: Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(start: Int32, end: Int32, escaped: Bool)
        case ref(Int32)
        case refs(start: Int32, count: Int32)
        case list(start: Int32, count: Int32)
    }

    public struct Entry: Sendable {
        public let record: Int32
        public let slot: Slot
        public let value: RawValue
    }

    /// What the store does after writing the entries: a connection page's
    /// merge, or an edge directive of a mutation payload. Records are indices
    /// into this change set; connections are named by their record keys.
    public enum Edit: Sendable {
        case merge(connection: Int32, page: Int32, slots: ConnectionSlots, mode: ConnectionMode)
        case insertEdge(edge: Int32, connections: [String], prepend: Bool)
        case insertNode(node: Int32, edgeType: TypeID, connections: [String], prepend: Bool)
        case deleteEdge(id: String, connections: [String])
        case deleteRecord(id: String)
    }

    /// A field error resolved to the record and slot its path names, and
    /// whether a `@catch` on the way there handles it.
    public struct FieldErrorEntry: Sendable {
        public let record: Int32
        public let slot: Slot
        public let error: FieldError
        public let caught: Bool
    }

    public let bytes: [UInt8]
    public internal(set) var recordKeys: ContiguousArray<String> = []
    public internal(set) var recordTypes: ContiguousArray<TypeID> = []
    /// Whether the record is an entity keyed `Type:id`, for the store's id index.
    public internal(set) var recordIsEntity: ContiguousArray<Bool> = []
    /// Entries grouped by record, one per slot: the last value the response
    /// gave. In arrival order until the ingest groups them at its end.
    public internal(set) var entries: ContiguousArray<Entry> = []
    /// The entries of record `i` are `entries[starts[i]..<starts[i + 1]]`.
    public internal(set) var starts: ContiguousArray<Int32> = []
    public internal(set) var refs: ContiguousArray<Int32> = []
    public internal(set) var scalars: ContiguousArray<RawValue> = []
    public internal(set) var edits: ContiguousArray<Edit> = []
    public internal(set) var fieldErrors: ContiguousArray<FieldErrorEntry> = []
    /// Errors the response carried without a path, or with one that names
    /// no field it selected: nothing in the store holds them.
    public internal(set) var unplacedErrors: [FieldError] = []
    var index: [String: Int32] = [:]

    /// Reserves by the response's size: the Rick and Morty fixture writes an
    /// entry per 33 bytes, a record per 760 and a list element per 250, and
    /// the estimates round each up.
    init(bytes: [UInt8]) {
        self.bytes = bytes
        let records = bytes.count / 512 + 4
        index.reserveCapacity(records)
        recordKeys.reserveCapacity(records)
        recordTypes.reserveCapacity(records)
        recordIsEntity.reserveCapacity(records)
        entries.reserveCapacity(bytes.count / 24 + 8)
        refs.reserveCapacity(bytes.count / 128 + 4)
    }

    /// Groups the entries by record and keeps the last one per slot, each at
    /// the place of the slot's first entry: an entity that appears at many
    /// paths is written once. A stable counting sort, then one pass per
    /// record; it runs where the ingest does, off the main actor.
    mutating func group() {
        let recordCount = recordKeys.count
        let total = entries.count
        var grouped = ContiguousArray<Int32>(repeating: 0, count: recordCount + 1)
        var sorted = ContiguousArray<Entry>()
        var kept = 0
        entries.withUnsafeBufferPointer { source in
            var highest: Int32 = -1
            var counts = ContiguousArray<Int32>(repeating: 0, count: recordCount + 1)
            counts.withUnsafeMutableBufferPointer { counts in
                for entry in source {
                    counts[Int(entry.record) &+ 1] &+= 1
                    if entry.slot.index > highest { highest = entry.slot.index }
                }
                for index in 0..<recordCount { counts[index &+ 1] &+= counts[index] }
            }
            var next = counts
            sorted = ContiguousArray<Entry>(unsafeUninitializedCapacity: total) { buffer, initialized in
                next.withUnsafeMutableBufferPointer { next in
                    for entry in source {
                        let record = Int(entry.record)
                        (buffer.baseAddress! + Int(next[record])).initialize(to: entry)
                        next[record] &+= 1
                    }
                }
                initialized = total
            }
            // The record that last kept each slot index, and where it kept it.
            var keeper = ContiguousArray<Int32>(repeating: -1, count: Int(highest) + 1)
            var place = ContiguousArray<Int32>(repeating: 0, count: Int(highest) + 1)
            sorted.withUnsafeMutableBufferPointer { sorted in
                keeper.withUnsafeMutableBufferPointer { keeper in
                    place.withUnsafeMutableBufferPointer { place in
                        for record in 0..<recordCount {
                            grouped[record] = Int32(kept)
                            for position in Int(counts[record])..<Int(counts[record &+ 1]) {
                                let entry = sorted[position]
                                let index = Int(entry.slot.index)
                                if keeper[index] == Int32(record) {
                                    sorted[Int(place[index])] = entry
                                } else {
                                    keeper[index] = Int32(record)
                                    place[index] = Int32(kept)
                                    sorted[kept] = entry
                                    kept &+= 1
                                }
                            }
                        }
                    }
                }
            }
        }
        grouped[recordCount] = Int32(kept)
        sorted.removeLast(total - kept)
        entries = sorted
        starts = grouped
    }

    /// The entry of a record's slot, once grouped.
    func entry(_ record: Int32, _ slot: Slot) -> Entry? {
        for position in Int(starts[Int(record)])..<Int(starts[Int(record) + 1])
        where entries[position].slot.index == slot.index {
            return entries[position]
        }
        return nil
    }

    /// The field errors no `@catch` handles, placed or not; they fail a
    /// `@throwOnFieldError` operation.
    public var uncaughtFieldErrors: [FieldError] {
        fieldErrors.filter { !$0.caught }.map(\.error) + unplacedErrors
    }

    @inline(__always)
    mutating func record(for key: String, type: TypeID, entity: Bool) -> Int32 {
        if let id = index[key] { return id }
        let id = Int32(recordKeys.count)
        recordKeys.append(key)
        recordTypes.append(type)
        recordIsEntity.append(entity)
        index[key] = id
        return id
    }

    /// Decodes a string value from the response bytes.
    public func string(_ start: Int32, _ end: Int32, escaped: Bool) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            Ingest.materialize(base: buffer.baseAddress!, Int(start), Int(end), escaped)
        }
    }

    /// Whether the string at the range equals `other`, without allocating.
    public func stringEquals(_ start: Int32, _ end: Int32, escaped: Bool, _ other: String) -> Bool {
        if escaped { return string(start, end, escaped: escaped) == other }
        let length = Int(end - start)
        var other = other
        return other.withUTF8 { otherBytes in
            otherBytes.count == length && bytes.withUnsafeBufferPointer { buffer in
                memcmp(buffer.baseAddress! + Int(start), otherBytes.baseAddress!, length) == 0
            }
        }
    }
}

public struct IngestError: Error, CustomStringConvertible, Sendable {
    public let offset: Int
    public let message: String
    public var description: String { "ingest error at byte \(offset): \(message)" }
}

/// Decodes a GraphQL response straight into a change set, following a resolved
/// plan. One pass, no intermediate tree, no model.
public enum Ingest {
    /// One step of a response path: a field by response key, or a list index.
    public enum PathSegment: Sendable, Hashable {
        case name(String)
        case index(Int)
    }

    /// A deferred part's content: the items it delivers, the parts it
    /// announces, and whether more follow. Reads the June 2023 incremental
    /// format (`incremental[{data, path, label}]`), the 2024 one
    /// (`pending[{id, path, label}]`, `incremental[{id, data}]`), and Relay's
    /// (`{data, path, label}` per part).
    public struct IncrementalPart: Sendable {
        public struct Item: Sendable {
            public var path: [PathSegment]?
            public var label: String?
            public var id: String?
            public var data: Data
        }

        public struct Pending: Sendable {
            public var id: String
            public var path: [PathSegment]
            public var label: String?
        }

        public var items: [Item] = []
        public var pending: [Pending] = []
        public var hasNext = false
    }

    public static func normalize(_ data: Data, plan: ResolvedSelection, rootKey: String = Store.rootKey) throws -> ChangeSet {
        let bytes = [UInt8](data)
        // The change set is made inside the cursor and moved out, so no copy
        // is held while the cursor appends and nothing is copied on write.
        return try bytes.withUnsafeBufferPointer { buffer in
            var cursor = Cursor(base: buffer.baseAddress!, count: buffer.count, changes: ChangeSet(bytes: bytes))
            try cursor.run(root: plan, rootKey: rootKey)
            return cursor.changes
        }
    }

    /// Normalizes a response off the caller's actor and inside the caller's
    /// task, so the caller's cancellation and priority reach it.
    @concurrent
    nonisolated static func normalized(_ data: Data, plan: ResolvedSelection, rootKey: String = Store.rootKey) async throws -> ChangeSet {
        try normalize(data, plan: plan, rootKey: rootKey)
    }

    /// Normalizes one object, as a deferred part delivers it: the selection
    /// the part fills, at the record its path named, read as that record's
    /// concrete type.
    public static func normalizeObject(_ data: Data, plan: ResolvedSelection, key: String, type: TypeID, entity: Bool) throws -> ChangeSet {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { buffer in
            var cursor = Cursor(base: buffer.baseAddress!, count: buffer.count, changes: ChangeSet(bytes: bytes))
            cursor.skipWhitespace()
            let rootID = cursor.changes.record(for: key, type: type, entity: entity)
            _ = try cursor.object(plan: plan, parent: rootID, slot: nil, listIndex: nil, depth: 0, fixedRecord: rootID)
            cursor.changes.group()
            return cursor.changes
        }
    }

    /// Reads a part of an incremental response after the first.
    public static func incremental(_ data: Data) throws -> IncrementalPart {
        let bytes = [UInt8](data)
        var part = IncrementalPart()
        try bytes.withUnsafeBufferPointer { buffer in
            var scanner = Scanner(base: buffer.baseAddress!, count: buffer.count)
            var topLevel = IncrementalPart.Item(path: nil, label: nil, id: nil, data: Data())
            var sawTopLevelData = false
            try scanner.members { key, scanner in
                switch key {
                case "incremental":
                    try scanner.elements { scanner in
                        var item = IncrementalPart.Item(path: nil, label: nil, id: nil, data: Data())
                        try scanner.members { key, scanner in
                            switch key {
                            case "data": item.data = try scanner.rawValue(in: bytes)
                            case "path": item.path = try scanner.path()
                            case "label": item.label = try scanner.stringValue()
                            case "id": item.id = try scanner.stringValue()
                            default: try scanner.skipValue()
                            }
                        }
                        part.items.append(item)
                    }
                case "pending":
                    try scanner.elements { scanner in
                        var pending = IncrementalPart.Pending(id: "", path: [], label: nil)
                        try scanner.members { key, scanner in
                            switch key {
                            case "id": pending.id = try scanner.stringValue() ?? ""
                            case "path": pending.path = try scanner.path() ?? []
                            case "label": pending.label = try scanner.stringValue()
                            default: try scanner.skipValue()
                            }
                        }
                        part.pending.append(pending)
                    }
                case "hasNext": part.hasNext = try scanner.parseBool()
                case "data":
                    sawTopLevelData = true
                    topLevel.data = try scanner.rawValue(in: bytes)
                case "path": topLevel.path = try scanner.path()
                case "label": topLevel.label = try scanner.stringValue()
                default: try scanner.skipValue()
                }
            }
            if sawTopLevelData, topLevel.path != nil {
                part.items.append(topLevel)
            }
        }
        return part
    }

    /// Reads a `graphql-transport-ws` frame: its type, id and payload bytes.
    public static func frame(_ data: Data) throws -> (type: String?, id: String?, payload: Data?) {
        let bytes = [UInt8](data)
        var type: String?
        var id: String?
        var payload: Data?
        try bytes.withUnsafeBufferPointer { buffer in
            var scanner = Scanner(base: buffer.baseAddress!, count: buffer.count)
            try scanner.members { key, scanner in
                switch key {
                case "type": type = try scanner.stringValue()
                case "id": id = try scanner.stringValue()
                case "payload": payload = try scanner.rawValue(in: bytes)
                default: try scanner.skipValue()
                }
            }
        }
        return (type, id, payload)
    }

    /// The plan-driven reader: a scanner over the response, and the change set
    /// it fills by the plan.
    struct Cursor {
        var scanner: Scanner
        var changes: ChangeSet
        /// One scratch buffer per nesting depth: (field index, value). Slots are
        /// resolved when the object ends, because abstract selections resolve
        /// them against the concrete type the payload names. Made when the
        /// walk first reaches the depth, and reused after.
        var scratch: [ContiguousArray<(Int, ChangeSet.RawValue)>] = []
        /// Client fields written beside the object's own, per depth: the
        /// connection links, by storage key and declared slot.
        var extra: [ContiguousArray<(String, Slot, ChangeSet.RawValue)>] = []
        /// How deep a selection may nest.
        static let depthLimit = 24
        /// The response's `errors`, as read; resolved against the plan at the end.
        var rawErrors: [(message: String, path: [PathSegment]?)] = []

        init(base: UnsafePointer<UInt8>, count: Int, changes: ChangeSet) {
            scanner = Scanner(base: base, count: count)
            self.changes = changes
        }

        var base: UnsafePointer<UInt8> { scanner.base }
        var position: Int {
            get { scanner.position }
            set { scanner.position = newValue }
        }

        // The lexical layer, which the scanner holds.
        @inline(__always) func peek() -> UInt8 { scanner.peek() }
        @inline(__always) mutating func skipWhitespace() { scanner.skipWhitespace() }
        @inline(__always) mutating func expect(_ byte: UInt8) throws { try scanner.expect(byte) }
        @inline(__always) mutating func scanString() throws -> (Int, Int, Bool) { try scanner.scanString() }
        @inline(__always) mutating func literal(_ text: StaticString) throws { try scanner.literal(text) }
        @inline(__always) mutating func skipValue() throws { try scanner.skipValue() }
        mutating func parseInt() throws -> Int { try scanner.parseInt() }
        mutating func parseDouble() throws -> Double { try scanner.parseDouble() }
        mutating func parseBool() throws -> Bool { try scanner.parseBool() }

        mutating func run(root: ResolvedSelection, rootKey: String) throws {
            skipWhitespace()
            var sawData = false
            var rootID: Int32 = -1
            try members { key, cursor in
                switch key {
                case "data":
                    if cursor.peek() == 0x6E {
                        try cursor.literal("null")
                    } else {
                        rootID = cursor.changes.record(for: rootKey, type: root.type, entity: false)
                        _ = try cursor.object(plan: root, parent: rootID, slot: nil, listIndex: nil, depth: 0, fixedRecord: rootID)
                        sawData = true
                    }
                case "errors":
                    try cursor.errors()
                default:
                    try cursor.skipValue()
                }
            }
            if !sawData {
                if !rawErrors.isEmpty { throw GraphQLErrors(messages: rawErrors.map(\.message)) }
                throw IngestError(offset: position, message: "no data in response")
            }
            changes.group()
            if !rawErrors.isEmpty {
                resolveErrors(root: root, rootID: rootID)
            }
        }

        /// Iterates an object's members, leaving each value to the handler.
        mutating func members(_ handle: (String, inout Cursor) throws -> Void) throws {
            skipWhitespace()
            try expect(0x7B)
            while true {
                skipWhitespace()
                let byte = peek()
                if byte == 0x7D { position += 1; return }
                if byte == 0x2C { position += 1; continue }
                let (start, end, escaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()
                try handle(Ingest.materialize(base: base, start, end, escaped), &self)
            }
        }

        /// The response's `errors` array: messages and paths.
        mutating func errors() throws {
            scanner.skipWhitespace()
            if scanner.peek() == 0x6E { try scanner.literal("null"); return }
            var read: [(message: String, path: [PathSegment]?)] = []
            try scanner.elements { scanner in
                var message = ""
                var path: [PathSegment]?
                try scanner.members { key, scanner in
                    switch key {
                    case "message": message = try scanner.stringValue() ?? ""
                    case "path": path = try scanner.path()
                    default: try scanner.skipValue()
                    }
                }
                read.append((message, path))
            }
            rawErrors.append(contentsOf: read)
        }

        /// Resolves each error's path through the plan and the entries to the
        /// record and slot it names. The walk stops at a field whose value is
        /// null, a link the response does not continue, or a list index it
        /// does not have, and the error lands on the last field it reached:
        /// with GraphQL's null propagation, that is the nullable ancestor.
        mutating func resolveErrors(root: ResolvedSelection, rootID: Int32) {
            for (message, path) in rawErrors {
                let rendered = (path ?? []).map { segment in
                    switch segment {
                    case .name(let name): name
                    case .index(let offset): String(offset)
                    }
                }.joined(separator: ".")
                let error = FieldError(message: message, path: rendered)
                guard let path, !path.isEmpty else {
                    changes.unplacedErrors.append(error)
                    continue
                }
                var record = rootID
                var selection = root
                var caught = false
                var resolved: (Int32, Slot)?
                var segments = path[...]
                walk: while let segment = segments.popFirst() {
                    let variant = selection.variant(for: changes.recordTypes[Int(record)])
                    guard case .name(let name) = segment, let index = variant.field(named: name) else { break walk }
                    let field = variant.fields[index]
                    caught = caught || field.caught
                    let slot = field.slot
                    resolved = (record, slot)
                    guard case .linked(let child, _, _, _) = field.kind, let entry = changes.entry(record, slot) else { break walk }
                    switch entry.value {
                    case .ref(let target):
                        record = target
                        selection = child
                    case .refs(let start, let count):
                        guard case .index(let offset)? = segments.first, offset >= 0, offset < Int(count) else { break walk }
                        segments.removeFirst()
                        let target = changes.refs[Int(start) + offset]
                        if target < 0 { break walk }
                        record = target
                        selection = child
                    default:
                        break walk
                    }
                }
                guard let (record, slot) = resolved else {
                    changes.unplacedErrors.append(error)
                    continue
                }
                changes.fieldErrors.append(ChangeSet.FieldErrorEntry(record: record, slot: slot, error: error, caught: caught))
            }
        }

        /// Parses one object against a selection; appends its entries; returns its record.
        ///
        /// Entities are keyed `Type:id`. For a selection on an interface or
        /// union the record's type is the payload's `__typename`, settled
        /// before any key is matched, because it picks the variant the object
        /// is read with: its fields and their slots. Relay prints `__typename`
        /// first, so settling it reads one key. The `id` may arrive anywhere:
        /// Relay prints the `id` it adds last, and an optimistic response
        /// sorts its keys.
        mutating func object(plan: ResolvedSelection, parent: Int32, slot: Slot?, listIndex: Int?, depth: Int, fixedRecord: Int32?) throws -> Int32 {
            try expect(0x7B)
            guard depth < Cursor.depthLimit else { throw IngestError(offset: position, message: "selection nested deeper than 24 levels") }
            if depth == scratch.count {
                var buffer = ContiguousArray<(Int, ChangeSet.RawValue)>()
                buffer.reserveCapacity(16)
                scratch.append(buffer)
                extra.append([])
            } else {
                scratch[depth].removeAll(keepingCapacity: true)
                extra[depth].removeAll(keepingCapacity: true)
            }
            var record: Int32 = fixedRecord ?? -1
            var concreteType = fixedRecord.map { changes.recordTypes[Int($0)] } ?? plan.type
            var pendingID: (Int, Int, Bool)? = nil
            if plan.isAbstract, fixedRecord == nil {
                try identity(of: plan, afterValue: false, wantsID: false, concreteType: &concreteType, pendingID: &pendingID)
            }
            var expected = 0
            let fields = plan.variant(for: concreteType).fields
            let fieldCount = fields.count
            while true {
                skipWhitespace()
                let byte = peek()
                if byte == 0x7D { position += 1; break }
                if byte == 0x2C { position += 1; continue }
                let (keyStart, keyEnd, keyEscaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()

                var matched: Int = -1
                let keyLength = keyEnd - keyStart
                if !keyEscaped {
                    if expected < fieldCount, fields[expected].keyBytes.count == keyLength, keyMatches(fields[expected], keyStart) {
                        matched = expected
                        expected += 1
                    } else {
                        for index in 0..<fieldCount where fields[index].keyBytes.count == keyLength && keyMatches(fields[index], keyStart) {
                            matched = index
                            expected = index + 1
                            break
                        }
                    }
                }
                guard matched >= 0 else { try skipValue(); continue }
                let field = fields[matched]

                if field.isTypename {
                    // The record's type, settled before the first key.
                    try skipValue()
                    continue
                }

                switch field.kind {
                case .scalar(let scalar, let list):
                    if peek() == 0x6E {
                        try literal("null")
                        scratch[depth].append((matched, .null))
                        continue
                    }
                    if list {
                        try expect(0x5B)
                        let start = Int32(changes.scalars.count)
                        var items = 0
                        while true {
                            skipWhitespace()
                            let next = peek()
                            if next == 0x5D { position += 1; break }
                            if next == 0x2C { position += 1; continue }
                            if next == 0x6E {
                                try literal("null")
                                changes.scalars.append(.null)
                                items += 1
                                continue
                            }
                            let value = try scalarValue(scalar)
                            changes.scalars.append(value)
                            items += 1
                            if let handle = field.handle { deletion(handle, value) }
                        }
                        scratch[depth].append((matched, .list(start: start, count: Int32(items))))
                        continue
                    }
                    let value = try scalarValue(scalar)
                    if plan.hasID && field.keyBytes.count == 2 && field.keyBytes[0] == 0x69 && field.keyBytes[1] == 0x64,
                       case .string(let start, let end, let escaped) = value, record < 0 {
                        record = changes.record(for: concreteType.name + ":" + Ingest.materialize(base: base, Int(start), Int(end), escaped), type: concreteType, entity: true)
                    }
                    scratch[depth].append((matched, value))
                    if let handle = field.handle { deletion(handle, value) }
                case .linked(let child, let plural, _, let connection):
                    if peek() == 0x6E {
                        try literal("null")
                        scratch[depth].append((matched, .null))
                        continue
                    }
                    if record < 0 {
                        // A child's key may be a path through this object, so the
                        // object's own key is settled before the child is read.
                        try identity(of: plan, afterValue: true, wantsID: true, concreteType: &concreteType, pendingID: &pendingID)
                        record = settle(plan: plan, concreteType: concreteType, pendingID: pendingID, parent: parent, slot: slot, listIndex: listIndex)
                    }
                    if plural {
                        try expect(0x5B)
                        var collected: [Int32] = []
                        var index = 0
                        while true {
                            skipWhitespace()
                            let next = peek()
                            if next == 0x5D { position += 1; break }
                            if next == 0x2C { position += 1; continue }
                            if next == 0x6E { try literal("null"); collected.append(-1); index += 1; continue }
                            collected.append(try object(plan: child, parent: record, slot: field.slot, listIndex: index, depth: depth + 1, fixedRecord: nil))
                            index += 1
                        }
                        let start = Int32(changes.refs.count)
                        changes.refs.append(contentsOf: collected)
                        scratch[depth].append((matched, .refs(start: start, count: Int32(collected.count))))
                        if let handle = field.handle {
                            for target in collected where target >= 0 { insertion(handle, target) }
                        }
                    } else {
                        let childRecord = try object(plan: child, parent: record, slot: field.slot, listIndex: nil, depth: depth + 1, fixedRecord: nil)
                        scratch[depth].append((matched, .ref(childRecord)))
                        if let connection {
                            // The page is the server's field; the connection record it
                            // merges into hangs off the parent by Relay's handle key.
                            let connectionRecord = changes.record(for: changes.recordKeys[Int(record)] + ":" + connection.storageKey, type: child.type, entity: false)
                            extra[depth].append((connection.storageKey, connection.slot, .ref(connectionRecord)))
                            changes.edits.append(.merge(connection: connectionRecord, page: childRecord, slots: connection.slots, mode: connection.mode))
                        }
                        if let handle = field.handle { insertion(handle, childRecord) }
                    }
                }
            }
            if record < 0 {
                record = settle(plan: plan, concreteType: concreteType, pendingID: pendingID, parent: parent, slot: slot, listIndex: listIndex)
            }
            for (index, value) in scratch[depth] {
                changes.entries.append(ChangeSet.Entry(record: record, slot: fields[index].slot, value: value))
            }
            for (_, slot, value) in extra[depth] {
                changes.entries.append(ChangeSet.Entry(record: record, slot: slot, value: value))
            }
            return record
        }

        /// Records the edit an edge directive asks for on a linked field's record.
        mutating func insertion(_ handle: ResolvedHandle, _ target: Int32) {
            switch handle.kind {
            case .appendEdge:
                changes.edits.append(.insertEdge(edge: target, connections: handle.connections, prepend: false))
            case .prependEdge:
                changes.edits.append(.insertEdge(edge: target, connections: handle.connections, prepend: true))
            case .appendNode:
                if let edgeType = handle.edgeType {
                    changes.edits.append(.insertNode(node: target, edgeType: edgeType, connections: handle.connections, prepend: false))
                }
            case .prependNode:
                if let edgeType = handle.edgeType {
                    changes.edits.append(.insertNode(node: target, edgeType: edgeType, connections: handle.connections, prepend: true))
                }
            case .deleteEdge, .deleteRecord:
                return
            }
        }

        /// Records the edit a delete directive asks for on an id value.
        mutating func deletion(_ handle: ResolvedHandle, _ value: ChangeSet.RawValue) {
            guard case .string(let start, let end, let escaped) = value else { return }
            let id = Ingest.materialize(base: base, Int(start), Int(end), escaped)
            switch handle.kind {
            case .deleteRecord:
                changes.edits.append(.deleteRecord(id: id))
            case .deleteEdge:
                changes.edits.append(.deleteEdge(id: id, connections: handle.connections))
            default:
                return
            }
        }

        @inline(__always)
        func keyMatches(_ field: ResolvedField, _ keyStart: Int) -> Bool {
            field.keyBytes.withUnsafeBufferPointer { key in
                memcmp(base + keyStart, key.baseAddress!, key.count) == 0
            }
        }

        /// Finds what an object's identity still lacks among its members, and
        /// leaves the cursor where it was: the `__typename` of an abstract
        /// selection, from the object's first member, before any key is
        /// matched; the `id`, from the member after the one at the cursor,
        /// which is a link's value. Without the id an entity whose `id`
        /// follows a link would be keyed by its path, apart from the record
        /// every other operation writes.
        mutating func identity(of plan: ResolvedSelection, afterValue: Bool, wantsID: Bool, concreteType: inout TypeID, pendingID: inout (Int, Int, Bool)?) throws {
            var needsID = wantsID && plan.hasID && pendingID == nil
            var needsType = plan.isAbstract && concreteType == plan.type
            guard needsID || needsType else { return }
            let resume = position
            defer { position = resume }
            let typename: StaticString = "__typename"
            if afterValue { try skipValue() }
            while needsID || needsType {
                skipWhitespace()
                let byte = peek()
                if byte == 0x7D { return }
                if byte == 0x2C { position += 1; continue }
                let (keyStart, keyEnd, keyEscaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()
                let keyLength = keyEnd - keyStart
                let isID = !keyEscaped && keyLength == 2 && base[keyStart] == 0x69 && base[keyStart + 1] == 0x64
                // An id of a custom scalar may be a number: its text keys the
                // record, as it does when the id comes before the link.
                if needsID, isID, peek() == 0x2D || (peek() >= 0x30 && peek() <= 0x39) {
                    let start = position
                    try skipValue()
                    pendingID = (start, position, false)
                    needsID = false
                    continue
                }
                guard !keyEscaped, peek() == 0x22 else { try skipValue(); continue }
                let (start, end, escaped) = try scanString()
                if needsID, isID {
                    pendingID = (start, end, escaped)
                    needsID = false
                } else if needsType, keyLength == typename.utf8CodeUnitCount, memcmp(base + keyStart, typename.utf8Start, keyLength) == 0 {
                    concreteType = Registry.type(Ingest.materialize(base: base, start, end, escaped))
                    needsType = false
                }
            }
        }

        /// The record for an object whose key is not settled yet: an entity key
        /// when an id was seen, else a client id from the path. Under an
        /// interface or union the path key ends in the concrete type, so a
        /// payload of another type at the same path is another record.
        @inline(__always)
        mutating func settle(plan: ResolvedSelection, concreteType: TypeID, pendingID: (Int, Int, Bool)?, parent: Int32, slot: Slot?, listIndex: Int?) -> Int32 {
            if let (start, end, escaped) = pendingID {
                return changes.record(for: concreteType.name + ":" + Ingest.materialize(base: base, start, end, escaped), type: concreteType, entity: true)
            }
            var key = changes.recordKeys[Int(parent)] + ":" + (slot.map(Registry.storageKey) ?? "")
            if let listIndex { key += ":" + String(listIndex) }
            if plan.isAbstract { key += ":" + concreteType.name }
            return changes.record(for: key, type: concreteType, entity: false)
        }

        mutating func scalarValue(_ scalar: ScalarKind) throws -> ChangeSet.RawValue {
            switch scalar {
            case .string:
                let (start, end, escaped) = try scanString()
                return .string(start: Int32(start), end: Int32(end), escaped: escaped)
            case .int: return .int(try parseInt())
            case .double: return .double(try parseDouble())
            case .bool: return .bool(try parseBool())
            case .custom:
                // A custom scalar is its text: a string's contents, or the
                // bytes of any other token as the server wrote them. Nothing
                // is parsed, so no value is rounded or dropped.
                if peek() == 0x22 {
                    let (start, end, escaped) = try scanString()
                    return .string(start: Int32(start), end: Int32(end), escaped: escaped)
                }
                let start = position
                try skipValue()
                return .string(start: Int32(start), end: Int32(position), escaped: false)
            }
        }
    }

    /// The lexical layer over response bytes: a position and the reads that
    /// move it. A frame, an incremental part's envelope and the `errors`
    /// array need nothing more; the cursor adds the plan-driven part.
    struct Scanner {
        let base: UnsafePointer<UInt8>
        let count: Int
        var position = 0

        init(base: UnsafePointer<UInt8>, count: Int) {
            self.base = base
            self.count = count
        }

        /// Iterates an object's members, leaving each value to the handler.
        mutating func members(_ handle: (String, inout Scanner) throws -> Void) throws {
            skipWhitespace()
            try expect(0x7B)
            while true {
                skipWhitespace()
                let byte = peek()
                if byte == 0x7D { position += 1; return }
                if byte == 0x2C { position += 1; continue }
                let (start, end, escaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()
                try handle(Ingest.materialize(base: base, start, end, escaped), &self)
            }
        }

        /// Iterates an array's elements, leaving each to the handler.
        mutating func elements(_ handle: (inout Scanner) throws -> Void) throws {
            skipWhitespace()
            try expect(0x5B)
            while true {
                skipWhitespace()
                let byte = peek()
                if byte == 0x5D { position += 1; return }
                if byte == 0x2C { position += 1; continue }
                try handle(&self)
            }
        }

        /// A string value, or nil for `null`.
        mutating func stringValue() throws -> String? {
            skipWhitespace()
            if peek() == 0x6E { try literal("null"); return nil }
            let (start, end, escaped) = try scanString()
            return Ingest.materialize(base: base, start, end, escaped)
        }

        /// The bytes of one value, verbatim.
        mutating func rawValue(in bytes: [UInt8]) throws -> Data {
            skipWhitespace()
            let start = position
            try skipValue()
            return Data(bytes[start..<position])
        }

        /// A response path: strings and integers. A path with an index that
        /// is not an integer names nothing; the response it came with is
        /// read all the same.
        mutating func path() throws -> [PathSegment]? {
            skipWhitespace()
            if peek() == 0x6E { try literal("null"); return nil }
            var segments: [PathSegment] = []
            var readable = true
            try elements { scanner in
                if scanner.peek() == 0x22 {
                    let (start, end, escaped) = try scanner.scanString()
                    segments.append(.name(Ingest.materialize(base: scanner.base, start, end, escaped)))
                    return
                }
                let start = scanner.position
                if let index = try? scanner.parseInt() {
                    segments.append(.index(index))
                    return
                }
                scanner.position = start
                try scanner.skipValue()
                readable = false
            }
            return readable ? segments : nil
        }

        @inline(__always) func peek() -> UInt8 { position < count ? base[position] : 0 }

        @inline(__always)
        mutating func skipWhitespace() {
            while position < count {
                let byte = base[position]
                if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { position += 1 } else { return }
            }
        }

        @inline(__always)
        mutating func expect(_ byte: UInt8) throws {
            guard position < count, base[position] == byte else {
                throw IngestError(offset: position, message: "expected '\(Character(UnicodeScalar(byte)))'")
            }
            position += 1
        }

        @inline(__always)
        mutating func scanString() throws -> (Int, Int, Bool) {
            try expect(0x22)
            let start = position
            var escaped = false
            while position < count {
                let byte = base[position]
                if byte == 0x22 { let end = position; position += 1; return (start, end, escaped) }
                if byte == 0x5C { escaped = true; position += 2 } else { position += 1 }
            }
            throw IngestError(offset: start, message: "unterminated string")
        }

        /// An integer that fits `Int`. A fraction, an exponent or a value out
        /// of range is an error, not a rounding: an `Int` field holds what the
        /// server sent or nothing.
        mutating func parseInt() throws -> Int {
            let start = position
            var negative = false
            if peek() == 0x2D { negative = true; position += 1 }
            // The magnitude, so that `Int.min` reads without overflowing.
            var magnitude: UInt64 = 0
            var overflow = false
            var digits = 0
            while position < count, base[position] >= 0x30, base[position] <= 0x39 {
                let (scaled, scaleOverflow) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, sumOverflow) = scaled.addingReportingOverflow(UInt64(base[position] - 0x30))
                overflow = overflow || scaleOverflow || sumOverflow
                magnitude = sum
                position += 1
                digits += 1
            }
            if digits == 0 { throw IngestError(offset: position, message: "expected a number") }
            if position < count, base[position] == 0x2E || base[position] == 0x65 || base[position] == 0x45 {
                throw IngestError(offset: start, message: "expected an integer")
            }
            let limit = negative ? UInt64(Int.max) + 1 : UInt64(Int.max)
            if overflow || magnitude > limit {
                throw IngestError(offset: start, message: "integer out of range")
            }
            return negative ? Int(truncatingIfNeeded: 0 &- magnitude) : Int(magnitude)
        }

        mutating func parseDouble() throws -> Double {
            let start = position
            while position < count {
                let byte = base[position]
                if (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x65 || byte == 0x45 {
                    position += 1
                } else {
                    break
                }
            }
            guard position > start else { throw IngestError(offset: position, message: "expected a number") }
            var buffer = [CChar](repeating: 0, count: position - start + 1)
            for offset in 0..<(position - start) { buffer[offset] = CChar(bitPattern: base[start + offset]) }
            return strtod(buffer, nil)
        }

        mutating func parseBool() throws -> Bool {
            skipWhitespace()
            if peek() == 0x74 { try literal("true"); return true }
            try literal("false")
            return false
        }

        mutating func literal(_ text: StaticString) throws {
            let length = text.utf8CodeUnitCount
            guard position + length <= count, memcmp(base + position, text.utf8Start, length) == 0 else {
                throw IngestError(offset: position, message: "expected \(text)")
            }
            position += length
        }

        mutating func skipValue() throws {
            skipWhitespace()
            switch peek() {
            case 0x22: _ = try scanString()
            case 0x7B, 0x5B:
                var depth = 0
                while position < count {
                    let byte = base[position]
                    if byte == 0x22 { _ = try scanString(); continue }
                    if byte == 0x7B || byte == 0x5B { depth += 1 }
                    if byte == 0x7D || byte == 0x5D { depth -= 1; if depth == 0 { position += 1; return } }
                    position += 1
                }
            case 0x74: try literal("true")
            case 0x66: try literal("false")
            case 0x6E: try literal("null")
            default: _ = try parseDouble()
            }
        }
    }

    /// Decodes a string from response bytes; the only place strings are allocated.
    static func materialize(base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ escaped: Bool) -> String {
        if !escaped {
            return String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(end - start)
        var index = start
        while index < end {
            let byte = base[index]
            if byte != 0x5C { bytes.append(byte); index += 1; continue }
            index += 1
            switch base[index] {
            case 0x22: bytes.append(0x22)
            case 0x5C: bytes.append(0x5C)
            case 0x2F: bytes.append(0x2F)
            case 0x62: bytes.append(0x08)
            case 0x66: bytes.append(0x0C)
            case 0x6E: bytes.append(0x0A)
            case 0x72: bytes.append(0x0D)
            case 0x74: bytes.append(0x09)
            case 0x75:
                // An escape cut short by the end of the string is a
                // replacement character, and the digits it has are dropped.
                guard index + 4 < end else {
                    bytes.append(contentsOf: [0xEF, 0xBF, 0xBD])
                    index = end
                    continue
                }
                // One without four hex digits is a replacement character, and
                // what follows the `u` is read as the string's own bytes, as
                // the scan that found the string's end read them.
                guard var scalar = hex4(base, index + 1) else {
                    bytes.append(contentsOf: [0xEF, 0xBF, 0xBD])
                    index += 1
                    continue
                }
                index += 4
                // A high surrogate pairs with a low one written as the next
                // escape. Anything else leaves it unpaired, a replacement
                // character, and the next escape is read on its own.
                if scalar >= 0xD800 && scalar < 0xDC00, index + 6 < end, base[index + 1] == 0x5C, base[index + 2] == 0x75,
                   let low = hex4(base, index + 3), low >= 0xDC00 && low <= 0xDFFF {
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    index += 6
                }
                bytes.append(contentsOf: Array(String(UnicodeScalar(scalar) ?? "\u{FFFD}").utf8))
            default: bytes.append(base[index])
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The value of the four hex digits at `start`, or nil when one is not.
    @inline(__always)
    static func hex4(_ base: UnsafePointer<UInt8>, _ start: Int) -> UInt32? {
        var value: UInt32 = 0
        for offset in 0..<4 {
            guard let digit = hexValue(base[start + offset]) else { return nil }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        case 0x41...0x46: byte - 0x41 + 10
        default: nil
        }
    }
}
