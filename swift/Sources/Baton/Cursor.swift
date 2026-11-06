import Foundation

extension Ingest {
    /// The plan-driven reader: a scanner over the response, and the change set
    /// it fills by the plan.
    struct Cursor {
        var scanner: Scanner
        var changes: ChangeSet
        /// What the response says of the parts to follow: the 2024 format's
        /// announcements, and whether there are more.
        var pending: [IncrementalPart.Pending] = []
        var hasNext = false
        /// One scratch buffer per nesting depth: (field index, value). Slots are
        /// resolved when the object ends, because abstract selections resolve
        /// them against the concrete type the payload names. Made when the
        /// walk first reaches the depth, and reused after.
        var scratch: [ContiguousArray<(Int, ChangeSet.RawValue)>] = []
        /// Client fields written beside the object's own, per depth: the
        /// connection links, by storage key and declared slot.
        var extra: [ContiguousArray<(String, Slot, ChangeSet.RawValue)>] = []
        /// The records of a plural link being read, per depth, reused as the
        /// scratch buffers are.
        var linked: [ContiguousArray<Int32>] = []
        /// Which of the variant's fields the object being read has answered,
        /// per depth, for a complete response.
        var seen: [ContiguousArray<Bool>] = []
        /// The values of the key fields the object being read has given, per
        /// depth, by the field's place in the key, as spans of the response.
        var keyParts: [ContiguousArray<(Int, Int, Bool)?>] = []
        /// Whether every field the plan selects must be answered: a server's
        /// response to an operation, where an object that omits one is
        /// malformed. Not for an optimistic response or a payload committed
        /// by hand, which may carry part of the selection.
        var complete = false
        /// How deep a selection may nest.
        static let depthLimit = 24
        /// The response's `errors`, as read; resolved against the plan at the end.
        var rawErrors: [ResponseError] = []
        /// The entities' objects the walk finished under selections whose
        /// repeats may be skipped: where each began, how long it ran, the
        /// record it settled as and the entries its parse appended, by the
        /// selection and a hash of the object's first bytes. A later object
        /// under that selection whose bytes equal a span's is the entity
        /// printed again: it takes the record, the first printing's entries
        /// are appended again in its place, and the walk moves past it; the
        /// change set is the one a parse would make, so the last printing
        /// of a record still wins. Open addressing at half load; one span
        /// per key, the first, so a key many objects share costs a missed
        /// skip and never a wrong one.
        var spans: ContiguousArray<Span>
        var spanCount = 0

        struct Span {
            var hash: UInt64
            /// The selection the object was read under; nil in an empty slot.
            var selection: ObjectIdentifier?
            var start: Int32
            var length: Int32
            var record: Int32
            /// The entries the printing's parse appended, the subtree's too.
            var entriesStart: Int32
            var entriesEnd: Int32

            static let empty = Span(hash: 0, selection: nil, start: 0, length: 0, record: -1, entriesStart: 0, entriesEnd: 0)
        }

        init(base: UnsafePointer<UInt8>, count: Int, changes: ChangeSet) {
            scanner = Scanner(base: base, count: count)
            self.changes = changes
            spans = ContiguousArray(repeating: Span.empty, count: Cursor.spanCapacity(count / 512 + 4))
        }

        /// Slots for the expected entities at half load, a power of two.
        private static func spanCapacity(_ expected: Int) -> Int {
            var capacity = 16
            while capacity < expected * 2 { capacity *= 2 }
            return capacity
        }

        /// A hash of up to the first 64 bytes at `start`, eight at a time,
        /// which needs no end to compute: an object's opening, its first keys
        /// and, as Relay prints objects, its type and its first values.
        @inline(__always)
        func prefixHash(_ start: Int) -> UInt64 {
            let length = min(64, count - start)
            var hash: UInt64 = 0x9E37_79B9_7F4A_7C15
            var offset = 0
            while offset + 8 <= length {
                let word = UnsafeRawPointer(base + start + offset).loadUnaligned(as: UInt64.self)
                hash = (hash ^ word) &* 0xFF51_AFD7_ED55_8CCD
                hash ^= hash >> 32
                offset += 8
            }
            while offset < length {
                hash = (hash ^ UInt64(base[start + offset])) &* 0x0000_0100_0000_01B3
                offset += 1
            }
            return hash
        }

