import Foundation

// The image's row codec: the tags, the writing of a record's row and a root
// field's cell, and the reading back, over bytes. `Disk` keeps SQLite and
// knows nothing of the layout; the codec knows nothing of SQL. A row is a
// flag byte and the record's type name, then a cell per value held: the
// key's name, the value's tag and payload, and, after a tag with its high
// bit set, a field error as its message, its path and its `extensions` as
// JSON text, empty for none. Numbers are varints, strings a length and
// UTF-8, links a type name shifted past an entity bit and a key. The names
// of types and keys are the file's, which the disk numbers, so the codec
// asks for them.

/// The tags of a stored value.
enum RowTag {
    static let null: UInt8 = 0
    static let no: UInt8 = 1
    static let yes: UInt8 = 2
    static let int: UInt8 = 3
    static let double: UInt8 = 4
    static let string: UInt8 = 5
    static let ref: UInt8 = 6
    static let refs: UInt8 = 7
    static let list: UInt8 = 8
    static let hasError: UInt8 = 0x80
}

/// Writes a row or a cell into bytes the disk stores.
struct RowWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
    }

    /// A record's row: its flags, its type, and a cell per value held, those
    /// whose keys the disk never writes left out.
    mutating func row(_ snapshot: Record.Snapshot, typeName: (TypeID) -> Int32, slotName: (Slot) -> Int32) {
        let record = snapshot.record
        bytes.append((snapshot.deleted ? 1 : 0) | (record.isEntity ? 2 : 0))
        append(varint: UInt64(typeName(record.type)))
        for index in snapshot.values.indices {
            cell(Slot(type: record.type, index: Int32(index)), snapshot.values[index], snapshot.errors, typeName: typeName, slotName: slotName)
        }
        for position in snapshot.renderedIDs.indices {
            cell(Slot(type: record.type, index: ~snapshot.renderedIDs[position]), snapshot.renderedValues[position], snapshot.errors, typeName: typeName, slotName: slotName)
        }
    }

    /// Keeps, after the row's own cells, the cells of the record's earlier
    /// row that it does not write: for a record memory has not read from
    /// the image, whose snapshot holds what this launch's responses wrote
    /// and not what the image held of it. The row's own cells come first,
    /// so that a stale name in the old row cuts a read short only after
    /// everything new; a damaged old row is kept as far as it reads. The
    /// cells of a deleted row are not kept: a payload that names a deleted
    /// record again starts it over, as hydration reads none of them.
    mutating func merge(over old: UnsafeRawBufferPointer) {
        var oldCells = RowReader(old)
        guard let flags = oldCells.byte(), flags & 1 == 0, oldCells.index() != nil else { return }
        var written: [Int] = []
        bytes.withUnsafeBytes { row in
            var cells = RowReader(row)
            guard cells.byte() != nil, cells.index() != nil else { return }
            while let cell = cells.cell() { written.append(cell.name) }
        }
        while let cell = oldCells.cell() {
            if written.contains(cell.name) { continue }
            bytes.append(contentsOf: UnsafeRawBufferPointer(rebasing: old[cell.bytes]))
        }
    }

    /// A record's cell: the key's name and the value with its error.
    private mutating func cell(_ slot: Slot, _ value: Value, _ errors: [Int32: FieldError]?, typeName: (TypeID) -> Int32, slotName: (Slot) -> Int32) {
        if case .missing = value { return }
        // A link to a transient record is left out: nothing on disk names
        // one, and the next launch misses on the slot and fetches.
        if value.linksTransient { return }
        let name = slotName(slot)
        if name < 0 { return }
        append(varint: UInt64(name))
        append(value, error: errors?[slot.index], typeName: typeName)
    }

    /// A root field's cell: the value with its error.
    mutating func cell(_ field: Store.RootField, typeName: (TypeID) -> Int32) {
        append(field.value, error: field.error, typeName: typeName)
    }

    mutating func append(varint value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(_ string: String) {
        var string = string
        string.withUTF8 { utf8 in
            append(varint: UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }

    /// A link is the target's type, whether it is an entity, and its key; a
    /// null entry of a list is a zero.
    mutating func append(link target: Record?, typeName: (TypeID) -> Int32) {
        guard let target else {
            bytes.append(0)
            return
        }
        append(varint: UInt64(typeName(target.type) + 1) << 1 | (target.isEntity ? 1 : 0))
        append(target.key)
    }

    /// A value is a tag and its payload; the tag's high bit says a field
    /// error follows.
    mutating func append(_ value: Value, error: FieldError?, typeName: (TypeID) -> Int32) {
        let flag: UInt8 = error == nil ? 0 : RowTag.hasError
        switch value {
        case .missing, .null:
            bytes.append(RowTag.null | flag)
        case .bool(let bool):
            bytes.append((bool ? RowTag.yes : RowTag.no) | flag)
        case .int(let int):
            bytes.append(RowTag.int | flag)
            append(varint: UInt64(bitPattern: Int64((int << 1) ^ (int >> 63))))
        case .double(let double):
            bytes.append(RowTag.double | flag)
            withUnsafeBytes(of: double.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        case .string(let string):
            bytes.append(RowTag.string | flag)
            append(string)
        case .ref(let target):
            bytes.append(RowTag.ref | flag)
            append(link: target, typeName: typeName)
        case .refs(let targets):
            bytes.append(RowTag.refs | flag)
            append(varint: UInt64(targets.count))
            for target in targets { append(link: target, typeName: typeName) }
        case .list(let values):
            bytes.append(RowTag.list | flag)
            append(varint: UInt64(values.count))
            for value in values { append(value, error: nil, typeName: typeName) }
        }
        if let error {
            append(error.message)
            append(error.path)
            // The extensions as JSON text; empty for none, since a JSON value
            // is never empty.
            append(error.extensions?.json ?? "")
        }
    }
}

/// A cursor over a row's bytes. Every read is checked against the end: a row
/// is data from a file, and a damaged one must read as nothing, not crash.
struct RowReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// A varint that names a position in a table: at most `Int32.max`.
    mutating func index() -> Int? {
        guard let value = varint(), value <= UInt64(Int32.max) else { return nil }
        return Int(value)
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    mutating func fixed64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    mutating func string() -> String? {
        guard let length = varint(), length <= UInt64(remaining) else { return nil }
        defer { offset += Int(length) }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + Int(length)]), as: UTF8.self)
    }

    // MARK: Decoding

    /// A cell's value with its field error, or nil for a damaged row.
    mutating func value(_ disk: Disk, target: (String, TypeID, Bool) -> Record) -> (Value, FieldError?)? {
        guard let tag = byte() else { return nil }
        let value: Value
        switch tag & ~RowTag.hasError {
        case RowTag.null:
            value = .null
        case RowTag.no:
            value = .bool(false)
        case RowTag.yes:
            value = .bool(true)
        case RowTag.int:
            guard let raw = varint() else { return nil }
            value = .int(Int(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))))
        case RowTag.double:
            guard let bits = fixed64() else { return nil }
            value = .double(Double(bitPattern: bits))
        case RowTag.string:
            guard let string = string() else { return nil }
            value = .string(string)
        case RowTag.ref:
            guard let target = link(disk, target: target) else { return nil }
            value = target.map(Value.ref) ?? .null
        case RowTag.refs:
            // Every link takes a byte at least, which bounds what a damaged
            // count can ask for.
            guard let count = varint(), count <= UInt64(remaining) else { return nil }
            var targets = ContiguousArray<Record?>()
            targets.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let target = link(disk, target: target) else { return nil }
                targets.append(target)
            }
            value = .refs(targets)
        case RowTag.list:
            guard let count = varint(), count <= UInt64(remaining) else { return nil }
            var items = ContiguousArray<Value>()
            items.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let item = scalar() else { return nil }
                items.append(item)
            }
            value = .list(items)
        default:
            return nil
        }
        guard tag & RowTag.hasError != 0 else { return (value, nil) }
        guard let message = string(), let path = string(), let extensions = string() else { return nil }
        // Extensions the row holds that no longer read are a damaged row.
        var parsed: Variable?
        if !extensions.isEmpty {
            guard let value = try? Ingest.variable(Data(extensions.utf8)) else { return nil }
            parsed = value
        }
        return (value, FieldError(message: message, path: path, extensions: parsed))
    }

    /// An element of a stored list of scalars. Lists hold scalars only, so a
    /// tag of anything else is a damaged row, and nesting cannot recurse.
    mutating func scalar() -> Value? {
        guard let tag = byte() else { return nil }
        switch tag {
        case RowTag.null: return .null
        case RowTag.no: return .bool(false)
        case RowTag.yes: return .bool(true)
        case RowTag.int:
            guard let raw = varint() else { return nil }
            return .int(Int(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))))
        case RowTag.double:
            guard let bits = fixed64() else { return nil }
            return .double(Double(bitPattern: bits))
        case RowTag.string:
            return string().map(Value.string)
        default:
            return nil
        }
    }

    // MARK: Scanning

    /// Marks in `used` the names a record's row uses, its type's, its keys'
    /// and those of the types its links name, for the sweep of the names
    /// table. False for a damaged row, read as far as it went.
    mutating func names(ofRow used: inout [Bool]) -> Bool {
        guard byte() != nil, let type = index() else { return false }
        mark(type, &used)
        while !isAtEnd {
            guard let name = index() else { return false }
            mark(name, &used)
            guard skip(valueMarking: &used) else { return false }
        }
        return true
    }

    /// Marks the names a root field's cell uses: the types its links name.
    mutating func names(ofCell used: inout [Bool]) -> Bool {
        skip(valueMarking: &used)
    }

    /// The next cell of a record's row, past its header: the key's name and
    /// the range of the cell's bytes, name and value. Nil at the end, or at
    /// a damaged cell.
    mutating func cell() -> (name: Int, bytes: Range<Int>)? {
        let start = offset
        var unmarked: [Bool] = []
        guard let name = index(), skip(valueMarking: &unmarked) else { return nil }
        return (name, start..<offset)
    }

    private func mark(_ name: Int, _ used: inout [Bool]) {
        if name < used.count { used[name] = true }
    }

    /// Passes over a value and its error, marking the type names its links
    /// carry.
    private mutating func skip(valueMarking used: inout [Bool]) -> Bool {
        guard let tag = byte() else { return false }
        switch tag & ~RowTag.hasError {
        case RowTag.null, RowTag.no, RowTag.yes:
            break
        case RowTag.int:
            guard varint() != nil else { return false }
        case RowTag.double:
            guard fixed64() != nil else { return false }
        case RowTag.string:
            guard skipString() else { return false }
        case RowTag.ref:
            guard skip(linkMarking: &used) else { return false }
        case RowTag.refs:
            guard let count = varint(), count <= UInt64(remaining) else { return false }
            for _ in 0..<Int(count) { guard skip(linkMarking: &used) else { return false } }
        case RowTag.list:
            guard let count = varint(), count <= UInt64(remaining) else { return false }
            for _ in 0..<Int(count) { guard skipScalar() else { return false } }
        default:
            return false
        }
        if tag & RowTag.hasError != 0 {
            for _ in 0..<3 { guard skipString() else { return false } }
        }
        return true
    }

    private mutating func skip(linkMarking used: inout [Bool]) -> Bool {
        guard let head = varint() else { return false }
        if head == 0 { return true }
        guard head >= 2, head >> 1 <= UInt64(Int32.max) + 1 else { return false }
        mark(Int(head >> 1) - 1, &used)
        return skipString()
    }

    private mutating func skipScalar() -> Bool {
        guard let tag = byte() else { return false }
        switch tag {
        case RowTag.null, RowTag.no, RowTag.yes: return true
        case RowTag.int: return varint() != nil
        case RowTag.double: return fixed64() != nil
        case RowTag.string: return skipString()
        default: return false
        }
    }

    private mutating func skipString() -> Bool {
        guard let length = varint(), length <= UInt64(remaining) else { return false }
        offset += Int(length)
        return true
    }

    /// The record a stored link names; the inner nil is a null entry of a
    /// list, the outer one a row that could not be read.
    mutating func link(_ disk: Disk, target: (String, TypeID, Bool) -> Record) -> Record?? {
        guard let head = varint() else { return nil }
        if head == 0 { return .some(nil) }
        // A link's head is its type's name id plus one, shifted past the
        // entity bit: 1 names no type.
        guard head >= 2, head >> 1 <= UInt64(Int32.max) + 1 else { return nil }
        guard let type = disk.type(Int(head >> 1) - 1), let key = string() else { return nil }
        return .some(target(key, type, head & 1 != 0))
    }
}

extension Value {
    /// Whether the value links a record of a transient type, which the image
    /// never names.
    nonisolated var linksTransient: Bool {
        switch self {
        case .ref(let target): Registry.isTransient(target.type)
        case .refs(let targets): targets.contains { $0.map { Registry.isTransient($0.type) } ?? false }
        default: false
        }
    }
}
