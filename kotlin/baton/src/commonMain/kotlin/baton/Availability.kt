package baton

// The availability check: whether the store holds an operation's data, and
// the lookups it binds on the way. Memory answers first; when it cannot and
// the store has an image, the same walk runs again with the image at hand,
// and what it reads becomes part of the store. See `spec/runtime.md`,
// section 5.

/** Where the availability check found the selection's data. */
internal enum class Answer {
    /** In memory, every record of it put there by a response. */
    MEMORY,

    /** With the image's help: read from it now, or by an earlier check. */
    IMAGE,

    /** Not all of it, in memory or in the image. */
    MISS,
}

/**
 * The state of one availability walk: the local batch of what it writes,
 * and whether the walk in memory met a record or a root field the image
 * filled.
 */
private class Walk(val batch: Store.Batch) {
    var met = false
}

/**
 * Whether every field of the selection is present, starting at [record]. A
 * missing link with a lookup is satisfied by the cached entity, and the link
 * is written so later reads are direct. What the walk writes, a lookup's
 * link bound, a link repaired, a cell filled from the image, is one local
 * batch.
 */
internal fun Store.check(selection: ResolvedSelection, record: Record = root): Answer {
    checkThread()
    if (ended) return Answer.MISS
    adoptConstants()
    // What the image's responses taught in earlier launches, before the walk
    // resolves a variant for a type the plan did not list.
    persistence?.let { image ->
        for ((type, condition) in image.takeMemberships()) Membership.learn(Registry.type(type), Registry.type(condition))
    }
    var answer = Answer.MISS
    local { batch ->
        val walk = Walk(batch)
        if (available(selection.variant(record.type), record, null, walk)) {
            answer = if (walk.met) Answer.IMAGE else Answer.MEMORY
            return@local
        }
        val image = persistence ?: return@local
        val found = image.reading { disk -> available(selection.variant(record.type), record, disk, walk) }
        answer = if (found) Answer.IMAGE else Answer.MISS
    }
    return answer
}

/**
 * The walk over one record's fields the check waits for, then the client
 * fields, then the connections' client links: a missing scalar is a miss; a
 * missing link with a lookup is satisfied by the entity the lookup names; a
 * missing link without one is a miss; a null link is fine; a link is
 * followed, a deleted target not entered; every element of a list is
 * followed. Without a disk it reads memory as it stands; with one, a record
 * that lacks a field reads its row first, a link to a record the collector
 * swept is pointed at the live record of that key, and a connection's
 * client record is walked while it holds nothing.
 */
private fun Store.available(variant: ResolvedVariant, record: Record, disk: Disk?, walk: Walk): Boolean {
    val fields = variant.waits
    if (disk == null) {
        if (record.hydrated) {
            walk.met = true
        } else if (record === root && hydratedRootSlots.isNotEmpty() && fields.any { it.slot.index in hydratedRootSlots }) {
            walk.met = true
        }
    }
    for (field in fields) {
        val slot = field.slot
        if (disk != null && record.peek(slot) == Value.Missing) hydrate(record, slot, disk, walk.batch)
        val kind = field.kind
        if (kind !is ResolvedField.Kind.Linked) {
            if (record.peek(slot) == Value.Missing) return false
            continue
        }
        when (val value = record.peek(slot)) {
            Value.Missing -> {
                val lookup = kind.lookup
                if (kind.plural || lookup == null) return false
                val target = resolve(lookup, disk, walk.batch) ?: return false
                if (!available(kind.selection.variant(target.type), target, disk, walk)) return false
                set(record, slot, Value.Ref(target), walk.batch)
            }
            Value.Null -> Unit
            is Value.Ref -> {
                var target = value.record
                if (disk != null) {
                    target = live(target, disk, walk.batch)
                    if (target !== value.record) set(record, slot, Value.Ref(target), walk.batch)
                }
                if (!target.deleted && !available(kind.selection.variant(target.type), target, disk, walk)) return false
            }
            is Value.Refs -> {
                val targets = if (disk == null) value.records else relinked(record, slot, value.records, disk, walk.batch)
                for (target in targets) {
                    if (target == null || target.deleted) continue
                    if (!available(kind.selection.variant(target.type), target, disk, walk)) return false
                }
            }
            else -> return false
        }
    }
    // A client field is never waited for, but the image holds what a payload
    // wrote: it is hydrated here, and the records behind a client link
    // brought back, without a miss for what no server sends.
    if (disk != null) {
        for (field in variant.payloadFields) {
            val slot = field.slot
            if (record.peek(slot) == Value.Missing) hydrate(record, slot, disk, walk.batch)
            val kind = field.kind as? ResolvedField.Kind.Linked ?: continue
            when (val value = record.peek(slot)) {
                is Value.Ref -> {
                    val target = live(value.record, disk, walk.batch)
                    if (target !== value.record) set(record, slot, Value.Ref(target), walk.batch)
                    if (!target.deleted) available(kind.selection.variant(target.type), target, disk, walk)
                }
                is Value.Refs -> {
                    for (target in relinked(record, slot, value.records, disk, walk.batch)) {
                        if (target != null && !target.deleted) available(kind.selection.variant(target.type), target, disk, walk)
                    }
                }
                else -> Unit
            }
        }
    }
    // Lenses read a connection through its client record, which the walk
    // above does not pass. A merge always fills it, so one that holds
    // nothing, swept or never filled, is not in memory: the image may hold
    // it, or have been told to forget it. With the image at hand it is
    // walked, so its merged pages come back with it, and one the image has
    // no row for stays a miss. The root's link is a cell of its own in the
    // image, read here, since the walk above hydrates the root a waited
    // field at a time and waits for no client link.
    for (link in variant.clientLinks) {
        if (disk != null && record.peek(link.slot) == Value.Missing) hydrate(record, link.slot, disk, walk.batch)
        val kind = link.kind as? ResolvedField.Kind.Linked ?: continue
        val found = (record.peek(link.slot) as? Value.Ref)?.record ?: continue
        if (!found.swept && !found.isEmpty) continue
        if (disk == null) return false
        val merged = live(found, disk, walk.batch)
        if (merged !== found) set(record, link.slot, Value.Ref(merged), walk.batch)
        if (!merged.deleted && !available(kind.selection.variant(merged.type), merged, disk, walk)) return false
    }
    return true
}

