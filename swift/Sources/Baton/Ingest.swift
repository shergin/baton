import Foundation

public struct IngestError: Error, CustomStringConvertible, Sendable, LocalizedError {
    public let offset: Int
    public let message: String
    public var description: String { "ingest error at byte \(offset): \(message)" }
    public var errorDescription: String? { description }
}

/// Decodes a GraphQL response straight into a change set, following a resolved
/// plan. One pass, no intermediate tree, no model.
package enum Ingest {
    /// One step of a response path: a field by response key, or a list index.
    package enum PathSegment: Sendable, Hashable {
        case name(String)
        case index(Int)
    }

    /// A deferred part's content: the items it delivers, the parts it
    /// announces, and whether more follow. Reads the June 2023 incremental
    /// format (`incremental[{data, path, label}]`), the 2024 one
    /// (`pending[{id, path, label}]`, `incremental[{id, data}]`), and Relay's
    /// (`{data, path, label}` per part).
    package struct IncrementalPart: Sendable {
        package struct Item: Sendable {
            package var path: [PathSegment]?
            package var label: String?
            package var id: String?
            /// Below the announced part's path, where the data is, in the
            /// 2024 format.
            package var subPath: [PathSegment]?
            package var data: Data
            /// The items of a streamed list the part delivers, in the June
            /// 2023 and 2024 formats; Relay's carries one item as `data`,
            /// its path ending in the item's index.
            package var items: [Data]?
            /// The field errors that came with the item, by absolute path.
            package var errors: [ResponseError] = []
        }

        package struct Pending: Sendable {
            package var id: String
            package var path: [PathSegment]
            package var label: String?
        }

        /// An announced part the server has finished, with the errors that
        /// kept it from being delivered, if any.
        package struct Completed: Sendable {
            package var id: String
            package var errors: [ResponseError]
        }

        package var items: [Item] = []
        package var pending: [Pending] = []
        package var completed: [Completed] = []
        package var hasNext = false
    }

    /// An entry of a response's `errors`, as read: its message and path.
    package struct ResponseError: Sendable {
        package var message: String
        package var path: [PathSegment]?
        /// The error's `extensions`, a JSON value, when the server sent any.
        package var extensions: Variable? = nil
    }

    /// One object a later part delivers: a deferred part's object, at the
    /// record its path names, or an item of a streamed list, under the
    /// parent record that holds the list.
    struct ObjectPart: Sendable {
        /// Where the object goes: into the record itself, as a deferred
        /// part's object does, or into the parent's list at an index.
        enum Placement: Sendable {
            case fills
            case item(storageKey: String, slot: Slot, index: Int)
        }

        /// A connection, or a paged list, whose page the object lands on:
        /// the page merges into it again once the object is in.
        enum Remerge: Sendable {
            case connection(key: String, slots: ConnectionSlots, mode: ConnectionMode)
            case paged(key: String, paged: ResolvedPaged, number: Int)
        }

        let data: Data
        let plan: ResolvedSelection
        /// The record the object fills, or the parent of the list it is an
        /// item of.
        let key: String
        let type: TypeID
        let entity: Bool
        /// Where the object is in the response, which the errors' paths
        /// start with.
        let path: [PathSegment]
        let errors: [ResponseError]
        var placement: Placement = .fills
        var remerge: Remerge? = nil
    }

    /// A whole response, or the first part of an incremental one, as it
    /// normalizes: its change set, the parts it announces (the 2024 format's
    /// `pending`) and whether more parts follow it. A whole response announces
    /// nothing and is followed by nothing.
    package struct FirstPart: Sendable {
        package var changes: ChangeSet
        package var pending: [IncrementalPart.Pending]
        package var hasNext: Bool
    }

    /// The change set a response normalizes to: what the store writes. A
    /// `complete` response answers every field the plan selects, as a server
    /// answers an operation: an object that omits one is malformed, and the
    /// response fails. A payload may be partial where that is the point, an
    /// optimistic response or one committed by hand, and then only what it
    /// carries is written.
    package static func normalize(_ data: Data, plan: ResolvedSelection, rootKey: String, complete: Bool = false) throws -> ChangeSet {
        try normalizeFirstPart(data, plan: plan, rootKey: rootKey, complete: complete).changes
    }

    /// Normalizes a response off the caller's actor and inside the caller's
    /// task, so the caller's cancellation and priority reach it.
    @concurrent
    nonisolated static func normalized(_ data: Data, plan: ResolvedSelection, rootKey: String, complete: Bool = false) async throws -> ChangeSet {
        try normalize(data, plan: plan, rootKey: rootKey, complete: complete)
    }

    /// The one payload of `payloads`, a transport's answer to `request`,
    /// awaited and normalized off the caller's actor and inside the caller's
    /// task: the actor is not entered when the bytes arrive, only for the
    /// commit that follows.
    @concurrent
    nonisolated static func normalized(_ payloads: AsyncThrowingStream<Data, any Error>, for request: Request, plan: ResolvedSelection, rootKey: String) async throws -> ChangeSet {
        try normalize(try await payloads.payload(for: request), plan: plan, rootKey: rootKey, complete: true)
    }

    /// A response, or the first part of an incremental one, with what it
    /// says of the parts to follow.
    package static func normalizeFirstPart(_ data: Data, plan: ResolvedSelection, rootKey: String, complete: Bool = false) throws -> FirstPart {
        let bytes = [UInt8](data)
        // The change set is made inside the cursor and moved out, so no copy
        // is held while the cursor appends and nothing is copied on write.
        return try bytes.withUnsafeBufferPointer { buffer in
            var cursor = Cursor(base: buffer.baseAddress!, count: buffer.count, changes: ChangeSet(bytes: bytes))
            cursor.complete = complete
            try cursor.run(root: plan, rootKey: rootKey)
            return FirstPart(changes: cursor.changes, pending: cursor.pending, hasNext: cursor.hasNext)
        }
    }

    @concurrent
    nonisolated static func normalizedFirstPart(_ data: Data, plan: ResolvedSelection, rootKey: String, complete: Bool = false) async throws -> FirstPart {
        try normalizeFirstPart(data, plan: plan, rootKey: rootKey, complete: complete)
    }

    /// Normalizes one object, as a deferred part delivers it: the selection
    /// the part fills, at the record its path named, read as that record's
    /// concrete type.
    package static func normalizeObject(_ data: Data, plan: ResolvedSelection, key: String, type: TypeID, entity: Bool) throws -> ChangeSet {
        try normalize(ObjectPart(data: data, plan: plan, key: key, type: type, entity: entity, path: [], errors: []))
    }

    /// One object of a later part as a change set. A deferred part's object
    /// is read into the record the part names; a streamed item is read as
    /// the list field's object, keyed by its id or by the parent, the field
    /// and its index, as it would be had it come with the first part, and
    /// placed at that index. An object that lands on a connection's page
    /// merges the page into its connection again. An error under the
    /// object's path lands on the field it names; any other is unplaced.
    static func normalize(_ part: ObjectPart) throws -> ChangeSet {
        let bytes = [UInt8](part.data)
        return try bytes.withUnsafeBufferPointer { buffer in
            var cursor = Cursor(base: buffer.baseAddress!, count: buffer.count, changes: ChangeSet(bytes: bytes))
            cursor.skipWhitespace()
            let anchor = cursor.changes.record(for: part.key, type: part.type, idOffset: part.entity ? Record.idOffset(ofType: part.type.name) : -1)
            let object: Int32
            switch part.placement {
            case .fills:
                object = try cursor.object(plan: part.plan, parent: anchor, storageKey: nil, listIndex: nil, depth: 0, fixedRecord: anchor)
            case .item(let storageKey, let slot, let index):
                object = try cursor.object(plan: part.plan, parent: anchor, storageKey: storageKey, listIndex: index, depth: 0, fixedRecord: nil)
                cursor.changes.edits.append(.place(parent: anchor, slot: slot, index: index, item: object))
                cursor.changes.streams.append((anchor, slot))
            }
            switch part.remerge {
            case .connection(let key, let slots, let mode)?:
                let connection = cursor.changes.record(for: key, type: slots.connection, idOffset: -1)
                cursor.changes.edits.append(.merge(connection: connection, page: anchor, slots: slots, mode: mode))
            case .paged(let key, let paged, let number)?:
                let list = cursor.changes.record(for: key, type: paged.slots.container, idOffset: -1)
                cursor.changes.edits.append(.mergePage(list: list, page: anchor, paged: paged, number: number))
            case nil:
                break
            }
            cursor.changes.group()
            if !part.errors.isEmpty {
                cursor.rawErrors = part.errors
                cursor.resolveErrors(root: part.plan, rootID: object, below: part.path)
            }
            return cursor.changes
        }
    }

    /// The objects a later part delivers, normalized off the caller's actor
    /// in one call.
    @concurrent
    nonisolated static func normalized(_ objects: [ObjectPart]) async throws -> [ChangeSet] {
        try objects.map { object in try normalize(object) }
    }

    /// An announced part the server could not deliver: the change set of its
    /// errors on the fields the part would have filled, and the errors a
    /// `@throwOnFieldError` operation counts, each once.
    struct FailedPart: Sendable {
        var changes: ChangeSet
        var uncaught: [FieldError]
    }

    /// The field errors of an announced part the server could not deliver,
    /// on the fields the part would have filled, so a `@catch` there reads
    /// them. A field holds one error, the first. The errors are caught when
    /// every one of those fields is under `@catch`, whatever their number;
    /// otherwise each counts once, however many fields are under none. They
    /// are not unplaced, which would fail a handle whose operation spreads
    /// the part's fragment: an error inside a spread is the fragment's to
    /// weigh.
    nonisolated static func failed(_ plan: ResolvedSelection, key: String, type: TypeID, entity: Bool, at path: [PathSegment], errors: [ResponseError]) -> FailedPart {
        var changes = ChangeSet(bytes: [])
        let record = changes.record(for: key, type: type, idOffset: entity ? Record.idOffset(ofType: type.name) : -1)
        changes.group()
        let rendered = errors.map { FieldError(message: $0.message, path: Ingest.render($0.path ?? path), extensions: $0.extensions) }
        guard let first = rendered.first else { return FailedPart(changes: changes, uncaught: []) }
        let fields = plan.variant(for: type, memberOf: []).read
        // A record of a type the part selects nothing on holds none of them.
        guard !fields.isEmpty else {
            changes.unplacedErrors = rendered
            return FailedPart(changes: changes, uncaught: rendered)
        }
        for field in fields {
            changes.fieldErrors.append(ChangeSet.FieldErrorEntry(record: record, slot: field.slot, error: first, caught: field.caught))
        }
        return FailedPart(changes: changes, uncaught: fields.allSatisfy(\.caught) ? [] : rendered)
    }

    /// The field errors of a streamed list the server could not finish, on
    /// the list field itself, beside the items that arrived.
    nonisolated static func failedStream(_ field: ResolvedField, key: String, type: TypeID, entity: Bool, at path: [PathSegment], errors: [ResponseError]) -> FailedPart {
        var changes = ChangeSet(bytes: [])
        let record = changes.record(for: key, type: type, idOffset: entity ? Record.idOffset(ofType: type.name) : -1)
        changes.group()
        let rendered = errors.map { FieldError(message: $0.message, path: Ingest.render($0.path ?? path), extensions: $0.extensions) }
        guard let first = rendered.first else { return FailedPart(changes: changes, uncaught: []) }
        changes.fieldErrors.append(ChangeSet.FieldErrorEntry(record: record, slot: field.slot, error: first, caught: field.caught))
        return FailedPart(changes: changes, uncaught: field.caught ? [] : rendered)
    }

    /// A response path, dotted, as a field error shows it.
    static func render(_ path: [PathSegment]) -> String {
        path.map { segment in
            switch segment {
            case .name(let name): name
            case .index(let offset): String(offset)
            }
        }.joined(separator: ".")
    }

    /// Reads a later part off the caller's actor.
    @concurrent
    nonisolated static func incrementalPart(_ data: Data) async throws -> IncrementalPart {
        try incremental(data)
    }

    /// Reads a part of an incremental response after the first.
    package static func incremental(_ data: Data) throws -> IncrementalPart {
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
                            case "items":
                                var items: [Data] = []
                                try scanner.elements { scanner in items.append(try scanner.rawValue(in: bytes)) }
                                item.items = items
                            case "path": item.path = try scanner.path()
                            case "subPath": item.subPath = try scanner.path()
                            case "label": item.label = try scanner.stringValue()
                            case "id": item.id = try scanner.stringValue()
                            case "errors": item.errors = try scanner.responseErrors()
                            default: try scanner.skipValue()
                            }
                        }
                        part.items.append(item)
                    }
                case "pending": part.pending = try scanner.pending()
                case "completed":
                    try scanner.elements { scanner in
                        var completed = IncrementalPart.Completed(id: "", errors: [])
                        try scanner.members { key, scanner in
                            switch key {
                            case "id": completed.id = try scanner.stringValue() ?? ""
                            case "errors": completed.errors = try scanner.responseErrors()
                            default: try scanner.skipValue()
                            }
                        }
                        part.completed.append(completed)
                    }
                case "hasNext": part.hasNext = try scanner.parseBool()
                case "data":
                    sawTopLevelData = true
                    topLevel.data = try scanner.rawValue(in: bytes)
                case "path": topLevel.path = try scanner.path()
                case "label": topLevel.label = try scanner.stringValue()
                case "errors": topLevel.errors = try scanner.responseErrors()
                default: try scanner.skipValue()
                }
            }
            if sawTopLevelData, topLevel.path != nil {
                part.items.append(topLevel)
            }
        }
        return part
    }

    /// A JSON value as a variable: an error's `extensions` read back from
    /// the image.
    package static func variable(_ data: Data) throws -> Variable {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { buffer in
            var scanner = Scanner(base: buffer.baseAddress!, count: buffer.count)
            return try scanner.value()
        }
    }

    /// Reads an array of GraphQL errors, such as a subscription's `error` frame
    /// carries: messages, paths and extensions.
    package static func responseErrors(_ data: Data) throws -> [ResponseError] {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { buffer in
            var scanner = Scanner(base: buffer.baseAddress!, count: buffer.count)
            return try scanner.responseErrors()
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

        /// A response's or a part's `errors` array: messages and paths.
        mutating func responseErrors() throws -> [ResponseError] {
            skipWhitespace()
            if peek() == 0x6E { try literal("null"); return [] }
            var read: [ResponseError] = []
            try elements { scanner in
                var error = ResponseError(message: "", path: nil)
                try scanner.members { key, scanner in
                    switch key {
                    case "message": error.message = try scanner.stringValue() ?? ""
                    case "path": error.path = try scanner.path()
                    case "extensions": error.extensions = try scanner.value()
                    default: try scanner.skipValue()
                    }
                }
                read.append(error)
            }
            return read
        }

        /// Any JSON value, as a variable: an error's `extensions`, which the
        /// plan says nothing about. A number without a fraction or an
        /// exponent that `Int` holds is an int; any other is a double.
        mutating func value() throws -> Variable {
            skipWhitespace()
            switch peek() {
            case 0x7B:
                var fields: [String: Variable] = [:]
                try members { key, scanner in fields[key] = try scanner.value() }
                return .object(fields)
            case 0x5B:
                var items: [Variable] = []
                try elements { scanner in items.append(try scanner.value()) }
                return .list(items)
            case 0x22:
                return .string(try stringValue() ?? "")
            case 0x74, 0x66:
                return .bool(try parseBool())
            case 0x6E:
                try literal("null")
                return .null
            default:
                let start = position
                if let int = try? parseInt() { return .int(int) }
                position = start
                return .double(try parseDouble())
            }
        }

        /// A first part's `pending` array: the parts it announces.
        mutating func pending() throws -> [IncrementalPart.Pending] {
            var read: [IncrementalPart.Pending] = []
            try elements { scanner in
                var pending = IncrementalPart.Pending(id: "", path: [], label: nil)
                try scanner.members { key, scanner in
                    switch key {
                    case "id": pending.id = try scanner.stringValue() ?? ""
                    case "path": pending.path = try scanner.path() ?? []
                    case "label": pending.label = try scanner.stringValue()
                    default: try scanner.skipValue()
                    }
                }
                read.append(pending)
            }
            return read
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

        /// Advances over a number's bytes without reading its value.
        @inline(__always)
        mutating func skipNumber() throws {
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
        }

        /// `strtod_l`, which reads in the locale it is given rather than the
        /// thread's, whose decimal separator may be a comma where JSON's is
        /// a point. A null locale is the C locale (`LC_C_LOCALE`), and reads
        /// faster than one `newlocale` makes. The SDK declares the function
        /// in a header Swift imports only through a module it names an
        /// implementation detail, so the C library's symbol is looked up by
        /// name, once (a handle of -2 is `RTLD_DEFAULT`).
        nonisolated(unsafe) static let strtodInLocale = unsafeBitCast(
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), "strtod_l"),
            to: (@convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, locale_t?) -> Double).self
        )

        /// A number read where it lies, in the C locale. JSON puts a
        /// delimiter after it, which stops `strtod_l` there; a number that
        /// ends the input, one followed by a byte `strtod_l` might read on,
        /// or one it did not read to the end the scan found, is copied to the
        /// stack first.
        mutating func parseDouble() throws -> Double {
            let start = position
            try skipNumber()
            let length = position - start
            if position < count {
                let next = base[position]
                if next == 0x2C || next == 0x7D || next == 0x5D || next == 0x20 || next == 0x0A || next == 0x0D || next == 0x09 {
                    let (value, read) = UnsafeRawPointer(base + start).withMemoryRebound(to: CChar.self, capacity: length + 1) { text in
                        var end: UnsafeMutablePointer<CChar>?
                        let value = Scanner.strtodInLocale(text, &end, nil)
                        return (value, end.map { UnsafePointer($0) - text } ?? 0)
                    }
                    if read == length { return value }
                }
            }
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: length + 1) { buffer in
                for offset in 0..<length { buffer[offset] = CChar(bitPattern: base[start + offset]) }
                buffer[length] = 0
                return Scanner.strtodInLocale(buffer.baseAddress!, nil, nil)
            }
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
            default: try skipNumber()
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
