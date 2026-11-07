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

    /**
     * The entities' objects the walk finished under selections whose repeats
     * may be skipped: where each began, how long it ran, the record it
     * settled as and the entries its parse appended, by the selection and a
     * hash of the object's first bytes. A later object under that selection
     * whose bytes equal a span's is the entity printed again: it takes the
     * record and the walk moves past it. The first printing's entries are
     * appended again in its place when a later printing wrote one of the
     * records they name since, so that the change set is the one a parse
     * would make and the last printing of a record still wins; when none
     * did, they stand last for every record already and nothing is
     * appended. Open addressing at half load, one span per key, the first,
     * so a key many objects share costs a missed skip and never a wrong one.
     */
    private var spanHashes = LongArray(spanCapacity(bytes.size / 512 + 4))
    private var spanSelections = arrayOfNulls<ResolvedSelection>(spanHashes.size)
    private var spanStarts = IntArray(spanHashes.size)
    private var spanLengths = IntArray(spanHashes.size)
    private var spanRecords = IntArray(spanHashes.size)
    private var spanEntriesStarts = IntArray(spanHashes.size)
    private var spanEntriesEnds = IntArray(spanHashes.size)
    /** The pass at which each span's object closed. */
    private var spanClosedAt = IntArray(spanHashes.size)
    private var spanCount = 0

    /**
     * The passes of the walk: one per object closed and per span whose
     * entries were appended again, in order. A span closed at a pass stands
     * while no record its entries name was written at a later one; the
     * change set keeps the pass each record was written at.
     */
    private var pass = 0

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
        // An entity printed again under this selection is the record its first
        // printing settled as, found by one compare. An object at a fixed
        // record, the root's or a deferred part's, neither looks one up nor is
        // remembered; nor does one under a selection with no key fields, which
        // settles as a record keyed by its path.
        val skippable = plan.skipsRepeats && fixedRecord < 0 && plan.key.isNotEmpty()
        var prefix = 0L
        if (skippable) {
            prefix = prefixHash(opening)
            val found = repeated(plan, prefix, opening)
            if (found >= 0) {
                changes.skipped += 1
                return found
            }
        }
        val entriesBefore = changes.entryCount
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
                        if (field.streams) changes.streams.add(record to field.slot.index)
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
                        val paged = field.paged
                        if (paged != null) {
                            // The container is the server's page; the record the paged list merges into hangs off the parent by
                            // the list's client key, and takes the page when the run named one.
                            val listRecord = changes.record(changes.recordKeys[record] + ":" + paged.storageKey, kind.selection.type, -1)
                            frame.extraSlots.add(paged.slot.index)
                            frame.extraValues.add(Raw.REF, listRecord.toLong(), 0)
                            val number = paged.page
                            if (number != null) changes.edits.add(ChangeSet.Edit.MergePage(listRecord, child, paged, number))
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
        wrote(record)
        // Only an entity is remembered: an object keyed by its path is another record under another parent.
        if (skippable && changes.recordIDOffsets[record] >= 0) remember(plan, prefix, opening, scanner.position, record, entriesBefore)
        return record
    }

    /**
     * A hash of up to the first 64 bytes at [start], eight at a time, which
     * needs no end to compute: an object's opening, its first keys and, as
     * Relay prints objects, its type and its first values.
     */
    private fun prefixHash(start: Int): Long {
        val length = minOf(64, bytes.size - start)
        var hash = 0x9E3779B97F4A7C15uL.toLong()
        var offset = 0
        while (offset + 8 <= length) {
            var word = 0L
            for (index in 0 until 8) word = (word shl 8) or (bytes[start + offset + index].toLong() and 0xFF)
            hash = (hash xor word) * 0xFF51AFD7ED558CCDuL.toLong()
            hash = hash xor (hash ushr 32)
            offset += 8
        }
        while (offset < length) {
            hash = (hash xor (bytes[start + offset].toLong() and 0xFF)) * 0x100000001B3L
            offset += 1
        }
        return hash
    }

    /**
     * The record of the object at [opening] when its bytes equal those of the
     * object remembered under the selection and the hash, the first printing's
     * entries appended again where they no longer stand last and the walk
     * moved past the bytes; -1 when none is remembered or the bytes differ.
     */
    private fun repeated(plan: ResolvedSelection, hash: Long, opening: Int): Int {
        val mask = spanHashes.size - 1
        var slot = hash.toInt() and mask
        while (true) {
            val selection = spanSelections[slot] ?: return -1
            if (spanHashes[slot] == hash && selection === plan) {
                val length = spanLengths[slot]
                if (opening + length > bytes.size || !bytes.regionsEqual(opening, spanStarts[slot], length)) return -1
                if (!stands(slot)) {
                    pass += 1
                    changes.replayEntries(spanEntriesStarts[slot], spanEntriesEnds[slot], pass)
                }
                scanner.position = opening + length
                return spanRecords[slot]
            }
            slot = (slot + 1) and mask
        }
    }

    /**
     * Whether the span's entries stand last for every record they name, none
     * having been written since the span closed, so that appending them
     * again would change nothing the grouping keeps.
     */
    private fun stands(slot: Int): Boolean {
        val closedAt = spanClosedAt[slot]
        val entryRecords = changes.entryRecords
        val writtenAt = changes.recordWrittenAt
        for (index in spanEntriesStarts[slot] until spanEntriesEnds[slot]) {
            if (writtenAt[entryRecords[index]] > closedAt) return false
        }
        return true
    }

    /** Closes a pass of the walk in which entries named the record. */
    private fun wrote(record: Int) {
        pass += 1
        changes.wrote(record, pass)
    }

    /** Remembers the entity's object just read, with the entries its parse appended from [entriesFrom] on, unless the key already has a span. */
    private fun remember(plan: ResolvedSelection, hash: Long, start: Int, end: Int, record: Int, entriesFrom: Int) {
        if ((spanCount + 1) * 2 > spanHashes.size) growSpans()
        val mask = spanHashes.size - 1
        var slot = hash.toInt() and mask
        while (true) {
            val selection = spanSelections[slot] ?: break
            if (spanHashes[slot] == hash && selection === plan) return
            slot = (slot + 1) and mask
        }
        spanHashes[slot] = hash
        spanSelections[slot] = plan
        spanStarts[slot] = start
        spanLengths[slot] = end - start
        spanRecords[slot] = record
        spanEntriesStarts[slot] = entriesFrom
        spanEntriesEnds[slot] = changes.entryCount
        spanClosedAt[slot] = pass
        spanCount += 1
    }

    private fun growSpans() {
        val oldHashes = spanHashes
        val oldSelections = spanSelections
        val oldStarts = spanStarts
        val oldLengths = spanLengths
        val oldRecords = spanRecords
        val oldEntriesStarts = spanEntriesStarts
        val oldEntriesEnds = spanEntriesEnds
        val oldClosedAt = spanClosedAt
        spanHashes = LongArray(oldHashes.size * 2)
        spanSelections = arrayOfNulls(spanHashes.size)
        spanStarts = IntArray(spanHashes.size)
        spanLengths = IntArray(spanHashes.size)
        spanRecords = IntArray(spanHashes.size)
        spanEntriesStarts = IntArray(spanHashes.size)
        spanEntriesEnds = IntArray(spanHashes.size)
        spanClosedAt = IntArray(spanHashes.size)
        val mask = spanHashes.size - 1
        for (old in oldHashes.indices) {
            val selection = oldSelections[old] ?: continue
            var slot = oldHashes[old].toInt() and mask
            while (spanSelections[slot] != null) slot = (slot + 1) and mask
            spanHashes[slot] = oldHashes[old]
            spanSelections[slot] = selection
            spanStarts[slot] = oldStarts[old]
            spanLengths[slot] = oldLengths[old]
            spanRecords[slot] = oldRecords[old]
            spanEntriesStarts[slot] = oldEntriesStarts[old]
            spanEntriesEnds[slot] = oldEntriesEnds[old]
            spanClosedAt[slot] = oldClosedAt[old]
        }
    }

    /** Slots for the expected entities at half load, a power of two. */
    private fun spanCapacity(expected: Int): Int {
        var capacity = 16
        while (capacity < expected * 2) capacity *= 2
        return capacity
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
        if (count == 1 && !frame.keyEscaped[0]) return changes.entityRecord(typeName, type, frame.keyStarts[0], frame.keyEnds[0])
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