/** A list's targets as the store and the image know them together, the list written again when one moved. */
private fun Store.relinked(record: Record, slot: Slot, targets: List<Record?>, disk: Disk, batch: Store.Batch): List<Record?> {
    var moved = false
    val live = targets.map { found ->
        if (found == null) return@map null
        val target = live(found, disk, batch)
        if (target !== found) moved = true
        target
    }
    if (!moved) return targets
    set(record, slot, Value.Refs(live), batch)
    return live
}

/**
 * A link's target as the store and the image know it together: the live
 * record of the key when the collector swept the one the link holds, and,
 * for a record that holds nothing yet, its row, so that whether it was
 * deleted is known before the walk decides to enter it.
 */
private fun Store.live(found: Record, disk: Disk, batch: Store.Batch): Record {
    val record = if (found.swept) target(found.key, found.type, found.isEntity) else found
    if (!record.hydrated && record.isEmpty && record !== root && record !== mutationRoot && record !== subscriptionRoot) {
        hydrate(record, disk, batch)
    }
    return record
}

/** Reads from the image what a record lacks: the root's field, or the record's row, once. */
private fun Store.hydrate(record: Record, slot: Slot, disk: Disk, batch: Store.Batch) {
    if (record === root) {
        hydrateRoot(slot, disk, batch)
    } else if (!record.hydrated && record !== mutationRoot && record !== subscriptionRoot) {
        hydrate(record, disk, batch)
    }
}

/**
 * Whether every deferred part of a selection the check found is whole, in
 * memory or, through the check, in the image. The check passes over
 * deferred fields, while a record read from the image holds every cell of
 * its row, a deferred fragment's link among them, with nothing behind it:
 * such a field is cleared, so its fragment reads absent rather than empty,
 * unless a field outside the deferred part reads the same slot. Either way
 * the answer is false, so the operation fetches.
 */
internal fun Store.deferredPartsHold(selection: ResolvedSelection, record: Record = root): Boolean {
    var whole = true
    local { batch -> whole = deferredParts(selection, record, batch) }
    return whole
}

private fun Store.deferredParts(selection: ResolvedSelection, record: Record, batch: Store.Batch): Boolean {
    var whole = true
    val fields = selection.variant(record.type).read
    for (field in fields) {
        val value = record.peek(field.slot)
        val kind = field.kind
        if (kind !is ResolvedField.Kind.Linked) {
            if (field.deferred != null && value == Value.Missing) whole = false
            continue
        }
        val targets: List<Record> = when (value) {
            is Value.Ref -> if (value.record.deleted) emptyList() else listOf(value.record)
            is Value.Refs -> value.records.filterNotNull().filter { !it.deleted }
            Value.Missing -> {
                if (field.deferred != null) whole = false
                emptyList()
            }
            else -> emptyList()
        }
        if (field.deferred == null) {
            for (target in targets) if (!deferredParts(kind.selection, target, batch)) whole = false
            continue
        }
        if (targets.none { target -> check(kind.selection, target) == Answer.MISS }) continue
        // A slot that a field outside the deferred part reads as well keeps its value: it is that field's data.
        if (fields.none { it.deferred == null && it.slot == field.slot }) set(record, field.slot, Value.Missing, batch)
        whole = false
    }
    return whole
}

/**
 * The entity a lookup names, if cached and not deleted: `Type:value` for a
 * typed lookup; for one without a type, the one live entity with the id
 * among the field's possible types, or none when several have it, which is
 * logged. With the image at hand, an entity only the image holds counts.
 */
private fun Store.resolve(lookup: LookupKey, disk: Disk?, batch: Store.Batch): Record? {
    val type = lookup.type
    if (type != null) return resolve(type, lookup.value, disk, batch)
    val possibleTypes = lookup.possibleTypes?.types.orEmpty()
    val live = possibleTypes.mapNotNull { candidate ->
        existing(Record.entityKey(candidate.name, lookup.value))?.takeIf { !it.deleted }
    }
    if (live.size > 1) log?.invoke(LogEvent.AmbiguousIdentity(lookup.value, live.map { it.type.name }))
    if (live.size == 1 || disk == null) return live.singleOrNull()
    if (live.size > 1) return null
    val found = possibleTypes.mapNotNull { candidate -> resolve(candidate, lookup.value, disk, batch) }
    if (found.size > 1) log?.invoke(LogEvent.AmbiguousIdentity(lookup.value, found.map { it.type.name }))
    return found.singleOrNull()
}

/**
 * The entity `Type:id`: live in memory, or, with the image at hand, read
 * from it. A record is registered only once the image had its row, so a
 * miss leaves nothing behind.
 */
private fun Store.resolve(type: TypeID, id: String, disk: Disk?, batch: Store.Batch): Record? {
    val key = Record.entityKey(type.name, id)
    existing(key)?.let { return if (it.deleted) null else it }
    if (disk == null) return null
    val candidate = Record(type, key, Record.idOffset(type.name))
    if (!hydrate(candidate, disk, batch)) return null
    register(candidate)
    return if (candidate.deleted) null else candidate
}
