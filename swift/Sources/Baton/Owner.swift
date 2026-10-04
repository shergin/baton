/// The scope lenses read in: one operation's variables, or a fragment's
/// arguments bound over them. Relay's fragment owner. A key with variables
/// is resolved once per owner, and each spread with arguments binds its
/// scope once, so a read after the first renders, hashes and allocates
/// nothing. A handle keeps one owner for its lifetime.
@MainActor
public final class Owner {
    nonisolated public let variables: Variables
    nonisolated let store: Store?
    /// Whether reads in the scope report missing and unexpected values and
    /// log required fields; not under a placeholder, whose link reported
    /// already.
    nonisolated let reports: Bool
    /// The slot of each key with variables, resolved on first use.
    private var slots: [(key: DynamicKey, slot: Slot)] = []
    /// The abstract slot of each key with variables read on an interface or
    /// union, rendered on first use.
    private var abstractSlots: [(key: DynamicKey, slot: AbstractSlot)] = []
    /// The scope of each spread with arguments, bound on first use.
    private var bound: [(site: ArgumentSite, owner: Owner)] = []
    private var inertOwner: Owner?

    nonisolated public convenience init(variables: Variables, store: Store? = nil) {
        self.init(variables: variables, store: store, reports: true)
    }

    nonisolated private init(variables: Variables, store: Store?, reports: Bool) {
        self.variables = variables
        self.store = store
        self.reports = reports
    }

    /// The key's slot under these variables.
    @inline(__always)
    public func slot(_ key: DynamicKey) -> Slot {
        for entry in slots where entry.key === key { return entry.slot }
        let slot = Registry.slot(key.type, key.render(variables))
        slots.append((key, slot))
        return slot
    }

    /// The key's slot under these variables on `type`, for a key read on an
    /// interface or union.
    public func slot(_ key: DynamicKey, on type: TypeID) -> Slot {
        for entry in abstractSlots where entry.key === key { return entry.slot.on(type) }
        let slot = AbstractSlot(key.render(variables))
        abstractSlots.append((key, slot))
        return slot.on(type)
    }

    /// The scope a spread with arguments binds here: these variables with
    /// `values` over them, a null for each argument passed none.
    public func binding(_ site: ArgumentSite, _ values: () -> [String: Variable?]) -> Owner {
        for entry in bound where entry.site === site { return entry.owner }
        var merged = variables.values
        for (name, value) in values() { merged[name] = value ?? .null }
        let owner = Owner(variables: Variables(merged), store: store, reports: reports)
        bound.append((site, owner))
        return owner
    }

    /// The same scope, reporting nothing: a placeholder record reads in it,
    /// so nothing under the placeholder reports a second time, and a
    /// non-null link below it reads the store's placeholder of its type.
    var inert: Owner {
        if let inertOwner { return inertOwner }
        let owner = reports ? Owner(variables: variables, store: store, reports: false) : self
        inertOwner = owner
        return owner
    }
}

/// A storage key with variables, such as `characters(page:$page)`: its type
/// and the parts it is built from. An owner renders it once.
public final class DynamicKey: Sendable {
    public let type: TypeID
    public let parts: [KeyPart]

    public init(_ type: TypeID, _ parts: [KeyPart]) {
        self.type = type
        self.parts = parts
    }

    /// The storage key under `variables`.
    public func render(_ variables: Variables) -> String {
        var text = ""
        for part in parts {
            switch part {
            case .literal(let literal): text += literal
            case .variable(let name): text += variables.render(name)
            }
        }
        return text
    }
}

/// A fragment spread with `@arguments`: the place an owner binds the
/// fragment's scope, so the binding is made once per owner.
public final class ArgumentSite: Sendable {
    public init() {}
}
