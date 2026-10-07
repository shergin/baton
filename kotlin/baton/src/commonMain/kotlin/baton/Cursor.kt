package baton

/**
 * The plan-driven reader: a scanner over the response, and the change set it
 * fills by the plan. One frame per nesting depth holds what the object being
 * read has given so far; frames are made when the walk first reaches a depth
 * and reused after.
 */
internal class Cursor(bytes: ByteArray, val changes: ChangeSet, private val complete: Boolean) {
    val scanner = Scanner(bytes)
    private val bytes = bytes

    /** What the response says of the parts to follow: the 2024 shape's announcements, and whether there are more. */
    var pending: List<IncrementalPart.Pending> = emptyList()
    var hasNext = false

    /** The response's `errors`, as read; resolved against the plan at the end. */
    val rawErrors = ArrayList<ResponseError>()

    private val frames = ArrayList<Frame>()

    /** The value the last scalar read gave, in the raw encoding. */
    private var valueKind: Byte = Raw.NULL
    private var valueFirst = 0L
    private var valueSecond = 0

    /**
     * One depth's state. Slots are resolved when the object ends, because an
     * abstract selection resolves them against the concrete type the payload
     * names; until then values wait here by field.
     */
    private class Frame {
        val fields = IntList()
        val values = RawValues(16)
        /** Client fields written beside the object's own: the connections' links, by slot index. */
        val extraSlots = IntList()
        val extraValues = RawValues(2)
        /** The records of a plural link being read. */
        val linked = IntList()
        /** Which of the variant's fields the object has answered, for a complete response. */
        var seen = BooleanArray(16)
        /** The values of the key fields the object has given, by the field's place in the key, as spans of the response. */
        var keyStarts = IntArray(2)
        var keyEnds = IntArray(2)
        var keyEscaped = BooleanArray(2)
        var keyGiven = BooleanArray(2)
        var found = 0
        var concreteType = TypeID(0)
        val answers = ArrayList<TypeID>()

        fun resetKeys(count: Int) {
            if (keyGiven.size < count) {
                keyStarts = IntArray(count)
                keyEnds = IntArray(count)
                keyEscaped = BooleanArray(count)
                keyGiven = BooleanArray(count)
            } else {
                keyGiven.fill(false, 0, count)
            }
            found = 0
        }
    }

    fun run(root: ResolvedSelection, rootKey: String) {
        scanner.skipWhitespace()
        var sawData = false
        var rootID = -1
        scanner.members { key ->
            when (key) {
                "data" -> if (scanner.peek() == 'n'.code) {
                    scanner.literal("null")
                } else {
                    rootID = changes.record(rootKey, root.type, -1)
                    objectAt(root, rootID, null, -1, 0, rootID)
                    sawData = true
                }
                "errors" -> rawErrors.addAll(scanner.responseErrors())
                "pending" -> pending = scanner.pending()
                "hasNext" -> hasNext = scanner.parseBool()
                else -> scanner.skipValue()
            }
        }
        if (!sawData) {
            if (rawErrors.isNotEmpty()) {
                throw GraphQLErrors(rawErrors.map { FieldError(it.message, Ingest.render(it.path ?: emptyList()), it.extensions) })
            }
            throw IngestError(scanner.position, "no data in response")
        }
        changes.group()
        if (rawErrors.isNotEmpty()) resolveErrors(root, rootID, emptyList())
    }

