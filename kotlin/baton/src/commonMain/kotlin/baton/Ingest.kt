package baton

/** A response that is not well formed: what was expected, and the byte offset where it was not. */
class IngestError internal constructor(val offset: Int, override val message: String) : Exception() {
    override fun toString(): String = "ingest error at byte $offset: $message"
}

/** One step of a response path: a field by response key, or a list index. */
internal sealed interface PathSegment {
    data class Name(val name: String) : PathSegment
    data class Index(val index: Int) : PathSegment
}

/** An entry of a response's `errors`, as read: its message, its path and its `extensions`. */
internal class ResponseError(val message: String, val path: List<PathSegment>?, val extensions: Variable? = null)

/**
 * A part of an incremental response after the first: the items it delivers,
 * the parts it announces, the announced parts it completes, and whether
 * more follow. Reads the June 2023 shape (`incremental[{data, path,
 * label}]`), the 2024 one (`pending[{id, path, label}]`, `incremental[{id,
 * data, subPath}]`, `completed[{id, errors}]`), and Relay's (`{data, path,
 * label}` per part).
 */
internal class IncrementalPart(
    val items: List<Item>,
    val pending: List<Pending>,
    val completed: List<Completed>,
    val hasNext: Boolean,
) {
    class Item(
        val path: List<PathSegment>?,
        val label: String?,
        val id: String?,
        /** Below the announced part's path, where the data is, in the 2024 shape. */
        val subPath: List<PathSegment>?,
        val data: ByteArray,
        /** The field errors that came with the item, by absolute path. */
        val errors: List<ResponseError>,
    )

    class Pending(val id: String, val path: List<PathSegment>, val label: String?)

    /** An announced part the server has finished, with the errors that kept it from being delivered, if any. */
    class Completed(val id: String, val errors: List<ResponseError>)
}

/** A whole response, or the first part of an incremental one: its change set, the parts it announces and whether more follow. */
internal class FirstPart(val changes: ChangeSet, val pending: List<IncrementalPart.Pending>, val hasNext: Boolean)

/**
 * Decodes a GraphQL response straight into a change set, following a
 * resolved plan: one pass over the bytes, no intermediate tree. It runs off
 * the store's thread and touches no record. See `spec/runtime.md`, section 3.
 */
internal object Ingest {
    /** The change set a response normalizes to; see [normalizeFirstPart]. */
    fun normalize(bytes: ByteArray, plan: ResolvedSelection, rootKey: String, complete: Boolean = false): ChangeSet =
        normalizeFirstPart(bytes, plan, rootKey, complete).changes

    /**
     * A response, or the first part of an incremental one, with what it says
     * of the parts to follow. A [complete] response answers every field the
     * plan selects, as a server answers an operation: an object that omits
     * one is malformed. An optimistic response or a payload committed by hand
     * may carry part of the selection.
     */
    fun normalizeFirstPart(bytes: ByteArray, plan: ResolvedSelection, rootKey: String, complete: Boolean = false): FirstPart {
        val cursor = Cursor(bytes, ChangeSet(bytes), complete)
        cursor.run(plan, rootKey)
        return FirstPart(cursor.changes, cursor.pending, cursor.hasNext)
    }

    /**
     * One object, as a deferred part delivers it: the selection the part
     * fills, at the record its path named, read as that record's type. An
     * error under the object's [path] lands on the field it names; any other
     * is unplaced.
     */
    fun normalizeObject(
        bytes: ByteArray,
        plan: ResolvedSelection,
        key: String,
        type: TypeID,
        entity: Boolean,
        path: List<PathSegment> = emptyList(),
        errors: List<ResponseError> = emptyList(),
    ): ChangeSet {
        val cursor = Cursor(bytes, ChangeSet(bytes), complete = false)
        cursor.scanner.skipWhitespace()
        val root = cursor.changes.record(key, type, if (entity) Record.idOffset(type.name) else -1)
        cursor.objectAt(plan, root, null, -1, 0, root)
        cursor.changes.group()
        if (errors.isNotEmpty()) {
            cursor.rawErrors.addAll(errors)
            cursor.resolveErrors(plan, root, path)
        }
        return cursor.changes
    }

    /** An announced part the server could not deliver: its errors on the fields it would have filled, and the errors a `@throwOnFieldError` operation counts. */
    class FailedPart(val changes: ChangeSet, val uncaught: List<FieldError>)

