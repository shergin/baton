package baton

/** A spread site that passes `@arguments`, by identity, so one lens binds its fragment's arguments once per site. */
@Generated
class ArgumentSite

/**
 * The scope a lens reads under: the operation's variables, the store it
 * reads, the environment that can fetch for it (none for a lens made by
 * hand), and the root the operation's data hangs off. Relay's fragment
 * owner. A key with variables is rendered once per owner, a condition is
 * settled once, and a spread with `@arguments` binds its child owner once
 * per site, so a read after the first renders and allocates nothing. Used on
 * the store's thread.
 */
class Owner private constructor(
    val variables: Variables,
    internal val store: Store?,
    /** What numbers the keys the scope renders: the store's keys, or a table of the scope's own for a lens made by hand over no store. */
    private val keys: Keys,
    /** The environment that fetches for the scope's lenses; none until the environment exists, and none for a lens made by hand. */
    internal val environment: Environment?,
    /** The root the scope reads under, whose operation a heal refetches; none for a lens made by hand. */
    internal val root: Store.Root?,
    /** Whether reads in the scope report missing and unexpected values and log required fields: not under a placeholder, whose link reported already. */
    internal val reports: Boolean,
) {
    /** A scope over no store, for a lens made by hand. */
    internal constructor(variables: Variables) : this(variables, null, Keys(), null, null, reports = true)

    /** A scope over [store], which numbers the keys it renders. */
    internal constructor(variables: Variables, store: Store) : this(variables, store, store.keys, null, null, reports = true)

    // Caches by identity, scanned linearly as Swift's owner scans them: a
    // lens reads a handful of keys, conditions and sites.
    private val slots = ArrayList<Pair<DynamicKey, Slot>>()
    private val conditions = ArrayList<Pair<Guard, Boolean>>()
    private val bound = ArrayList<Pair<ArgumentSite, Owner>>()
    private var inertOwner: Owner? = null

    /**
     * The slot a rendered key names under this owner's variables. A text the
     * store has not met is numbered and reads as missing; nothing is written
     * to a record but the copy a constant the build named since takes from
     * its rendering, which the commit would make.
     */
    @Generated
    fun slot(key: DynamicKey): Slot {
        for ((cached, slot) in slots) if (cached === key) return slot
        store?.checkThread()
        keys.reconcile()
        val slot = keys.slot(key.type, key.render(variables))
        store?.adoptConstants()
        slots.add(key to slot)
        return slot
    }

    /** Whether a guarded field is selected under this owner's variables: `@include(if:)` when the variable is true, `@skip(if:)` when it is false. */
    @Generated
    fun selects(guard: Guard): Boolean {
        for ((cached, selects) in conditions) if (cached === guard) return selects
        val selects = guard.holds(variables)
        conditions.add(guard to selects)
        return selects
    }

    /** The owner a spread with `@arguments` reads under: these variables with the site's values over them, a null for each argument passed none. */
    @Generated
    fun binding(site: ArgumentSite, values: () -> Map<String, Variable?>): Owner {
        for ((cached, owner) in bound) if (cached === site) return owner
        val merged = HashMap(variables.values)
        for ((name, value) in values()) merged[name] = value ?: Variable.Null
        val owner = Owner(Variables(merged), store, keys, environment, root, reports)
        bound.add(site to owner)
        return owner
    }

    /**
     * The same scope, reporting nothing: a placeholder record reads in it, so
     * nothing under the placeholder reports a second time, and a non-null
     * link below it reads the store's placeholder of its type.
     */
    internal val inert: Owner
        get() {
            inertOwner?.let { return it }
            val owner = if (reports) Owner(variables, store, keys, environment, root, reports = false) else this
            inertOwner = owner
            return owner
        }
}
