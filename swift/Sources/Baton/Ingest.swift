import Foundation

/// A normalized response, not yet in the store: records by key, one flat list
/// of (record, slot, value) entries in arrival order, reference lists in a
/// shared arena, and strings as byte ranges into the response. Nothing is
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

    public let bytes: [UInt8]
    public internal(set) var recordKeys: ContiguousArray<String> = []
    public internal(set) var recordTypes: ContiguousArray<TypeID> = []
    public internal(set) var entries: ContiguousArray<Entry> = []
    public internal(set) var refs: ContiguousArray<Int32> = []
    public internal(set) var scalars: ContiguousArray<RawValue> = []
    var index: [String: Int32] = [:]

    init(bytes: [UInt8]) {
        self.bytes = bytes
        index.reserveCapacity(1024)
        recordKeys.reserveCapacity(1024)
        recordTypes.reserveCapacity(1024)
        entries.reserveCapacity(32_768)
        refs.reserveCapacity(8_192)
    }

    @inline(__always)
    mutating func record(for key: String, type: TypeID) -> Int32 {
        if let id = index[key] { return id }
        let id = Int32(recordKeys.count)
        recordKeys.append(key)
        recordTypes.append(type)
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
    public static func normalize(_ data: Data, plan: ResolvedSelection, rootKey: String = Store.rootKey) throws -> ChangeSet {
        let bytes = [UInt8](data)
        var changes = ChangeSet(bytes: bytes)
        try bytes.withUnsafeBufferPointer { buffer in
            var cursor = Cursor(base: buffer.baseAddress!, count: buffer.count, changes: changes)
            try cursor.run(root: plan, rootKey: rootKey)
            changes = cursor.changes
        }
        return changes
    }

    struct Cursor {
        let base: UnsafePointer<UInt8>
        let count: Int
        var position = 0
        var changes: ChangeSet
        /// One scratch buffer per nesting depth: (field index, value). Slots are
        /// resolved when the object ends, because abstract selections resolve
        /// them against the concrete type the payload names.
        var scratch: [ContiguousArray<(Int, ChangeSet.RawValue)>] = (0..<24).map { _ in
            var array = ContiguousArray<(Int, ChangeSet.RawValue)>()
            array.reserveCapacity(32)
            return array
        }

        init(base: UnsafePointer<UInt8>, count: Int, changes: ChangeSet) {
            self.base = base
            self.count = count
            self.changes = changes
        }

        mutating func run(root: ResolvedSelection, rootKey: String) throws {
            skipWhitespace()
            try expect(0x7B)
            var sawData = false
            while true {
                skipWhitespace()
                if peek() == 0x7D { position += 1; break }
                let (start, end, escaped) = try scanString()
                skipWhitespace(); try expect(0x3A); skipWhitespace()
                if !escaped && end - start == 4 && memcmp(base + start, "data", 4) == 0 {
                    if peek() == 0x6E {
                        try literal("null")
                    } else {
                        let rootID = changes.record(for: rootKey, type: root.type)
                        _ = try object(plan: root, parent: rootID, slot: nil, listIndex: nil, depth: 0, fixedRecord: rootID)
                        sawData = true
                    }
                } else if !escaped && end - start == 6 && memcmp(base + start, "errors", 6) == 0 {
                    let errorsStart = position
                    try skipValue()
                    if !sawData {
                        throw IngestError(offset: errorsStart, message: "the response carries errors and no data")
                    }
                } else {
                    try skipValue()
                }
                skipWhitespace()
                if peek() == 0x2C { position += 1 }
            }
            if !sawData { throw IngestError(offset: position, message: "no data in response") }
        }

        /// Parses one object against a selection; appends its entries; returns its record.
        ///
        /// Entities are keyed `Type:id`. For a selection on an interface or union
        /// the type is the payload's `__typename` (the compiler puts it first), and
        /// the slots are resolved against that concrete type when the object ends.
        mutating func object(plan: ResolvedSelection, parent: Int32, slot: Slot?, listIndex: Int?, depth: Int, fixedRecord: Int32?) throws -> Int32 {
            try expect(0x7B)
            guard depth < scratch.count else { throw IngestError(offset: position, message: "selection nested deeper than 24 levels") }
            scratch[depth].removeAll(keepingCapacity: true)
            var record: Int32 = fixedRecord ?? -1
            var concreteType = plan.type
            var pendingID: (Int, Int, Bool)? = nil
            var expected = 0
            let fields = plan.fields
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
                    // Kept as the record's type, not as a field.
                    if peek() == 0x6E { try literal("null"); continue }
                    let (start, end, escaped) = try scanString()
                    if plan.isAbstract {
                        concreteType = Registry.type(Ingest.materialize(base: base, start, end, escaped))
                        if record < 0, let (idStart, idEnd, idEscaped) = pendingID {
                            record = changes.record(for: concreteType.name + ":" + Ingest.materialize(base: base, idStart, idEnd, idEscaped), type: concreteType)
                        }
                    }
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
                            changes.scalars.append(try scalarValue(scalar))
                            items += 1
                        }
                        scratch[depth].append((matched, .list(start: start, count: Int32(items))))
                        continue
                    }
                    let value = try scalarValue(scalar)
                    if plan.hasID && field.keyBytes.count == 2 && field.keyBytes[0] == 0x69 && field.keyBytes[1] == 0x64,
                       case .string(let start, let end, let escaped) = value, record < 0 {
                        if plan.isAbstract && concreteType == plan.type {
                            // The typename has not arrived; settle when it does, or at the end.
                            pendingID = (Int(start), Int(end), escaped)
                        } else {
                            record = changes.record(for: concreteType.name + ":" + Ingest.materialize(base: base, Int(start), Int(end), escaped), type: concreteType)
                        }
                    }
                    scratch[depth].append((matched, value))
                case .linked(let child, let plural, _):
                    if peek() == 0x6E {
                        try literal("null")
                        scratch[depth].append((matched, .null))
                        continue
                    }
                    if record < 0 {
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
                    } else {
                        let childRecord = try object(plan: child, parent: record, slot: field.slot, listIndex: nil, depth: depth + 1, fixedRecord: nil)
                        scratch[depth].append((matched, .ref(childRecord)))
                    }
                }
            }
            if record < 0 {
                record = settle(plan: plan, concreteType: concreteType, pendingID: pendingID, parent: parent, slot: slot, listIndex: listIndex)
            }
            if plan.isAbstract {
                let slots = plan.slots(for: concreteType)
                for (index, value) in scratch[depth] {
                    changes.entries.append(ChangeSet.Entry(record: record, slot: slots[index], value: value))
                }
            } else {
                for (index, value) in scratch[depth] {
                    changes.entries.append(ChangeSet.Entry(record: record, slot: fields[index].slot, value: value))
                }
            }
            return record
        }

        @inline(__always)
        func keyMatches(_ field: ResolvedField, _ keyStart: Int) -> Bool {
            field.keyBytes.withUnsafeBufferPointer { key in
                memcmp(base + keyStart, key.baseAddress!, key.count) == 0
            }
        }

        /// The record for an object whose key is not settled yet: an entity key
        /// when an id was seen, else a client id from the path.
        @inline(__always)
        mutating func settle(plan: ResolvedSelection, concreteType: TypeID, pendingID: (Int, Int, Bool)?, parent: Int32, slot: Slot?, listIndex: Int?) -> Int32 {
            if let (start, end, escaped) = pendingID {
                return changes.record(for: concreteType.name + ":" + Ingest.materialize(base: base, start, end, escaped), type: concreteType)
            }
            let parentKey = changes.recordKeys[Int(parent)]
            let storageKey = slot.map(Registry.storageKey) ?? ""
            if let listIndex { return changes.record(for: parentKey + ":" + storageKey + ":" + String(listIndex), type: concreteType) }
            return changes.record(for: parentKey + ":" + storageKey, type: concreteType)
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
                switch peek() {
                case 0x22:
                    let (start, end, escaped) = try scanString()
                    return .string(start: Int32(start), end: Int32(end), escaped: escaped)
                case 0x74, 0x66: return .bool(try parseBool())
                case 0x7B, 0x5B:
                    // Structured custom scalars are not stored in this release.
                    try skipValue()
                    return .null
                default:
                    let start = position
                    let double = try parseDouble()
                    let text = UnsafeBufferPointer(start: base + start, count: position - start)
                    return text.contains(0x2E) || text.contains(0x65) || text.contains(0x45) ? .double(double) : .int(Int(double))
                }
            }
        }

        // MARK: lexical layer

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

        mutating func parseInt() throws -> Int {
            var negative = false
            if peek() == 0x2D { negative = true; position += 1 }
            var value = 0
            var digits = 0
            while position < count, base[position] >= 0x30, base[position] <= 0x39 {
                value = value &* 10 &+ Int(base[position] - 0x30)
                position += 1
                digits += 1
            }
            if digits == 0 { throw IngestError(offset: position, message: "expected a number") }
            if position < count, base[position] == 0x2E || base[position] == 0x65 || base[position] == 0x45 {
                position -= digits + (negative ? 1 : 0)
                return Int(try parseDouble())
            }
            return negative ? -value : value
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
                var scalar: UInt32 = 0
                for offset in 1...4 { scalar = scalar << 4 | UInt32(hexValue(base[index + offset])) }
                index += 4
                if scalar >= 0xD800 && scalar < 0xDC00, index + 6 < end, base[index + 1] == 0x5C, base[index + 2] == 0x75 {
                    var low: UInt32 = 0
                    for offset in 3...6 { low = low << 4 | UInt32(hexValue(base[index + offset])) }
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

    @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        case 0x41...0x46: byte - 0x41 + 10
        default: 0
        }
    }
}
