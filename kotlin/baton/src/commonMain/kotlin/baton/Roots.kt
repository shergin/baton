package baton

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

// What keeps records alive is the store's, since it is a fact about data. A
// root is an operation's selection and the record it starts from. It lives
// while a holder keeps it, then waits in the release buffer, oldest out
// first; a completed mutation's payload waits apart from the buffer. The
// collector marks from the roots and from nothing else, and runs when a root
// left or a commit dropped a link. See `spec/runtime.md`, section 7.

/** The root of an operation, made on first sight: the caller retains it, or parks it in the release buffer. */
internal fun Store.root(key: String, resolved: ResolvedSelection, record: Record): Store.Root {
    checkThread()
    adoptConstants()
    roots[key]?.let { return it }
    val root = Store.Root(key, resolved, record)
    // An ended store keeps no root: a handle made after the end reads gone.
    if (!ended) roots[key] = root
    return root
}

/** Keeps the root's records alive by one holder more, whose policy allows the network or not. A root retained after it left is a root again. */
internal fun Store.retain(root: Store.Root, allowingNetwork: Boolean) {
    root.holders += 1
    if (allowingNetwork) root.networkHolders += 1
    releaseBuffer.remove(root.key)
    if (!ended && roots[root.key] == null) roots[root.key] = root
}

/**
 * One holder fewer. At none the root waits in the release buffer, oldest out
 * first, or leaves at once when nothing of it is to be buffered. The keys of
 * the roots pushed out are returned, so that the environment drops what it
 * holds for them.
 */
internal fun Store.release(root: Store.Root, allowingNetwork: Boolean, buffering: Boolean = true): List<String> {
    root.holders -= 1
    if (allowingNetwork) root.networkHolders -= 1
    if (root.holders > 0) return emptyList()
    root.holders = 0
    root.networkHolders = 0
    if (ended) return emptyList()
    if (!buffering) {
        drop(root)
        return emptyList()
    }
    return park(root.key)
}

/**
 * Parks a root in the release buffer, as a preload does by hand, and returns
 * the keys of the roots pushed out. A root pushed out leaves, and the pass
 * that follows may free what it kept; a root that only moved into the buffer
 * removes nothing, and no pass runs for it.
 */
internal fun Store.park(key: String): List<String> {
    releaseBuffer.remove(key)
    releaseBuffer.add(key)
    val evicted = ArrayList<String>()
    while (releaseBuffer.size > releaseBufferSize) {
        val gone = releaseBuffer.removeAt(0)
        roots.remove(gone)
        evicted.add(gone)
    }
    if (evicted.isNotEmpty()) scheduleCollection()
    return evicted
}

/** A root that leaves at once: a subscription released closes its stream, and its events wait for nobody. */
internal fun Store.drop(root: Store.Root) {
    roots.remove(root.key)
    releaseBuffer.remove(root.key)
    scheduleCollection()
}

/**
 * Keeps a completed mutation's payload alive as a root, apart from the
 * release buffer, so mutations push no released query out of it. A
 * completion of an equal operation value takes its place; one with other
 * variables keeps its own, since its selection may reach other records.
 */
internal fun Store.keepCompleted(root: Store.Root) {
    if (ended) return
    completedMutations.remove(root.key)
    completedMutations.add(root.key)
    roots[root.key] = root
    if (completedMutations.size <= releaseBufferSize) return
    while (completedMutations.size > releaseBufferSize) roots.remove(completedMutations.removeAt(0))
    scheduleCollection()
}

/**
 * Dates a root: the store just committed its operation's response, in this
 * launch, which the image is told, and which makes the data present when the
 * response was complete, whoever asked for it. A query just written that
 * nothing retains waits in the release buffer, as Relay's does; the keys of
 * the roots pushed out are returned.
 */
internal fun Store.date(root: Store.Root, present: Boolean = true): List<String> {
    root.stamp(now, invalidationEpoch)
    root.fetches += 1
    if (present) root.committed()
    // An operation selecting a transient root field leaves no stamp: the
    // stamp carries the operation's variables, which would name what the
    // field was asked with.
    if (!root.resolved.transient) persistence?.fetched(root.key, wallNow)
    if (root.record !== this.root || root.holders > 0 || root.key in releaseBuffer) return emptyList()
    return park(root.key)
}

