@_spi(Generated) import Baton
import BatonSpec

// What a generated read in `RelayReads.swift` lifts into the manifest's
// spelling: a scalar, a link read present or absent, a `@catch` result.

/// A value a lens reads, in the manifest's spelling.
protocol RelayValue {
    var manifestValue: Manifest.Value { get }
}

extension String: RelayValue {
    var manifestValue: Manifest.Value { .string(self) }
}

extension Int: RelayValue {
    var manifestValue: Manifest.Value { .int(self) }
}

extension Double: RelayValue {
    var manifestValue: Manifest.Value { .double(self) }
}

extension Bool: RelayValue {
    var manifestValue: Manifest.Value { .bool(self) }
}

extension Optional: RelayValue where Wrapped: RelayValue {
    var manifestValue: Manifest.Value { map(\.manifestValue) ?? .null }
}

extension Array: RelayValue where Element: RelayValue {
    var manifestValue: Manifest.Value { .list(map(\.manifestValue)) }
}

/// A scalar the lens reads, or null when it reads absent.
func relayValue<T: RelayValue>(_ value: T?) -> Manifest.Value {
    value?.manifestValue ?? .null
}

/// A generated enum or a mapped scalar, as its text.
func relayValue<T: MappedScalar>(_ value: T?) -> Manifest.Value {
    value.map { .string($0.scalarText) } ?? .null
}

/// A link the lens reads: present, as an empty object, or absent, as null.
func relayLink<T>(_ value: T?) -> Manifest.Value {
    value == nil ? .null : .object([:])
}

/// A `@catch` result of a scalar: its value, or the paths of its errors.
func relayResult<T: RelayValue>(_ result: Result<T, FieldErrors>?) -> Manifest.Value {
    switch result {
    case .success(let value)?: .object(["ok": .bool(true), "value": value.manifestValue])
    case .failure(let errors)?: failure(errors)
    case nil: .null
    }
}

/// A `@catch` result of a lens: whether it succeeded, or the paths of its
/// errors; the lens's fields are rows of their own.
func relayResult<T>(_ result: Result<T, FieldErrors>?) -> Manifest.Value {
    switch result {
    case .success?: .object(["ok": .bool(true)])
    case .failure(let errors)?: failure(errors)
    case nil: .null
    }
}

private func failure(_ errors: FieldErrors) -> Manifest.Value {
    .object(["ok": .bool(false), "errors": .list(errors.errors.map(\.path).sorted().map(Manifest.Value.string))])
}

extension RandomAccessCollection where Index == Int {
    /// The element at `index`, or nil past the end.
    func element(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
