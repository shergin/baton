import Baton
import Foundation

/// Never answers; for exercising first-body behaviour without a network.
public struct SilentTransport: Transport {
    public init() {}
    public func execute(_ request: Request) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