    /**
     * The field errors of an announced part the server could not deliver, on
     * the fields the part would have filled, so a `@catch` there reads them.
     * A field holds one error, the first; the errors are caught when every
     * one of those fields is under `@catch`.
     */
    fun failed(plan: ResolvedSelection, key: String, type: TypeID, entity: Boolean, path: List<PathSegment>, errors: List<ResponseError>): FailedPart {
        val changes = ChangeSet(ByteArray(0))
        val record = changes.record(key, type, if (entity) Record.idOffset(type.name) else -1)
        changes.group()
        val rendered = errors.map { FieldError(it.message, render(it.path ?: path), it.extensions) }
        val first = rendered.firstOrNull() ?: return FailedPart(changes, emptyList())
        val fields = plan.variant(type, emptyList()).read
        if (fields.isEmpty()) {
            changes.unplacedErrors.addAll(rendered)
            return FailedPart(changes, rendered)
        }
        for (field in fields) changes.fieldErrors.add(ChangeSet.FieldErrorEntry(record, field.slot.index, first, field.caught))
        return FailedPart(changes, if (fields.all { it.caught }) emptyList() else rendered)
    }

    /** A response path, dotted, as a field error shows it. */
    fun render(path: List<PathSegment>): String = path.joinToString(".") { segment ->
        when (segment) {
            is PathSegment.Name -> segment.name
            is PathSegment.Index -> segment.index.toString()
        }
    }

    /** Reads a part of an incremental response after the first. */
    fun incremental(bytes: ByteArray): IncrementalPart {
        val scanner = Scanner(bytes)
        val items = ArrayList<IncrementalPart.Item>()
        var pending: List<IncrementalPart.Pending> = emptyList()
        val completed = ArrayList<IncrementalPart.Completed>()
        var hasNext = false
        var topData: ByteArray? = null
        var topPath: List<PathSegment>? = null
        var topLabel: String? = null
        var topErrors: List<ResponseError> = emptyList()
        scanner.members { key ->
            when (key) {
                "incremental" -> scanner.elements {
                    var path: List<PathSegment>? = null
                    var subPath: List<PathSegment>? = null
                    var label: String? = null
                    var id: String? = null
                    var data = ByteArray(0)
                    var errors: List<ResponseError> = emptyList()
                    scanner.members { member ->
                        when (member) {
                            "data" -> data = scanner.rawValue()
                            "path" -> path = scanner.path()
                            "subPath" -> subPath = scanner.path()
                            "label" -> label = scanner.stringValue()
                            "id" -> id = scanner.stringValue()
                            "errors" -> errors = scanner.responseErrors()
                            else -> scanner.skipValue()
                        }
                    }
                    items.add(IncrementalPart.Item(path, label, id, subPath, data, errors))
                }
                "pending" -> pending = scanner.pending()
                "completed" -> scanner.elements {
                    var id = ""
                    var errors: List<ResponseError> = emptyList()
                    scanner.members { member ->
                        when (member) {
                            "id" -> id = scanner.stringValue() ?: ""
                            "errors" -> errors = scanner.responseErrors()
                            else -> scanner.skipValue()
                        }
                    }
                    completed.add(IncrementalPart.Completed(id, errors))
                }
                "hasNext" -> hasNext = scanner.parseBool()
                "data" -> topData = scanner.rawValue()
                "path" -> topPath = scanner.path()
                "label" -> topLabel = scanner.stringValue()
                "errors" -> topErrors = scanner.responseErrors()
                else -> scanner.skipValue()
            }
        }
        val data = topData
        if (data != null && topPath != null) items.add(IncrementalPart.Item(topPath, topLabel, null, null, data, topErrors))
        return IncrementalPart(items, pending, completed, hasNext)
    }
}

/**
 * The lexical layer over a response's bytes: a position and the reads that
 * move it. An envelope, a part and the `errors` array need nothing more; the
 * cursor adds the part the plan drives.
 */
internal class Scanner(val bytes: ByteArray) {
    var position = 0
    private val count = bytes.size

    fun peek(): Int = if (position < count) bytes[position].toInt() and 0xFF else 0

    fun skipWhitespace() {
        while (position < count) {
            val byte = bytes[position].toInt()
            if (byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09) position += 1 else return
        }
    }

    fun expect(byte: Char) {
        if (position >= count || bytes[position] != byte.code.toByte()) throw IngestError(position, "expected '$byte'")
        position += 1
    }

