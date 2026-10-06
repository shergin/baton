import Foundation

/// A Swift type a custom scalar reads as, under `customScalarTypes` in
/// `baton.json`. The store keeps the scalar's text exactly as the server
/// wrote it; the accessor converts at the read and says the conversion can
/// fail, so a value the type cannot hold reads as nil, or as the failure a
/// directive asks for, never as a zero. A variable of the type is sent as
/// its text.
public protocol MappedScalar: Sendable {
    /// The value the text names, or nil when the text does not convert.
    init?(scalarText: String)
    /// The text a server receives for the value.
    var scalarText: String { get }
}

/// A decimal written as the server wrote it, read in the POSIX locale, so
/// an amount never passes through a `Double` or a user's separators.
extension Decimal: MappedScalar {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public init?(scalarText: String) {
        guard let value = Decimal(string: scalarText, locale: Decimal.posix), value.isFinite else { return nil }
        self = value
    }

    public var scalarText: String {
        var value = self
        return NSDecimalString(&value, Decimal.posix)
    }
}

/// A date in ISO 8601's internet profile, `2026-10-11T09:30:00Z`, with
/// fractional seconds or without; written with them.
extension Date: MappedScalar {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    public init?(scalarText: String) {
        guard let date = (try? Date.fractional.parse(scalarText)) ?? (try? Date.whole.parse(scalarText)) else { return nil }
        self = date
    }

    public var scalarText: String { Date.fractional.format(self) }
}

extension URL: MappedScalar {
    public init?(scalarText: String) {
        guard !scalarText.isEmpty, let url = URL(string: scalarText) else { return nil }
        self = url
    }

    public var scalarText: String { absoluteString }
}

extension UUID: MappedScalar {
    public init?(scalarText: String) {
        guard let uuid = UUID(uuidString: scalarText) else { return nil }
        self = uuid
    }

    public var scalarText: String { uuidString }
}
