package baton

// The availability check: whether the store holds an operation's data, and
// the lookups it binds on the way. See `spec/runtime.md`, section 5. The
// image's half, the same walk with the image at hand, comes with the image.

/** Where the availability check found the selection's data. */
internal enum class Answer {
    /** In memory, every record of it put there by a response. */
    MEMORY,

    /** With the image's help; answered once the image exists. */
    IMAGE,

    /** Not all of it. */
    MISS,
}

/**
 * Whether every field of the selection is present, starting at [record]. A
 * missing link with a lookup is satisfied by the cached entity, and the link
 * is written so later reads are direct; what the walk writes is one local
 * batch, notified as it writes, since nothing observes a walk in progress.
 */
internal fun Store.check(selection: ResolvedSelection, record: Record = root): Answer {
    checkThread()
    if (ended) return Answer.MISS
    adoptConstants()
    var found = false
    local { batch -> found = available(selection.variant(record.type), record, batch) }
    return if (found) Answer.MEMORY else Answer.MISS
}

/**
 * The walk over one record's fields the check waits for, then the
 * connections' client links: a missing scalar is a miss; a missing link with
 * a lookup is satisfied by the entity the lookup names; a missing link
 * without one is a miss; a null link is fine; a link is followed, a deleted
 * target not entered; every element of a list is followed.
 */
private fun Store.available(variant: ResolvedVariant, record: Record, batch: Store.Batch): Boolean {
    for (field in variant.waits) {
        val slot = field.slot
        val kind = field.kind
        if (kind !is ResolvedField.Kind.Linked) {
            if (record.peek(slot) == Value.Missing) return false
            continue
        }
        when (val value = record.peek(slot)) {
            Value.Missing -> {
                val lookup = kind.lookup
                if (kind.plural || lookup == null) return false
                val target = resolve(lookup) ?: return false
                if (!available(kind.selection.variant(target.type), target, batch)) return false
                set(record, slot, Value.Ref(target), batch)
            }
            Value.Null -> Unit
            is Value.Ref -> {
                val target = value.record
                if (!target.deleted && !available(kind.selection.variant(target.type), target, batch)) return false
            }
            is Value.Refs -> {
                for (target in value.records) {
                    if (target == null || target.deleted) continue
                    if (!available(kind.selection.variant(target.type), target, batch)) return false
                }
            }
            else -> return false
        }
    }
    // Lenses read a connection through its client record, which the walk
    // above does not pass. A merge always fills it, so one that holds
    // nothing, swept or never filled, is not in memory.
    for (link in variant.clientLinks) {
        val found = (record.peek(link.slot) as? Value.Ref)?.record ?: continue
        if (found.swept || found.isEmpty) return false
    }
    return true
}

/**
 * Whether every deferred part of a selection the check found is whole. The
 * check passes over deferred fields; a deferred link whose records lack the
 * part is cleared, unless a field outside the part reads the same slot, so
 * its fragment reads absent rather than empty. Either way the answer is
 * false, so the operation fetches.
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
        if (targets.none { target -> !available(kind.selection.variant(target.type), target, batch) }) continue
        // A slot that a field outside the deferred part reads as well keeps its value: it is that field's data.
        if (fields.none { it.deferred == null && it.slot == field.slot }) set(record, field.slot, Value.Missing, batch)
        whole = false
    }
    return whole
}

/**
 * The entity a lookup names, if the store holds it live: `Type:value` for a
 * typed lookup; for one without a type, the one live entity with the id among
 * the field's possible types, or none when several have it, which is logged.
 */
private fun Store.resolve(lookup: LookupKey): Record? {
    val type = lookup.type
    if (type != null) {
        val record = existing(Record.entityKey(type.name, lookup.value)) ?: return null
        return if (record.deleted) null else record
    }
    val found = lookup.possibleTypes?.types.orEmpty().mapNotNull { candidate ->
        existing(Record.entityKey(candidate.name, lookup.value))?.takeIf { !it.deleted }
    }
    if (found.size > 1) log?.invoke(LogEvent.AmbiguousIdentity(lookup.value, found.map { it.type.name }))
    return found.singleOrNull()
}