        /// The record of the object at `opening` when its bytes equal those
        /// of the object remembered under the selection and the hash, the
        /// first printing's entries appended again and the walk moved past
        /// the bytes; nil when none is remembered or the bytes differ, where
        /// the compare stopped at the first byte that did.
        @inline(__always)
        mutating func repeated(_ plan: ResolvedSelection, _ hash: UInt64, at opening: Int) -> Int32? {
            let identity = ObjectIdentifier(plan)
            let mask = spans.count - 1
            var slot = Int(truncatingIfNeeded: hash) & mask
            while true {
                let span = spans[slot]
                guard let selection = span.selection else { return nil }
                if span.hash == hash, selection == identity {
                    let length = Int(span.length)
                    guard opening + length <= count, memcmp(base + opening, base + Int(span.start), length) == 0 else { return nil }
                    // One entry at a time: a slice of the array appended to
                    // itself would copy the whole array first.
                    for index in Int(span.entriesStart)..<Int(span.entriesEnd) {
                        changes.entries.append(changes.entries[index])
                    }
                    position = opening + length
                    return span.record
                }
                slot = (slot + 1) & mask
            }
        }

        /// Remembers the entity's object just read, with the entries its
        /// parse appended from `entriesFrom` on, unless the key already has
        /// a span.
        mutating func remember(_ plan: ResolvedSelection, _ hash: UInt64, start: Int, end: Int, record: Int32, entriesFrom: Int) {
            if (spanCount + 1) * 2 > spans.count { growSpans() }
            let identity = ObjectIdentifier(plan)
            let mask = spans.count - 1
            var slot = Int(truncatingIfNeeded: hash) & mask
            while let selection = spans[slot].selection {
                if spans[slot].hash == hash, selection == identity { return }
                slot = (slot + 1) & mask
            }
            spans[slot] = Span(hash: hash, selection: identity, start: Int32(start), length: Int32(end - start), record: record, entriesStart: Int32(entriesFrom), entriesEnd: Int32(changes.entries.count))
            spanCount += 1
        }

        private mutating func growSpans() {
            let old = spans
            spans = ContiguousArray(repeating: Span.empty, count: old.count * 2)
            let mask = spans.count - 1
            for span in old where span.selection != nil {
                var slot = Int(truncatingIfNeeded: span.hash) & mask
                while spans[slot].selection != nil { slot = (slot + 1) & mask }
                spans[slot] = span
            }
        }

