import Foundation

/// A normalized response, not yet in the store: records by key, one flat list
/// of (record, slot, value) entries in arrival order, reference lists in a
/// shared arena, strings as byte ranges into the response, the edits the
/// plan's connections and edge directives ask for, and the field errors the
/// response carried, resolved to the records and slots they name. Nothing is
/// materialized until the commit decides which values won and which changed.
package struct ChangeSet: Sendable {
    package enum RawValue: Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(start: Int32, end: Int32, escaped: Bool)
        case ref(Int32)
        case refs(start: Int32, count: Int32)
        case list(start: Int32, count: Int32)
    }

    package struct Entry: Sendable {
        package let record: Int32
        package let slot: Slot
        package let value: RawValue
    }

    /// What the store does after writing the entries: a connection page's
    /// merge, or an edge directive of a mutation payload. Records are indices
    /// into this change set; connections are named by their record keys.
    package enum Edit: Sendable {
        case merge(connection: Int32, page: Int32, slots: ConnectionSlots, mode: ConnectionMode)
        /// A page of a paged list merged into the list's record, by the page
        /// number the container was fetched with.
        case mergePage(list: Int32, page: Int32, paged: ResolvedPaged, number: Int)
        /// A streamed item set at its index in the parent's list, which is
        /// extended with nulls to reach the index.
        case place(parent: Int32, slot: Slot, index: Int, item: Int32)
        case insertEdge(edge: Int32, connections: [String], prepend: Bool)
        case insertNode(node: Int32, edgeType: TypeID, connections: [String], prepend: Bool)
        case deleteEdge(id: String, connections: [String])
        case deleteRecord(id: String)
        /// A record a mutation named by its type and a variable (`@deletes`),
        /// by its exact key.
        case deleteByKey(key: String)
    }

    /// A field error resolved to the record and slot its path names, and
    /// whether a `@catch` on the way there handles it.
    package struct FieldErrorEntry: Sendable {
        package let record: Int32
        package let slot: Slot
        package let error: FieldError
        package let caught: Bool
    }

    package let bytes: [UInt8]
    package internal(set) var recordKeys: ContiguousArray<String> = []
    package internal(set) var recordTypes: ContiguousArray<TypeID> = []
    /// Whether the record is an entity keyed `Type:id`, for the store's id index.
    package internal(set) var recordIsEntity: ContiguousArray<Bool> = []
    /// Where each record's id starts in its key, or -1 for a record keyed
    /// by its path: the store makes the record from it and asks nothing of
    /// the registry.
    package internal(set) var recordIDOffsets: ContiguousArray<Int32> = []
    /// The pass of the walk at which entries last named each record: the
    /// cursor counts a pass per object closed and per span whose entries
    /// it appended again, and a span closed at a pass stands while no
    /// record its entries name was written at a later one. Zero until
    /// written.
    var recordWrittenAt: ContiguousArray<Int32> = []
    /// What the response said of types the plan did not list: that records
    /// of the type are members of the condition. The store learns them.
    package internal(set) var memberships: [(type: TypeID, condition: TypeID)] = []
    /// Entries grouped by record, one per slot: the last value the response
    /// gave. In arrival order until the ingest groups them at its end.
    package internal(set) var entries: ContiguousArray<Entry> = []
    /// The entries of record `i` are `entries[starts[i]..<starts[i + 1]]`.
    package internal(set) var starts: ContiguousArray<Int32> = []
    package internal(set) var refs: ContiguousArray<Int32> = []
    package internal(set) var scalars: ContiguousArray<RawValue> = []
    package internal(set) var edits: ContiguousArray<Edit> = []
    /// The streamed lists this change set writes, by record and slot: the
    /// lists a first part carries, and the one an item is placed in. The
    /// delivery notes each as its commit left it, so a later item knows the
    /// list it belongs to.
    package internal(set) var streams: ContiguousArray<(record: Int32, slot: Slot)> = []
    package internal(set) var fieldErrors: ContiguousArray<FieldErrorEntry> = []
    /// Errors the response carried without a path, or with one that names
    /// no field it selected: nothing in the store holds them.
    package internal(set) var unplacedErrors: [FieldError] = []
    /// How many objects the walk found printed again, byte for byte, under
    /// a selection it had read them under, and took as their records
    /// without a parse; and how many entries it appended before `group()`
    /// kept one per record and slot. For the counts.
    package internal(set) var skipped = 0
    package internal(set) var entriesBeforeGrouping = 0
    /// The records the change set describes, one per key in `recordKeys`'
    /// order, built by `build()` after the grouping with their values
    /// materialized and their links bound among them: what the commit
    /// adopts for the keys the store lacks. A box, so the commit can take
    /// them out of a change set its caller still holds, and the ones it did
    /// not adopt are freed off the main actor rather than with the change
    /// set on it. Empty until built, and again once taken.
    package let prebuilt = PrebuiltRecords()
    var index: [String: Int32] = [:]
    /// The records whose entity key came from one unescaped key field, by
    /// the type and the field's bytes, in front of `index`: an entity a
    /// response names many times, as every episode of a character names its
    /// characters, is found by its bytes, and its key string is made once,
    /// on first sight. Open addressing over four words a slot: the record,
    /// where the bytes start and end, and their hash; `index` stays the
    /// record of truth, so a spelling this table does not hold still finds
    /// its record there.
    var spans: ContiguousArray<Int32>
    var spanCount = 0

    /// Reserves by the response's size: the Rick and Morty fixture writes an
    /// entry per 33 bytes, a record per 760 and a list element per 250, and
    /// the estimates round each up.
    init(bytes: [UInt8]) {
        self.bytes = bytes
        let records = bytes.count / 512 + 4
        spans = ContiguousArray(repeating: -1, count: ChangeSet.spanCapacity(records) * 4)
        index.reserveCapacity(records)
        recordKeys.reserveCapacity(records)
        recordTypes.reserveCapacity(records)
        recordIsEntity.reserveCapacity(records)
        recordIDOffsets.reserveCapacity(records)
        recordWrittenAt.reserveCapacity(records)
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
        entriesBeforeGrouping = total
        var grouped = ContiguousArray<Int32>(repeating: 0, count: recordCount + 1)
        var sorted = ContiguousArray<Entry>()
        var kept = 0
        entries.withUnsafeBufferPointer { source in
            // The highest dense index, and the highest `~index` of a key
            // numbered apart, which the tables below place after the dense.
            var highest: Int32 = -1
            var highestRendered: Int32 = -1
            var counts = ContiguousArray<Int32>(repeating: 0, count: recordCount + 1)
            counts.withUnsafeMutableBufferPointer { counts in
                for entry in source {
                    counts[Int(entry.record) &+ 1] &+= 1
                    let index = entry.slot.index
                    if index > highest {
                        highest = index
                    } else if index < 0, ~index > highestRendered {
                        highestRendered = ~index
                    }
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
            // The record that last kept each slot, and where it kept it.
            let width = Int(highest) + 1 + Int(highestRendered) + 1
            var keeper = ContiguousArray<Int32>(repeating: -1, count: width)
            var place = ContiguousArray<Int32>(repeating: 0, count: width)
            sorted.withUnsafeMutableBufferPointer { sorted in
                keeper.withUnsafeMutableBufferPointer { keeper in
                    place.withUnsafeMutableBufferPointer { place in
                        for record in 0..<recordCount {
                            grouped[record] = Int32(kept)
                            for position in Int(counts[record])..<Int(counts[record &+ 1]) {
                                let entry = sorted[position]
                                let slot = entry.slot.index
                                let index = slot >= 0 ? Int(slot) : Int(highest) &+ 1 &+ Int(~slot)
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

    /// Builds the records, after `group()`: one `Record` per key, filled
    /// with the values its entries give, strings materialized, lists built,
    /// links as references to the records built here. Runs where the
    /// ingest runs, off the main actor; the records are nobody's until the
    /// commit adopts them, and the ones it does not adopt are freed where
    /// they were made.
    mutating func build() {
        let count = recordKeys.count
        var records = ContiguousArray<Record>()
        records.reserveCapacity(count)
        for index in 0..<count {
            records.append(Record(type: recordTypes[index], key: recordKeys[index], idOffset: recordIDOffsets[index]))
        }
        var hasNull = ContiguousArray<Bool>(repeating: false, count: count)
        // Which records a built record links, and which hold a link: the
        // commit relinks only those, against the linked ones the store had.
        var linked = ContiguousArray<Bool>(repeating: false, count: count)
        var links = ContiguousArray<Bool>(repeating: false, count: count)
        // The field errors are left to the commit, which sets them on an
        // adopted record as on any other: an error arriving counts as a
        // change of its slot, and the undo log holds it.
        var rendered: [(id: Int32, value: Value)] = []
        for index in 0..<count {
            let range = Int(starts[index])..<Int(starts[index + 1])
            var highest: Int32 = -1
            for position in range where entries[position].slot.index > highest { highest = entries[position].slot.index }
            var values = ContiguousArray<Value>(repeating: .missing, count: Int(highest) + 1)
            rendered.removeAll(keepingCapacity: true)
            for position in range {
                let entry = entries[position]
                let value: Value
                switch entry.value {
                case .null:
                    value = .null
                    hasNull[index] = true
                case .bool(let bool): value = .bool(bool)
                case .int(let int): value = .int(int)
                case .double(let double): value = .double(double)
                case .string(let start, let end, let escaped): value = .string(string(start, end, escaped: escaped))
                case .ref(let target):
                    value = .ref(records[Int(target)])
                    linked[Int(target)] = true
                    links[index] = true
                case .refs(let start, let listCount):
                    var list = ContiguousArray<Record?>()
                    list.reserveCapacity(Int(listCount))
                    for offset in 0..<Int(listCount) {
                        let target = refs[Int(start) + offset]
                        if target < 0 {
                            list.append(nil)
                        } else {
                            list.append(records[Int(target)])
                            linked[Int(target)] = true
                        }
                    }
                    links[index] = true
                    value = .refs(list)
                case .list(let start, let listCount):
                    var list = ContiguousArray<Value>()
                    list.reserveCapacity(Int(listCount))
                    for offset in 0..<Int(listCount) {
                        switch scalars[Int(start) + offset] {
                        case .null: list.append(.null)
                        case .bool(let bool): list.append(.bool(bool))
                        case .int(let int): list.append(.int(int))
                        case .double(let double): list.append(.double(double))
                        case .string(let start, let end, let escaped): list.append(.string(string(start, end, escaped: escaped)))
                        default: list.append(.null)
                        }
                    }
                    value = .list(list)
                }
                if entry.slot.index >= 0 {
                    values[Int(entry.slot.index)] = value
                } else {
                    rendered.append((~entry.slot.index, value))
                }
            }
            var renderedIDs = ContiguousArray<Int32>()
            var renderedValues = ContiguousArray<Value>()
            if !rendered.isEmpty {
                rendered.sort { $0.id < $1.id }
                renderedIDs.reserveCapacity(rendered.count)
                renderedValues.reserveCapacity(rendered.count)
                for (id, value) in rendered {
                    renderedIDs.append(id)
                    renderedValues.append(value)
                }
            }
            records[index].fill(values: values, rendered: (renderedIDs, renderedValues), errors: nil)
        }
        prebuilt.put(records, hasNull: hasNull, linked: linked, links: links)
    }

    /// The entry of a record's slot, once grouped.
    func entry(_ record: Int32, _ slot: Slot) -> Entry? {
        for position in Int(starts[Int(record)])..<Int(starts[Int(record) + 1])
        where entries[position].slot.index == slot.index {
            return entries[position]
        }
        return nil
    }

    /// The field errors no `@catch` handles, placed or not, each once; they
    /// fail a `@throwOnFieldError` operation. A failed part's change set
    /// repeats one error on every field the part would have filled, and
    /// counts them through `Ingest.FailedPart` instead.
    package var uncaughtFieldErrors: [FieldError] {
        fieldErrors.filter { !$0.caught }.map(\.error) + unplacedErrors
    }

    @inline(__always)
    mutating func record(for key: String, type: TypeID, idOffset: Int32) -> Int32 {
        if let id = index[key] { return id }
        let id = Int32(recordKeys.count)
        recordKeys.append(key)
        recordTypes.append(type)
        recordIsEntity.append(idOffset >= 0)
        recordIDOffsets.append(idOffset)
        recordWrittenAt.append(0)
        index[key] = id
        return id
    }

    /// The record of an entity of `type` keyed by the one unescaped key
    /// field at `bytes[start..<end]`, added on first sight under the key
    /// `typeName:text`, as `record(for:)` adds it.
    mutating func entityRecord(typeName: String, type: TypeID, start: Int, end: Int) -> Int32 {
        let hash = spanHash(type, start, end)
        let mask = spans.count / 4 - 1
        var slot = Int(UInt32(bitPattern: hash)) & mask
        while true {
            let base = slot * 4
            let record = spans[base]
            if record < 0 { break }
            if spans[base + 3] == hash, Int(spans[base + 2] - spans[base + 1]) == end - start,
               recordTypes[Int(record)] == type, sameBytes(Int(spans[base + 1]), start, end - start) {
                return record
            }
            slot = (slot + 1) & mask
        }
        let key = Record.entityKey(typeName, string(Int32(start), Int32(end), escaped: false))
        let record = self.record(for: key, type: type, idOffset: Record.idOffset(ofType: typeName))
        if (spanCount + 1) * 2 > spans.count / 4 { growSpans() }
        insertSpan(record, Int32(start), Int32(end), hash)
        return record
    }

    private func spanHash(_ type: TypeID, _ start: Int, _ end: Int) -> Int32 {
        bytes.withUnsafeBufferPointer { buffer in
            var hash = type.raw &* -0x61c88647
            for position in start..<end { hash = (hash ^ Int32(buffer[position])) &* 16777619 }
            return hash ^ Int32(bitPattern: UInt32(bitPattern: hash) >> 16)
        }
    }

    private func sameBytes(_ first: Int, _ second: Int, _ length: Int) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            for offset in 0..<length where buffer[first + offset] != buffer[second + offset] { return false }
            return true
        }
    }

    private mutating func insertSpan(_ record: Int32, _ start: Int32, _ end: Int32, _ hash: Int32) {
        let mask = spans.count / 4 - 1
        var slot = Int(UInt32(bitPattern: hash)) & mask
        while spans[slot * 4] >= 0 { slot = (slot + 1) & mask }
        let base = slot * 4
        spans[base] = record
        spans[base + 1] = start
        spans[base + 2] = end
        spans[base + 3] = hash
        spanCount += 1
    }

    private mutating func growSpans() {
        let old = spans
        spans = ContiguousArray(repeating: -1, count: old.count * 2)
        spanCount = 0
        for base in stride(from: 0, to: old.count, by: 4) where old[base] >= 0 {
            insertSpan(old[base], old[base + 1], old[base + 2], old[base + 3])
        }
    }

    /// Slots for the expected records at half load, a power of two.
    private static func spanCapacity(_ expected: Int) -> Int {
        var capacity = 16
        while capacity < expected * 2 { capacity *= 2 }
        return capacity
    }

    /// Decodes a string value from the response bytes.
    package func string(_ start: Int32, _ end: Int32, escaped: Bool) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            Ingest.materialize(base: buffer.baseAddress!, Int(start), Int(end), escaped)
        }
    }

    /// Whether the string at the range equals `other`, without allocating.
    package func stringEquals(_ start: Int32, _ end: Int32, escaped: Bool, _ other: String) -> Bool {
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

/// The records a change set built, held in a box the commit empties: one
/// `Record` per key, and whether each holds a null, which a verdict reads.
/// Shared by the copies of a change set and taken once; the ingest fills
/// it off the main actor before any copy is handed over.
package final class PrebuiltRecords: @unchecked Sendable {
    nonisolated(unsafe) private var records: ContiguousArray<Record> = []
    nonisolated(unsafe) private var hasNull: ContiguousArray<Bool> = []
    nonisolated(unsafe) private var linked: ContiguousArray<Bool> = []
    nonisolated(unsafe) private var links: ContiguousArray<Bool> = []

    package init() {}

    /// How many records the box holds; for the commit to see whether the
    /// change set was built, and for the tests.
    package var count: Int { records.count }

    /// Puts the built records in, with whether each is linked by a built
    /// record and whether each holds a link.
    func put(_ records: ContiguousArray<Record>, hasNull: ContiguousArray<Bool>, linked: ContiguousArray<Bool>, links: ContiguousArray<Bool>) {
        self.records = records
        self.hasNull = hasNull
        self.linked = linked
        self.links = links
    }

    /// Takes the records out, leaving the box empty.
    func take() -> (records: ContiguousArray<Record>, hasNull: ContiguousArray<Bool>, linked: ContiguousArray<Bool>, links: ContiguousArray<Bool>) {
        defer {
            records = []
            hasNull = []
            linked = []
            links = []
        }
        return (records, hasNull, linked, links)
    }
}