    /**
     * Resolves each error's path through the plan and the entries to the
     * record and slot it names. The walk stops at a field whose value is
     * null, a link the response does not continue, or a list index it does
     * not have, and the error lands on the last field it reached: under
     * GraphQL's null propagation, the nullable ancestor. An error whose path
     * is not below [prefix], or reaches no field, is unplaced.
     */
    fun resolveErrors(root: ResolvedSelection, rootID: Int, prefix: List<PathSegment>) {
        for (raw in rawErrors) {
            val path = raw.path
            val error = FieldError(raw.message, Ingest.render(path ?: emptyList()), raw.extensions)
            if (path == null || path.size <= prefix.size || path.subList(0, prefix.size) != prefix) {
                changes.unplacedErrors.add(error)
                continue
            }
            var record = rootID
            var selection = root
            var caught = false
            var resolvedRecord = -1
            var resolvedSlot = 0
            var position = prefix.size
            while (position < path.size) {
                val segment = path[position]
                position += 1
                val variant = selection.variant(changes.recordTypes[record], emptyList())
                if (segment !is PathSegment.Name) break
                val field = variant.field(segment.name) ?: break
                caught = caught || field.caught
                resolvedRecord = record
                resolvedSlot = field.slot.index
                val kind = field.kind as? ResolvedField.Kind.Linked ?: break
                val entry = changes.entry(record, field.slot.index)
                if (entry < 0) break
                when (changes.values.kinds[entry]) {
                    Raw.REF -> {
                        record = changes.values.first[entry].toInt()
                        selection = kind.selection
                    }
                    Raw.REFS -> {
                        val next = path.getOrNull(position) as? PathSegment.Index ?: break
                        if (next.index < 0 || next.index >= changes.values.second[entry]) break
                        position += 1
                        val target = changes.refs[changes.values.first[entry].toInt() + next.index]
                        if (target < 0) break
                        record = target
                        selection = kind.selection
                    }
                    else -> break
                }
            }
            if (resolvedRecord < 0) {
                changes.unplacedErrors.add(error)
                continue
            }
            changes.fieldErrors.add(ChangeSet.FieldErrorEntry(resolvedRecord, resolvedSlot, error, caught))
        }
    }

