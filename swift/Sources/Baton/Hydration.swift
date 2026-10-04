import Foundation

/// Hydration: filling records from the image. It runs inside the availability
/// check, on the main actor, holding the image's connection; `Disk` writes
/// the rows this reads.
extension Store {
    /// Reads the record's row and fills the slots the record lacks. Returns
    /// whether the image had the row.
    func hydrate(_ record: Record, from disk: Disk) -> Bool {
        // A row the image is told to forget reads as missing until a
        // response writes the record again.
        if forgotten(record) { return false }
        record.setHydrated()
        // A record that held nothing has had no reader to notify. One that
        // held something is notified once the row is closed: an observer may
        // ask the store a question of its own.
        let observed = !record.isEmpty
        var filled: [Slot] = []
        let found = disk.record(record.key) { bytes in
            var reader = RowReader(bytes)
            guard let flags = reader.byte(), reader.varint() != nil else { return }
            if flags & 1 != 0 {
                if !observed { record.setDeleted(true) }
                return
            }
            while !reader.isAtEnd {
                // A row that stops making sense is used as far as it went:
                // what follows reads as missing, and the operation refetches.
                guard let name = reader.index(), let slot = disk.slot(name, on: record.type),
                      let (value, error) = value(&reader, disk)
                else { return }
                if record.fill(slot, value, error: error), observed { filled.append(slot) }
            }
        }
        for slot in filled { record.notify(slot) }
        if found { hydratedRecords += 1 }
        return found
    }

    /// Reads one field of the query root, which the image stores a row per
    /// field. Returns whether the field was filled.
    func hydrateRoot(_ slot: Slot, from disk: Disk) -> Bool {
        var filled = false
        _ = disk.rootField(slot.storageKey) { bytes in
            var reader = RowReader(bytes)
            guard let (value, error) = value(&reader, disk) else { return }
            filled = root.fill(slot, value, error: error)
        }
        guard filled else { return false }
        // Marked before an observer can ask the store about it.
        hydratedRootSlots.insert(slot.index)
        root.notify(slot)
        return true
    }

    private func value(_ reader: inout RowReader, _ disk: Disk) -> (Value, FieldError?)? {
        guard let tag = reader.byte() else { return nil }
        let value: Value
        switch tag & ~RowTag.hasError {
        case RowTag.null:
            value = .null
        case RowTag.no:
            value = .bool(false)
        case RowTag.yes:
            value = .bool(true)
        case RowTag.int:
            guard let raw = reader.varint() else { return nil }
            value = .int(Int(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))))
        case RowTag.double:
            guard let bits = reader.fixed64() else { return nil }
            value = .double(Double(bitPattern: bits))
        case RowTag.string:
            guard let string = reader.string() else { return nil }
            value = .string(string)
        case RowTag.ref:
            guard let target = link(&reader, disk) else { return nil }
            value = target.map(Value.ref) ?? .null
        case RowTag.refs:
            // Every link takes a byte at least, which bounds what a damaged
            // count can ask for.
            guard let count = reader.varint(), count <= UInt64(reader.remaining) else { return nil }
            var targets = ContiguousArray<Record?>()
            targets.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let target = link(&reader, disk) else { return nil }
                targets.append(target)
            }
            value = .refs(targets)
        case RowTag.list:
            guard let count = reader.varint(), count <= UInt64(reader.remaining) else { return nil }
            var items = ContiguousArray<Value>()
            items.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let item = scalar(&reader) else { return nil }
                items.append(item)
            }
            value = .list(items)
        default:
            return nil
        }
        guard tag & RowTag.hasError != 0 else { return (value, nil) }
        guard let message = reader.string(), let path = reader.string() else { return nil }
        return (value, FieldError(message: message, path: path))
    }

    /// An element of a stored list of scalars. Lists hold scalars only, so a
    /// tag of anything else is a damaged row, and nesting cannot recurse.
    private func scalar(_ reader: inout RowReader) -> Value? {
        guard let tag = reader.byte() else { return nil }
        switch tag {
        case RowTag.null: return .null
        case RowTag.no: return .bool(false)
        case RowTag.yes: return .bool(true)
        case RowTag.int:
            guard let raw = reader.varint() else { return nil }
            return .int(Int(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))))
        case RowTag.double:
            guard let bits = reader.fixed64() else { return nil }
            return .double(Double(bitPattern: bits))
        case RowTag.string:
            return reader.string().map(Value.string)
        default:
            return nil
        }
    }

    /// The record a stored link names; the inner nil is a null entry of a
    /// list, the outer one a row that could not be read.
    private func link(_ reader: inout RowReader, _ disk: Disk) -> Record?? {
        guard let head = reader.varint() else { return nil }
        if head == 0 { return .some(nil) }
        // A link's head is its type's name id plus one, shifted past the
        // entity bit: 1 names no type.
        guard head >= 2, head >> 1 <= UInt64(Int32.max) + 1 else { return nil }
        guard let type = disk.type(Int(head >> 1) - 1), let key = reader.string() else { return nil }
        return .some(target(key: key, type: type, entity: head & 1 != 0))
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
}
