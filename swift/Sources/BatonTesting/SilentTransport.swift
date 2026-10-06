import Baton
import Foundation

/// Never answers; for exercising first-body behaviour without a network.
public struct SilentTransport: Transport {
    public init() {}

    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        Self.once {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }
}