    /**
     * Reads one object against a selection, appends its entries, and returns
     * its record. Under an interface or union the record's type is the
     * payload's `__typename`, settled before any member is matched, since it
     * picks the variant. The key fields may arrive anywhere: Relay prints the
     * `id` it adds last, and an optimistic response sorts its keys.
     * [listIndex] and [fixedRecord] are -1 when there is none.
     */
    fun objectAt(plan: ResolvedSelection, parent: Int, storageKey: String?, listIndex: Int, depth: Int, fixedRecord: Int): Int {
        val opening = scanner.position
        scanner.expect('{')
        if (depth >= DEPTH_LIMIT) throw IngestError(scanner.position, "selection nested deeper than $DEPTH_LIMIT levels")
        if (depth == frames.size) frames.add(Frame())
        val frame = frames[depth]
        frame.fields.clear()
        frame.values.clear()
        frame.extraSlots.clear()
        frame.extraValues.clear()
        frame.answers.clear()
        var record = fixedRecord
        frame.concreteType = if (fixedRecord >= 0) changes.recordTypes[fixedRecord] else plan.type
        frame.resetKeys(0)
        if (plan.isAbstract && fixedRecord < 0) identity(plan, emptyList(), afterValue = false, wantsKey = false, frame)
        val variant = plan.variant(frame.concreteType, frame.answers)
        for (condition in frame.answers) changes.memberships.add(frame.concreteType to condition)
        val fields = variant.read
        val fieldCount = fields.size
        val keys = variant.keyBytes
        frame.resetKeys(keys.size)
        if (complete) {
            if (frame.seen.size < fieldCount) frame.seen = BooleanArray(fieldCount) else frame.seen.fill(false, 0, fieldCount)
        }
        var expected = 0
        while (true) {
            scanner.skipWhitespace()
            val byte = scanner.peek()
            if (byte == '}'.code) {
                scanner.position += 1
                break
            }
            if (byte == ','.code) {
                scanner.position += 1
                continue
            }
            scanner.scanString()
            val keyStart = scanner.stringStart
            val keyLength = scanner.stringEnd - keyStart
            val keyEscaped = scanner.stringEscaped
            scanner.skipWhitespace()
            scanner.expect(':')
            scanner.skipWhitespace()

            var matched = -1
            if (!keyEscaped) {
                if (expected < fieldCount && fields[expected].keyBytes.size == keyLength && bytes.regionEquals(keyStart, fields[expected].keyBytes)) {
                    matched = expected
                    expected += 1
                } else {
                    for (index in 0 until fieldCount) {
                        if (fields[index].keyBytes.size == keyLength && bytes.regionEquals(keyStart, fields[index].keyBytes)) {
                            matched = index
                            expected = index + 1
                            break
                        }
                    }
                }
            }
            if (matched < 0) {
                scanner.skipValue()
                continue
            }
            if (complete) frame.seen[matched] = true
            val field = fields[matched]

            when (val kind = field.kind) {
                is ResolvedField.Kind.Scalar -> {
                    if (scanner.peek() == 'n'.code) {
                        scanner.literal("null")
                        frame.fields.add(matched)
                        frame.values.add(Raw.NULL, 0, 0)
                        continue
                    }
                    if (kind.list) {
                        scanner.expect('[')
                        val start = changes.scalars.size
                        var items = 0
                        while (true) {
                            scanner.skipWhitespace()
                            val next = scanner.peek()
                            if (next == ']'.code) {
                                scanner.position += 1
                                break
                            }
                            if (next == ','.code) {
                                scanner.position += 1
                                continue
                            }
                            if (next == 'n'.code) {
                                scanner.literal("null")
                                changes.scalars.add(Raw.NULL, 0, 0)
                                items += 1
                                continue
                            }
                            scalarValue(kind.kind)
                            changes.scalars.add(valueKind, valueFirst, valueSecond)
                            items += 1
                            field.edit?.let { deletion(it) }
                        }
                        frame.fields.add(matched)
                        frame.values.add(Raw.LIST, start.toLong(), items)
                        continue
                    }
                    val start = scanner.position
                    scalarValue(kind.kind)
                    if (field.keyIndex >= 0 && record < 0 && !frame.keyGiven[field.keyIndex]) {
                        // A key's value is its text: a string's contents, or a number as the server wrote it.
                        if (valueKind == Raw.STRING || valueKind == Raw.ESCAPED_STRING) {
                            giveKey(frame, field.keyIndex, valueFirst.toInt(), valueSecond, valueKind == Raw.ESCAPED_STRING)
                        } else {
                            giveKey(frame, field.keyIndex, start, scanner.position, false)
                        }
                        if (frame.found == keys.size) record = entity(variant.typeName, frame.concreteType, frame)
                    }
                    frame.fields.add(matched)
                    frame.values.add(valueKind, valueFirst, valueSecond)
                    field.edit?.let { deletion(it) }
                }
                is ResolvedField.Kind.Linked -> {
                    if (scanner.peek() == 'n'.code) {
                        scanner.literal("null")
                        frame.fields.add(matched)
                        frame.values.add(Raw.NULL, 0, 0)
                        continue
                    }
                    if (record < 0) {
                        // A child's key may be a path through this object, so its own key is settled first.
                        identity(plan, keys, afterValue = true, wantsKey = true, frame)
                        record = settle(plan, frame, variant.typeName, keys.size, parent, storageKey, listIndex)
                    }
                    if (kind.plural) {
                        scanner.expect('[')
                        frame.linked.clear()
                        var index = 0
                        while (true) {
                            scanner.skipWhitespace()
                            val next = scanner.peek()
                            if (next == ']'.code) {
                                scanner.position += 1
                                break
                            }
                            if (next == ','.code) {
                                scanner.position += 1
                                continue
                            }
                            if (next == 'n'.code) {
                                scanner.literal("null")
                                frame.linked.add(-1)
                                index += 1
                                continue
                            }
                            frame.linked.add(objectAt(kind.selection, record, field.storageKey, index, depth + 1, -1))
                            index += 1
                        }
                        val start = changes.addRefs(frame.linked.values, frame.linked.size)
                        frame.fields.add(matched)
                        frame.values.add(Raw.REFS, start.toLong(), frame.linked.size)
                        val edit = field.edit
                        if (edit != null) {
                            for (position in 0 until frame.linked.size) {
                                val target = frame.linked.values[position]
                                if (target >= 0) insertion(edit, target)
                            }
                        }
                    } else {
                        val child = objectAt(kind.selection, record, field.storageKey, -1, depth + 1, -1)
                        frame.fields.add(matched)
                        frame.values.add(Raw.REF, child.toLong(), 0)
                        val connection = kind.connection
                        if (connection != null) {
                            // The page is the server's field; the connection it merges into hangs off the parent by Relay's handle key.
                            val connectionRecord = changes.record(changes.recordKeys[record] + ":" + connection.storageKey, kind.selection.type, -1)
                            frame.extraSlots.add(connection.slot.index)
                            frame.extraValues.add(Raw.REF, connectionRecord.toLong(), 0)
                            changes.edits.add(ChangeSet.Edit.Merge(connectionRecord, child, connection.slots, connection.mode))
                        }
                        field.edit?.let { insertion(it, child) }
                    }
                }
            }
        }
        if (complete) {
            // A deferred field arrives in a later part, and a client field in none.
            for (index in variant.expected) {
                if (!frame.seen[index]) {
                    throw IngestError(opening, "the response omits `${fields[index].responseKey}` of `${variant.typeName}`, which the operation selected")
                }
            }
        }
        if (record < 0) record = settle(plan, frame, variant.typeName, keys.size, parent, storageKey, listIndex)
        for (position in 0 until frame.fields.size) {
            changes.addEntry(record, fields[frame.fields.values[position]].slot.index, frame.values.kinds[position], frame.values.first[position], frame.values.second[position])
        }
        for (position in 0 until frame.extraSlots.size) {
            changes.addEntry(record, frame.extraSlots.values[position], frame.extraValues.kinds[position], frame.extraValues.first[position], frame.extraValues.second[position])
        }
        return record
    }