    /** Where the string at the position starts and ends inside its quotes, and whether it has an escape. */
    var stringStart = 0
        private set
    var stringEnd = 0
        private set
    var stringEscaped = false
        private set

    fun scanString() {
        expect('"')
        val start = position
        var escaped = false
        while (position < count) {
            val byte = bytes[position]
            if (byte == QUOTE) {
                stringStart = start
                stringEnd = position
                stringEscaped = escaped
                position += 1
                return
            }
            if (byte == BACKSLASH) {
                escaped = true
                position += 2
            } else {
                position += 1
            }
        }
        throw IngestError(start, "unterminated string")
    }

    fun literal(text: String) {
        if (position + text.length > count) throw IngestError(position, "expected $text")
        for (offset in text.indices) {
            if (bytes[position + offset] != text[offset].code.toByte()) throw IngestError(position, "expected $text")
        }
        position += text.length
    }

    /** Iterates an object's members, leaving each value to [handle]. */
    inline fun members(handle: (String) -> Unit) {
        skipWhitespace()
        expect('{')
        while (true) {
            skipWhitespace()
            val byte = peek()
            if (byte == '}'.code) {
                position += 1
                return
            }
            if (byte == ','.code) {
                position += 1
                continue
            }
            scanString()
            val key = Text.materialize(bytes, stringStart, stringEnd, stringEscaped)
            skipWhitespace()
            expect(':')
            skipWhitespace()
            handle(key)
        }
    }

    /** Iterates an array's elements, leaving each to [handle]. */
    inline fun elements(handle: () -> Unit) {
        skipWhitespace()
        expect('[')
        while (true) {
            skipWhitespace()
            val byte = peek()
            if (byte == ']'.code) {
                position += 1
                return
            }
            if (byte == ','.code) {
                position += 1
                continue
            }
            handle()
        }
    }

    /** A string value, or null for `null`. */
    fun stringValue(): String? {
        skipWhitespace()
        if (peek() == 'n'.code) {
            literal("null")
            return null
        }
        scanString()
        return Text.materialize(bytes, stringStart, stringEnd, stringEscaped)
    }

    /** The bytes of one value, verbatim. */
    fun rawValue(): ByteArray {
        skipWhitespace()
        val start = position
        skipValue()
        return bytes.copyOfRange(start, position)
    }

    /** A response's or a part's `errors` array: messages, paths and extensions. */
    fun responseErrors(): List<ResponseError> {
        skipWhitespace()
        if (peek() == 'n'.code) {
            literal("null")
            return emptyList()
        }
        val read = ArrayList<ResponseError>()
        elements {
            var message = ""
            var path: List<PathSegment>? = null
            var extensions: Variable? = null
            members { key ->
                when (key) {
                    "message" -> message = stringValue() ?: ""
                    "path" -> path = path()
                    "extensions" -> extensions = value()
                    else -> skipValue()
                }
            }
            read.add(ResponseError(message, path, extensions))
        }
        return read
    }

    /** Any JSON value as a variable: a number without a fraction or exponent that a `Long` holds is an int, any other a double. */
    fun value(): Variable {
        skipWhitespace()
        return when (peek()) {
            '{'.code -> {
                val fields = LinkedHashMap<String, Variable>()
                members { key -> fields[key] = value() }
                Variable.Object(fields)
            }
            '['.code -> {
                val items = ArrayList<Variable>()
                elements { items.add(value()) }
                Variable.List(items)
            }
            '"'.code -> Variable.String(stringValue() ?: "")
            't'.code, 'f'.code -> Variable.Bool(parseBool())
            'n'.code -> {
                literal("null")
                Variable.Null
            }
            else -> {
                val start = position
                try {
                    Variable.Int(parseInt())
                } catch (_: IngestError) {
                    position = start
                    Variable.Double(parseDouble())
                }
            }
        }
    }

    /** A first part's `pending` array: the parts it announces. */
    fun pending(): List<IncrementalPart.Pending> {
        val read = ArrayList<IncrementalPart.Pending>()
        elements {
            var id = ""
            var path: List<PathSegment> = emptyList()
            var label: String? = null
            members { key ->
                when (key) {
                    "id" -> id = stringValue() ?: ""
                    "path" -> path = path() ?: emptyList()
                    "label" -> label = stringValue()
                    else -> skipValue()
                }
            }
            read.add(IncrementalPart.Pending(id, path, label))
        }
        return read
    }