        var base: UnsafePointer<UInt8> { scanner.base }
        var count: Int { scanner.count }
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
                        rootID = cursor.changes.record(for: rootKey, type: root.type, idOffset: -1)
                        _ = try cursor.object(plan: root, parent: rootID, storageKey: nil, listIndex: nil, depth: 0, fixedRecord: rootID)
                        sawData = true
                    }
                case "errors":
                    try cursor.errors()
                case "pending":
                    cursor.pending = try cursor.scanner.pending()
                case "hasNext":
                    cursor.hasNext = try cursor.parseBool()
                default:
                    try cursor.skipValue()
                }
            }
            if !sawData {
                if !rawErrors.isEmpty {
                    throw GraphQLErrors(errors: rawErrors.map { FieldError(message: $0.message, path: Ingest.render($0.path ?? []), extensions: $0.extensions) })
                }
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
            rawErrors.append(contentsOf: try scanner.responseErrors())
        }

        /// Resolves each error's path through the plan and the entries to the
        /// record and slot it names. The walk stops at a field whose value is
        /// null, a link the response does not continue, or a list index it
        /// does not have, and the error lands on the last field it reached:
        /// with GraphQL's null propagation, that is the nullable ancestor.
        mutating func resolveErrors(root: ResolvedSelection, rootID: Int32, below prefix: [PathSegment] = []) {
            for raw in rawErrors {
                let path = raw.path
                let error = FieldError(message: raw.message, path: Ingest.render(path ?? []), extensions: raw.extensions)
                // A part's errors are by the response's paths: the walk
                // starts where the part's object is.
                guard let path, path.count > prefix.count, Array(path.prefix(prefix.count)) == prefix else {
                    changes.unplacedErrors.append(error)
                    continue
                }
                var record = rootID
                var selection = root
                var caught = false
                var resolved: (Int32, Slot)?
                var segments = path.dropFirst(prefix.count)
                walk: while let segment = segments.popFirst() {
                    let variant = selection.variant(for: changes.recordTypes[Int(record)], memberOf: [])
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
        mutating func object(plan: ResolvedSelection, parent: Int32, storageKey: String?, listIndex: Int?, depth: Int, fixedRecord: Int32?) throws -> Int32 {
            let opening = position
            try expect(0x7B)
            guard depth < Cursor.depthLimit else { throw IngestError(offset: position, message: "selection nested deeper than 24 levels") }
            // An entity printed again under this selection is the record its
            // first printing settled as, found by one compare. An object at a
            // fixed record, the root's or a deferred part's, neither looks
            // one up nor is remembered; nor does one under a selection with
            // no key fields, which settles as a record keyed by its path.
            let skippable = plan.skipsRepeats && fixedRecord == nil && !plan.key.isEmpty
            var prefix: UInt64 = 0
            if skippable {
                prefix = prefixHash(opening)
                if let record = repeated(plan, prefix, at: opening) {
                    changes.skipped += 1
                    return record
                }
            }
            let entriesBefore = changes.entries.count
            if depth == scratch.count {
                var buffer = ContiguousArray<(Int, ChangeSet.RawValue)>()
                buffer.reserveCapacity(16)
                scratch.append(buffer)
                extra.append([])
                linked.append([])
                seen.append([])
                keyParts.append([])
            } else {
                scratch[depth].removeAll(keepingCapacity: true)
                extra[depth].removeAll(keepingCapacity: true)
            }
            var record: Int32 = fixedRecord ?? -1
            var concreteType = fixedRecord.map { changes.recordTypes[Int($0)] } ?? plan.type
            var found = 0
            var answers: [TypeID] = []
            if plan.isAbstract, fixedRecord == nil {
                try identity(of: plan, keys: [], afterValue: false, wantsID: false, concreteType: &concreteType, depth: depth, found: &found, answers: &answers)
            }
            var expected = 0
            let variant = plan.variant(for: concreteType, memberOf: answers)
            for condition in answers { changes.memberships.append((concreteType, condition)) }
            let fields = variant.read
            let fieldCount = fields.count
            let keys = variant.keys
            keyParts[depth].removeAll(keepingCapacity: true)
            keyParts[depth].append(contentsOf: repeatElement(nil, count: keys.count))
            if complete {
                seen[depth].removeAll(keepingCapacity: true)
                seen[depth].append(contentsOf: repeatElement(false, count: fieldCount))
            }
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
                    if expected < fieldCount, fields[expected].keyBytes.count == keyLength, keyMatches(fields, expected, keyStart) {
                        matched = expected
                        expected += 1
                    } else {
                        for index in 0..<fieldCount where fields[index].keyBytes.count == keyLength && keyMatches(fields, index, keyStart) {
                            matched = index
                            expected = index + 1
                            break
                        }
                    }
                }
                guard matched >= 0 else { try skipValue(); continue }
                if complete { seen[depth][matched] = true }
                // The matched field is read in place: a copy would retain each of its lists.
                switch fields[matched].kind {
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
                            if let edit = fields[matched].edit { deletion(edit, value) }
                        }
                        scratch[depth].append((matched, .list(start: start, count: Int32(items))))
                        continue
                    }
                    let start = position
                    let value = try scalarValue(scalar)
                    if fields[matched].keyIndex >= 0, record < 0, keyParts[depth][Int(fields[matched].keyIndex)] == nil {
                        // A key's value is its text: a string's contents, or
                        // a number as the server wrote it.
                        if case .string(let start, let end, let escaped) = value {
                            keyParts[depth][Int(fields[matched].keyIndex)] = (Int(start), Int(end), escaped)
                        } else {
                            keyParts[depth][Int(fields[matched].keyIndex)] = (start, position, false)
                        }
                        found += 1
                        if found == keys.count {
                            record = entity(typeName: variant.typeName, type: concreteType, depth: depth)
                        }
                    }
                    scratch[depth].append((matched, value))
                    if let edit = fields[matched].edit { deletion(edit, value) }
                case .linked(let child, let plural, _, let connection):
                    if peek() == 0x6E {
                        try literal("null")
                        scratch[depth].append((matched, .null))
                        continue
                    }
                    if record < 0 {
                        // A child's key may be a path through this object, so the
                        // object's own key is settled before the child is read.
                        try identity(of: plan, keys: keys, afterValue: true, wantsID: true, concreteType: &concreteType, depth: depth, found: &found, answers: &answers)
                        record = settle(plan: plan, concreteType: concreteType, typeName: variant.typeName, keyCount: keys.count, found: found, depth: depth, parent: parent, storageKey: storageKey, listIndex: listIndex)
                    }
                    if plural {
                        try expect(0x5B)
                        linked[depth].removeAll(keepingCapacity: true)
                        var index = 0
                        while true {
                            skipWhitespace()
                            let next = peek()
                            if next == 0x5D { position += 1; break }
                            if next == 0x2C { position += 1; continue }
                            if next == 0x6E { try literal("null"); linked[depth].append(-1); index += 1; continue }
                            let target = try object(plan: child, parent: record, storageKey: fields[matched].storageKey, listIndex: index, depth: depth + 1, fixedRecord: nil)
                            linked[depth].append(target)
                            index += 1
                        }
                        let start = Int32(changes.refs.count)
                        changes.refs.append(contentsOf: linked[depth])
                        scratch[depth].append((matched, .refs(start: start, count: Int32(linked[depth].count))))
                        if fields[matched].streams { changes.streams.append((record, fields[matched].slot)) }
                        if let edit = fields[matched].edit {
                            for target in linked[depth] where target >= 0 { insertion(edit, target) }
                        }
                    } else {
                        let childRecord = try object(plan: child, parent: record, storageKey: fields[matched].storageKey, listIndex: nil, depth: depth + 1, fixedRecord: nil)
                        scratch[depth].append((matched, .ref(childRecord)))
                        if let connection {
                            // The page is the server's field; the connection record it
                            // merges into hangs off the parent by Relay's handle key.
                            let connectionRecord = changes.record(for: changes.recordKeys[Int(record)] + ":" + connection.storageKey, type: child.type, idOffset: -1)
                            extra[depth].append((connection.storageKey, connection.slot, .ref(connectionRecord)))
                            changes.edits.append(.merge(connection: connectionRecord, page: childRecord, slots: connection.slots, mode: connection.mode))
                        }
                        if let paged = fields[matched].paged {
                            // The container is the server's page; the record the
                            // paged list merges into hangs off the parent by the
                            // list's client key, and takes the page when the run
                            // named one.
                            let listRecord = changes.record(for: changes.recordKeys[Int(record)] + ":" + paged.storageKey, type: child.type, idOffset: -1)
                            extra[depth].append((paged.storageKey, paged.slot, .ref(listRecord)))
                            if let number = paged.page {
                                changes.edits.append(.mergePage(list: listRecord, page: childRecord, paged: paged, number: number))
                            }
                        }
                        if let edit = fields[matched].edit { insertion(edit, childRecord) }
                    }
                }
            }
            if complete {
                // A deferred field arrives in a later part.
                for index in variant.expected where !seen[depth][index] {
                    throw IngestError(offset: opening, message: "the response omits `\(fields[index].responseKey)` of `\(variant.typeName)`, which the operation selected")
                }
            }
            if record < 0 {
                record = settle(plan: plan, concreteType: concreteType, typeName: variant.typeName, keyCount: keys.count, found: found, depth: depth, parent: parent, storageKey: storageKey, listIndex: listIndex)
            }
            for (index, value) in scratch[depth] {
                changes.entries.append(ChangeSet.Entry(record: record, slot: fields[index].slot, value: value))
            }
            for (_, slot, value) in extra[depth] {
                changes.entries.append(ChangeSet.Entry(record: record, slot: slot, value: value))
            }
            // Only an entity is remembered: an object keyed by its path is
            // another record under another parent.
            if skippable, changes.recordIsEntity[Int(record)] {
                remember(plan, prefix, start: opening, end: position, record: record, entriesFrom: entriesBefore)
            }
            return record
        }

        /// Records the edit an edge directive asks for on a linked field's record.
        mutating func insertion(_ edit: ResolvedEdit, _ target: Int32) {
            switch edit.kind {
            case .appendEdge:
                changes.edits.append(.insertEdge(edge: target, connections: edit.connections, prepend: false))
            case .prependEdge:
                changes.edits.append(.insertEdge(edge: target, connections: edit.connections, prepend: true))
            case .appendNode:
                if let edgeType = edit.edgeType {
                    changes.edits.append(.insertNode(node: target, edgeType: edgeType, connections: edit.connections, prepend: false))
                }
            case .prependNode:
                if let edgeType = edit.edgeType {
                    changes.edits.append(.insertNode(node: target, edgeType: edgeType, connections: edit.connections, prepend: true))
                }
            case .deleteEdge, .deleteRecord:
                return
            }
        }

        /// Records the edit a delete directive asks for on an id value.
        mutating func deletion(_ edit: ResolvedEdit, _ value: ChangeSet.RawValue) {
            guard case .string(let start, let end, let escaped) = value else { return }
            let id = Ingest.materialize(base: base, Int(start), Int(end), escaped)
            switch edit.kind {
            case .deleteRecord:
                changes.edits.append(.deleteRecord(id: id))
            case .deleteEdge:
                changes.edits.append(.deleteEdge(id: id, connections: edit.connections))
            default:
                return
            }
        }

        @inline(__always)
        /// Whether the field's key is at `keyStart`; the field is read in
        /// place, since a copy of it would retain each of its lists.
        func keyMatches(_ fields: [ResolvedField], _ index: Int, _ keyStart: Int) -> Bool {
            fields[index].keyBytes.withUnsafeBufferPointer { key in
                memcmp(base + keyStart, key.baseAddress!, key.count) == 0
            }
        }

        /// Finds what an object's identity still lacks among its members, and
        /// leaves the cursor where it was: the `__typename` of an abstract
        /// selection, from the object's first member, before any key is
        /// matched; the key fields not yet given, from the member after the
        /// one at the cursor, which is a link's value. Without them an entity
        /// whose key follows a link would be keyed by its path, apart from
        /// the record every other operation writes.
        mutating func identity(of plan: ResolvedSelection, keys: [[UInt8]], afterValue: Bool, wantsID: Bool, concreteType: inout TypeID, depth: Int, found: inout Int, answers: inout [TypeID]) throws {
            var needsID = wantsID && !keys.isEmpty && found < keys.count
            var needsType = plan.isAbstract && concreteType == plan.type
            // Relay's membership answers are read while the type is: a type
            // the plan did not list takes its variant from them.
            var needsAnswers = needsType && !plan.membershipKeys.isEmpty
            guard needsID || needsType else { return }
            let resume = position
            defer { position = resume }
            let typename: StaticString = "__typename"
            if afterValue { try skipValue() }
            while needsID || needsType || needsAnswers {
                skipWhitespace()
                let byte = peek()
                if byte == 0x7D { return }
                if byte == 0x2C { position += 1; continue }
                let (keyStart, keyEnd, keyEscaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()
                let keyLength = keyEnd - keyStart
                var keyIndex = -1
                if needsID, !keyEscaped {
                    for (index, key) in keys.enumerated() where key.count == keyLength && keyParts[depth][index] == nil
                        && key.withUnsafeBufferPointer({ memcmp(base + keyStart, $0.baseAddress!, keyLength) == 0 }) {
                        keyIndex = index
                        break
                    }
                }
                if needsAnswers, !keyEscaped, keyLength > 4, base[keyStart] == 0x5F, base[keyStart + 1] == 0x5F {
                    for answer in plan.membershipKeys where answer.bytes.count == keyLength
                        && answer.bytes.withUnsafeBufferPointer({ memcmp(base + keyStart, $0.baseAddress!, keyLength) == 0 }) {
                        answers.append(answer.condition)
                    }
                    // The answers are found once the type is: a type the plan
                    // lists needs none, and the scan stops with the type.
                }
                // A key of a custom scalar may be a number: its text keys the
                // record, as it does when the key comes before the link.
                if keyIndex >= 0, peek() == 0x2D || (peek() >= 0x30 && peek() <= 0x39) {
                    let start = position
                    try skipValue()
                    keyParts[depth][keyIndex] = (start, position, false)
                    found += 1
                    needsID = found < keys.count
                    continue
                }
                guard !keyEscaped, peek() == 0x22 else { try skipValue(); continue }
                let (start, end, escaped) = try scanString()
                if keyIndex >= 0 {
                    keyParts[depth][keyIndex] = (start, end, escaped)
                    found += 1
                    needsID = found < keys.count
                } else if needsType, keyLength == typename.utf8CodeUnitCount, memcmp(base + keyStart, typename.utf8Start, keyLength) == 0 {
                    concreteType = plan.listedType(base: base, start, end, escaped) ?? Registry.type(Ingest.materialize(base: base, start, end, escaped))
                    needsType = false
                    // A type the plan lists has its variant; only an unlisted
                    // one takes it from the answers, which the whole object
                    // is read for.
                    if plan.lists(concreteType) { needsAnswers = false }
                }
            }
        }

        /// The record of an entity whose key fields were all given: keyed by
        /// their values in the key's order.
        @inline(__always)
        mutating func entity(typeName: String, type: TypeID, depth: Int) -> Int32 {
            let parts = keyParts[depth]
            let key: String
            if parts.count == 1, let (start, end, escaped) = parts[0] {
                if !escaped { return changes.entityRecord(typeName: typeName, type: type, start: start, end: end) }
                key = Record.entityKey(typeName, Ingest.materialize(base: base, start, end, escaped))
            } else {
                key = Record.entityKey(typeName, parts: parts.map { part in
                    let (start, end, escaped) = part!
                    return Ingest.materialize(base: base, start, end, escaped)
                })
            }
            return changes.record(for: key, type: type, idOffset: Record.idOffset(ofType: typeName))
        }

        /// The record for an object whose key is not settled yet: an entity key
        /// when every key field was seen, else a client id from the path.
        /// Under an interface or union the path key ends in the concrete
        /// type, so a payload of another type at the same path is another
        /// record.
        @inline(__always)
        mutating func settle(plan: ResolvedSelection, concreteType: TypeID, typeName: String, keyCount: Int, found: Int, depth: Int, parent: Int32, storageKey: String?, listIndex: Int?) -> Int32 {
            if keyCount > 0, found == keyCount {
                return entity(typeName: typeName, type: concreteType, depth: depth)
            }
            var key = changes.recordKeys[Int(parent)] + ":" + (storageKey ?? "")
            if let listIndex { key += ":" + String(listIndex) }
            if plan.isAbstract { key += ":" + typeName }
            return changes.record(for: key, type: concreteType, idOffset: -1)
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
}