    private fun giveKey(frame: Frame, index: Int, start: Int, end: Int, escaped: Boolean) {
        frame.keyStarts[index] = start
        frame.keyEnds[index] = end
        frame.keyEscaped[index] = escaped
        frame.keyGiven[index] = true
        frame.found += 1
    }

    /** Records the edit an edge directive asks for on a linked field's record. */
    private fun insertion(edit: ResolvedEdit, target: Int) {
        when (edit.kind) {
            Edit.Kind.APPEND_EDGE -> changes.edits.add(ChangeSet.Edit.InsertEdge(target, edit.connections, prepend = false))
            Edit.Kind.PREPEND_EDGE -> changes.edits.add(ChangeSet.Edit.InsertEdge(target, edit.connections, prepend = true))
            Edit.Kind.APPEND_NODE -> edit.edgeType?.let { changes.edits.add(ChangeSet.Edit.InsertNode(target, it, edit.connections, prepend = false)) }
            Edit.Kind.PREPEND_NODE -> edit.edgeType?.let { changes.edits.add(ChangeSet.Edit.InsertNode(target, it, edit.connections, prepend = true)) }
            Edit.Kind.DELETE_EDGE, Edit.Kind.DELETE_RECORD -> Unit
        }
    }

    /** Records the edit a delete directive asks for on the id the last scalar read gave. */
    private fun deletion(edit: ResolvedEdit) {
        if (valueKind != Raw.STRING && valueKind != Raw.ESCAPED_STRING) return
        val id = Text.materialize(bytes, valueFirst.toInt(), valueSecond, valueKind == Raw.ESCAPED_STRING)
        when (edit.kind) {
            Edit.Kind.DELETE_RECORD -> changes.edits.add(ChangeSet.Edit.DeleteRecord(id))
            Edit.Kind.DELETE_EDGE -> changes.edits.add(ChangeSet.Edit.DeleteEdge(id, edit.connections))
            else -> Unit
        }
    }

    /**
     * Finds what an object's identity still lacks among its members, and
     * leaves the scanner where it was: the `__typename` of an abstract
     * selection, from the object's first member, before any member is
     * matched; the key fields not yet given, from the member after the one
     * at the scanner, which is a link's value. Without them an entity whose
     * key follows a link would be keyed by its path, apart from the record
     * every other operation writes.
     */
    private fun identity(plan: ResolvedSelection, keys: List<ByteArray>, afterValue: Boolean, wantsKey: Boolean, frame: Frame) {
        var needsKey = wantsKey && keys.isNotEmpty() && frame.found < keys.size
        var needsType = plan.isAbstract && frame.concreteType == plan.type
        // Relay's membership answers are read while the type is: a type the plan did not list takes its variant from them.
        var needsAnswers = needsType && plan.membershipKeys.isNotEmpty()
        if (!needsKey && !needsType) return
        val resume = scanner.position
        try {
            if (afterValue) scanner.skipValue()
            while (needsKey || needsType || needsAnswers) {
                scanner.skipWhitespace()
                val byte = scanner.peek()
                if (byte == '}'.code) return
                if (byte == ','.code) {
                    scanner.position += 1
                    continue
                }
                scanner.scanString()
                val keyStart = scanner.stringStart
                val keyLength = scanner.stringEnd - keyStart
                val keyEscaped = scanner.stringEscaped
                scanner.skipWhitespace()
                scanner.expect(':')
                scanner.skipWhitespace()
                var keyIndex = -1
                if (needsKey && !keyEscaped) {
                    for ((index, key) in keys.withIndex()) {
                        if (key.size == keyLength && !frame.keyGiven[index] && bytes.regionEquals(keyStart, key)) {
                            keyIndex = index
                            break
                        }
                    }
                }
                if (needsAnswers && !keyEscaped && keyLength > 4 && bytes[keyStart] == UNDERSCORE && bytes[keyStart + 1] == UNDERSCORE) {
                    for ((answer, condition) in plan.membershipKeys) {
                        if (answer.size == keyLength && bytes.regionEquals(keyStart, answer)) frame.answers.add(condition)
                    }
                }
                // A key of a custom scalar may be a number: its text keys the record, as it does before the link.
                val next = scanner.peek()
                if (keyIndex >= 0 && (next == '-'.code || next in '0'.code..'9'.code)) {
                    val start = scanner.position
                    scanner.skipValue()
                    giveKey(frame, keyIndex, start, scanner.position, false)
                    needsKey = frame.found < keys.size
                    continue
                }
                if (keyEscaped || next != '"'.code) {
                    scanner.skipValue()
                    continue
                }
                scanner.scanString()
                val start = scanner.stringStart
                val end = scanner.stringEnd
                val escaped = scanner.stringEscaped
                if (keyIndex >= 0) {
                    giveKey(frame, keyIndex, start, end, escaped)
                    needsKey = frame.found < keys.size
                } else if (needsType && keyLength == TYPENAME.size && bytes.regionEquals(keyStart, TYPENAME)) {
                    frame.concreteType = plan.listedType(bytes, start, end, escaped) ?: Registry.type(Text.materialize(bytes, start, end, escaped))
                    needsType = false
                    // A listed type has its variant; only an unlisted one takes it from the answers, which the whole object is read for.
                    if (plan.lists(frame.concreteType)) needsAnswers = false
                }
            }
        } finally {
            scanner.position = resume
        }
    }