/**
 * Whether the root's data is stale: fetched before the store's last
 * invalidation, or older than [expiration], the operation's own or the
 * store's default. No expiration means never; data with no known age is
 * stale wherever an expiration applies.
 */
internal fun Store.isStale(root: Store.Root, expiration: Duration?): Boolean {
    if (root.fetchEpoch < invalidationEpoch) return true
    val limit = expiration ?: cacheExpiration ?: return false
    val fetchTime = root.fetchTime ?: return true
    return fetchTime + limit < now
}

/**
 * Gives a root whose operation this launch has not fetched the age the image
 * knows: the time since an earlier launch fetched it. Data that had to be
 * read from the image and has no such time is stale.
 */
internal fun Store.takeAge(root: Store.Root, hydrated: Boolean) {
    if (root.fetchTime != null) return
    val persistence = persistence ?: return
    val age = persistence.age(root.key, wallNow)
    if (age != null) {
        root.stamp(now - age.seconds, invalidationEpoch)
    } else if (hydrated) {
        root.stamp(null, invalidationEpoch - 1)
    }
}

/**
 * A read under the root found data missing: the root is marked stale, and
 * the heal may refetch it, once per fetch of the root. Returns false when the
 * data is the heal's own refetch's, under which a field still missing is
 * unexpected and healed no further.
 */
internal fun Store.heal(root: Store.Root): Boolean {
    if (root.healedAt == root.fetches) return false
    root.healedAt = root.fetches + 1
    root.stamp(root.fetchTime, invalidationEpoch - 1)
    return true
}

/**
 * Settles the verdict of every retained root that holds data, after a batch
 * changed a null, a link, an error or a deletion: what `@throwOnFieldError`
 * and a bubbling `@required` read.
 */
internal fun Store.settleVerdicts() {
    for (root in roots.values.toList()) {
        if (root.holders > 0 && root.present) root.settle()
    }
}

/**
 * Removes every record no retention reaches: the roots, through the links
 * the plan follows, the connections' client links among them; the records an
 * optimistic layer wrote; and the records whose rows wait to be written, so
 * the image, which a read does not write first, is never older than memory.
 * Then frees every rendered key's number that nothing holds. Returns how
 * many records were removed.
 */
internal fun Store.collect(): Int {
    checkThread()
    if (ended) return 0
    val reachable = HashSet<Record>()
    for (root in roots.values) mark(root.resolved, root.record, reachable)
    persistence?.let { reachable.addAll(it.unwrittenRecords()) }
    // The records an optimistic layer wrote stay while it is applied: its revert writes back into them.
    for (layer in optimisticLayers) {
        for (key in layer.changes.recordKeys) existing(key)?.let { reachable.add(it) }
    }
    collections += 1
    val swept = sweep(reachable)
    freeKeys()
    return swept
}

/** Collects every record the selection reaches from [record]. */
private fun mark(selection: ResolvedSelection, record: Record, reachable: MutableSet<Record>) {
    reachable.add(record)
    for (field in selection.variant(record.type).follows) {
        val kind = field.kind as? ResolvedField.Kind.Linked ?: continue
        when (val value = record.peek(field.slot)) {
            is Value.Ref -> mark(kind.selection, value.record, reachable)
            is Value.Refs -> for (target in value.records) if (target != null) mark(kind.selection, target, reachable)
            else -> Unit
        }
    }
}

/**
 * The numbers a live resolution, a scope, a fetch in flight, a layer, a twin,
 * a row waiting for the image or a row read from it holds, then frees the
 * rest, drops the records' entries under them and has the image forget their
 * names.
 */
private fun Store.freeKeys() {
    val kept = HashSet<Slot>()
    for (root in roots.values) root.renderedSlots(kept)
    for (scope in looseScopes) scope.renderedSlots(kept)
    for (resolution in inFlight) resolution.renderedSlots(kept)
    for (layer in optimisticLayers) layer.renderedSlots(kept)
    twinSlots(kept)
    kept.addAll(imageSlots)
    persistence?.unwrittenSlots(kept)
    val freed = keys.free(kept)
    if (freed.isEmpty()) return
    val set = freed.toSet()
    for (record in recordsByKey().values) record.drop(set)
    for (slot in freed) if (slot.type == root.type) hydratedRootSlots.remove(slot.index)
    persistence?.freed(freed)
}