    /** A response path of strings and integers; one with an index that is not an integer names nothing, and is null. */
    fun path(): List<PathSegment>? {
        skipWhitespace()
        if (peek() == 'n'.code) {
            literal("null")
            return null
        }
        val segments = ArrayList<PathSegment>()
        var readable = true
        elements {
            if (peek() == '"'.code) {
                scanString()
                segments.add(PathSegment.Name(Text.materialize(bytes, stringStart, stringEnd, stringEscaped)))
            } else {
                val start = position
                try {
                    val index = parseInt()
                    if (index < Int.MIN_VALUE || index > Int.MAX_VALUE) readable = false else segments.add(PathSegment.Index(index.toInt()))
                } catch (_: IngestError) {
                    position = start
                    skipValue()
                    readable = false
                }
            }
        }
        return if (readable) segments else null
    }

    /** An integer a `Long` holds. A fraction, an exponent or a value out of range is an error, not a rounding. */
    fun parseInt(): Long {
        val start = position
        var negative = false
        if (peek() == '-'.code) {
            negative = true
            position += 1
        }
        // The magnitude, so that `Long.MIN_VALUE` reads without overflowing.
        var magnitude = 0uL
        var overflow = false
        var digits = 0
        while (position < count) {
            val digit = bytes[position] - '0'.code.toByte()
            if (digit !in 0..9) break
            if (magnitude > (ULong.MAX_VALUE - digit.toULong()) / 10uL) overflow = true
            magnitude = magnitude * 10uL + digit.toULong()
            position += 1
            digits += 1
        }
        if (digits == 0) throw IngestError(position, "expected a number")
        if (position < count) {
            val next = bytes[position]
            if (next == DOT || next == LOWER_E || next == UPPER_E) throw IngestError(start, "expected an integer")
        }
        val limit = if (negative) Long.MAX_VALUE.toULong() + 1uL else Long.MAX_VALUE.toULong()
        if (overflow || magnitude > limit) throw IngestError(start, "integer out of range")
        return if (negative) (0uL - magnitude).toLong() else magnitude.toLong()
    }

    /** Advances over a number's bytes without reading its value. */
    fun skipNumber() {
        val start = position
        while (position < count) {
            val byte = bytes[position]
            if ((byte >= ZERO && byte <= NINE) || byte == MINUS || byte == PLUS || byte == DOT || byte == LOWER_E || byte == UPPER_E) {
                position += 1
            } else {
                break
            }
        }
        if (position == start) throw IngestError(position, "expected a number")
    }

    /** A number read as JSON writes it, whatever the platform's locale. */
    fun parseDouble(): Double {
        val start = position
        skipNumber()
        return bytes.decodeToString(start, position).toDoubleOrNull() ?: throw IngestError(start, "expected a number")
    }

    fun parseBool(): Boolean {
        skipWhitespace()
        if (peek() == 't'.code) {
            literal("true")
            return true
        }
        literal("false")
        return false
    }

    fun skipValue() {
        skipWhitespace()
        when (peek()) {
            '"'.code -> scanString()
            '{'.code, '['.code -> {
                var depth = 0
                while (position < count) {
                    val byte = bytes[position]
                    if (byte == QUOTE) {
                        scanString()
                        continue
                    }
                    if (byte == OPEN_BRACE || byte == OPEN_BRACKET) depth += 1
                    if (byte == CLOSE_BRACE || byte == CLOSE_BRACKET) {
                        depth -= 1
                        if (depth == 0) {
                            position += 1
                            return
                        }
                    }
                    position += 1
                }
                throw IngestError(position, "unterminated value")
            }
            't'.code -> literal("true")
            'f'.code -> literal("false")
            'n'.code -> literal("null")
            else -> skipNumber()
        }
    }

    internal companion object {
        const val QUOTE: Byte = 0x22
        const val BACKSLASH: Byte = 0x5C
        const val OPEN_BRACE: Byte = 0x7B
        const val CLOSE_BRACE: Byte = 0x7D
        const val OPEN_BRACKET: Byte = 0x5B
        const val CLOSE_BRACKET: Byte = 0x5D
        const val ZERO: Byte = 0x30
        const val NINE: Byte = 0x39
        const val MINUS: Byte = 0x2D
        const val PLUS: Byte = 0x2B
        const val DOT: Byte = 0x2E
        const val LOWER_E: Byte = 0x65
        const val UPPER_E: Byte = 0x45
    }
}