    /** The record of an entity whose key fields were all given, keyed by their values in the key's order. */
    private fun entity(typeName: String, type: TypeID, frame: Frame): Int {
        val count = frame.found
        val value = if (count == 1) {
            Text.materialize(bytes, frame.keyStarts[0], frame.keyEnds[0], frame.keyEscaped[0])
        } else {
            Record.keyValue(List(count) { Text.materialize(bytes, frame.keyStarts[it], frame.keyEnds[it], frame.keyEscaped[it]) })
        }
        return changes.record(Record.entityKey(typeName, value), type, Record.idOffset(typeName))
    }

    /**
     * The record of an object whose key is not settled yet: an entity's when
     * every key field was given, else a client key from the path. Under an
     * interface or union the path key ends in the concrete type, so a payload
     * of another type at the same path is another record.
     */
    private fun settle(plan: ResolvedSelection, frame: Frame, typeName: String, keyCount: Int, parent: Int, storageKey: String?, listIndex: Int): Int {
        if (keyCount > 0 && frame.found == keyCount) return entity(typeName, frame.concreteType, frame)
        val key = buildString {
            append(changes.recordKeys[parent])
            append(':')
            append(storageKey ?: "")
            if (listIndex >= 0) {
                append(':')
                append(listIndex)
            }
            if (plan.isAbstract) {
                append(':')
                append(typeName)
            }
        }
        return changes.record(key, frame.concreteType, -1)
    }

    /** Reads a scalar by its kind into the value registers. */
    private fun scalarValue(kind: ScalarKind) {
        when (kind) {
            ScalarKind.STRING -> string()
            ScalarKind.INT -> set(Raw.INT, scanner.parseInt(), 0)
            ScalarKind.DOUBLE -> set(Raw.DOUBLE, scanner.parseDouble().toRawBits(), 0)
            ScalarKind.BOOL -> set(Raw.BOOL, if (scanner.parseBool()) 1 else 0, 0)
            ScalarKind.CUSTOM -> {
                // A custom scalar is its text: a string's contents, or the bytes of any other token as the server wrote them.
                if (scanner.peek() == '"'.code) {
                    string()
                } else {
                    val start = scanner.position
                    scanner.skipValue()
                    set(Raw.STRING, start.toLong(), scanner.position)
                }
            }
        }
    }

    private fun string() {
        scanner.scanString()
        set(if (scanner.stringEscaped) Raw.ESCAPED_STRING else Raw.STRING, scanner.stringStart.toLong(), scanner.stringEnd)
    }

    private fun set(kind: Byte, first: Long, second: Int) {
        valueKind = kind
        valueFirst = first
        valueSecond = second
    }

    private companion object {
        /** How deep a selection may nest. */
        const val DEPTH_LIMIT = 24
        const val UNDERSCORE: Byte = 0x5F
        val TYPENAME = "__typename".encodeToByteArray()
    }
}

/** A growable list of ints, reused by the cursor's frames. */
internal class IntList {
    var values = IntArray(8)
        private set
    var size = 0
        private set

    fun add(value: Int) {
        if (size == values.size) values = values.copyOf(size * 2)
        values[size] = value
        size += 1
    }

    fun clear() {
        size = 0
    }
}
