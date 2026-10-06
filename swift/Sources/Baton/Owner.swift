/// The scope lenses read in: one operation's variables, or a fragment's
/// arguments bound over them. Relay's fragment owner. A key with variables
/// is resolved once per owner, and each spread with arguments binds its
/// scope once, so a read after the first renders, hashes and allocates
/// nothing. A handle keeps one owner for its lifetime.
@_spi(Generated)
@MainActor
public final class Owner {
    nonisolated public let variables: Variables
    nonisolated let store: Store?
    /// What numbers the keys the scope renders: the store's keys, or a
    /// table of the scope's own for a lens made by hand over no store.
    nonisolated let keys: Keys
    /// The scope's hold on the numbers it took, kept while the scope lives.
    nonisolated let hold: Keys.Hold
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
    /// Whether each condition read in the scope selects, settled on first
    /// use.
    private var conditions: [(condition: Guard, selects: Bool)] = []
    private var inertOwner: Owner?

    /// The environment that fetches for the scope's lenses: their refetches
    /// and pages. None for a lens made by hand, which cannot fetch.
    private(set) weak var environment: Environment?
    /// The root the scope reads under, whose operation a heal refetches.
    /// None for a lens made by hand.
    let root: Store.Root?

    nonisolated public convenience init(variables: Variables, store: Store? = nil) {
        self.init(variables: variables, store: store, keys: store?.keys ?? Keys(), environment: nil, root: nil, reports: true)
    }

    /// The scope of a handle's lenses, which fetch through its environment
    /// and are healed through its root.
    convenience init(variables: Variables, store: Store, environment: Environment, root: Store.Root? = nil) {
        self.init(variables: variables, store: store, keys: store.keys, environment: environment, root: root, reports: true)
    }

    nonisolated private init(variables: Variables, store: Store?, keys: Keys, environment: Environment?, root: Store.Root?, reports: Bool) {
        self.variables = variables
        self.store = store
        self.keys = keys
        hold = keys.hold()
        self.environment = environment
        self.root = root
        self.reports = reports
    }

    /// The key's slot under these variables.
    @inline(__always)
    public func slot(_ key: DynamicKey) -> Slot {
        for entry in slots where entry.key === key { return entry.slot }
        let slot = resolve(key.type, key.render(variables))
        slots.append((key, slot))
        return slot
    }

    /// Whether the condition selects under these variables: `@include(if:)`
    /// when the variable is true, `@skip(if:)` when it is false. Settled
    /// once per owner, as a key with variables is, so a read looks nothing
    /// up by name.
    @inline(__always)
    public func selects(_ condition: Guard) -> Bool {
        for entry in conditions where entry.condition === condition { return entry.selects }
        let selects = condition.holds(variables)
        conditions.append((condition, selects))
        return selects
    }

    /// The key's slot under these variables on `type`, for a key read on an
    /// interface or union.
    public func slot(_ key: DynamicKey, on type: TypeID) -> Slot {
        for entry in abstractSlots where entry.key === key { return entry.slot.on(type) }
        meetConstants()
        let slot = AbstractSlot(key.render(variables), hold: hold)
        abstractSlots.append((key, slot))
        return slot.on(type)
    }

    /// Numbers a rendered key, once per owner, after the store has adopted
    /// the constants the build named since: a key met first as a rendering
    /// and then as a constant reads what either wrote.
    private func resolve(_ type: TypeID, _ text: String) -> Slot {
        meetConstants()
        return keys.slot(type, text, for: hold)
    }

    private func meetConstants() {
        keys.reconcile()
        store?.adoptConstants()
    }

    /// The scope a spread with arguments binds here: these variables with
    /// `values` over them, a null for each argument passed none.
    public func binding(_ site: ArgumentSite, _ values: () -> [String: Variable?]) -> Owner {
        for entry in bound where entry.site === site { return entry.owner }
        var merged = variables.values
        for (name, value) in values() { merged[name] = value ?? .null }
        let owner = Owner(variables: Variables(merged), store: store, keys: keys, environment: environment, root: root, reports: reports)
        bound.append((site, owner))
        return owner
    }

    /// The same scope, reporting nothing: a placeholder record reads in it,
    /// so nothing under the placeholder reports a second time, and a
    /// non-null link below it reads the store's placeholder of its type.
    var inert: Owner {
        if let inertOwner { return inertOwner }
        let owner = reports ? Owner(variables: variables, store: store, keys: keys, environment: environment, root: root, reports: false) : self
        inertOwner = owner
        return owner
    }
}

/// A storage key with variables, such as `characters(page:$page)`: its type,
/// the field's name and the arguments it is built from. An owner renders it
/// once.
@_spi(Generated)
public final class DynamicKey: Sendable {
    public let type: TypeID
    public let name: String
    public let arguments: [KeyArgument]

    public init(_ type: TypeID, _ name: String, _ arguments: [KeyArgument]) {
        self.type = type
        self.name = name
        self.arguments = arguments
    }

    /// The storage key under `variables`: the name, then the arguments as
    /// `name:value` in order, in parentheses when any is left. An argument
    /// whose value is a variable that is null is left out, as Relay's
    /// storage key leaves a null argument out.
    public func render(_ variables: Variables) -> String {
        var text = name
        var open = false
        for argument in arguments {
            guard let value = argument.render(variables) else { continue }
            text += open ? "," : "("
            open = true
            text += argument.name
            text += ":"
            text += value
        }
        if open { text += ")" }
        return text
    }
}

/// An argument of a storage key: its name and the parts of its value, text
/// and variables rendered as JSON.
@_spi(Generated)
public struct KeyArgument: Sendable {
    public let name: String
    public let parts: [KeyPart]

    public init(_ name: String, _ parts: [KeyPart]) {
        self.name = name
        self.parts = parts
    }

    /// The value's text under `variables`, or nil for a value that is one
    /// variable given null or nothing.
    func render(_ variables: Variables) -> String? {
        if parts.count == 1, case .variable(let name) = parts[0] {
            guard let value = variables.values[name], value != .null else { return nil }
            return value.json
        }
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
@_spi(Generated)
public final class ArgumentSite: Sendable {
    public init() {}
}
