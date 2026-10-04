import Foundation
import Network

/// A `graphql-transport-ws` server on the loopback interface, for the tests of
/// the WebSocket transport: it acknowledges the connection, at once or when
/// the test says, records the frames the client sends, and sends the frames a
/// test hands it.
final class SocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "baton.tests.socket-server")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var received: [(type: String, id: String?)] = []
    private var closes = 0
    private let handshake = Handshake()
    /// Whether `connection_init` is acknowledged as it arrives.
    private let acknowledges: Bool

    init(acknowledges: Bool = true) throws {
        self.acknowledges = acknowledges
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(queue) { [handshake] subprotocols, _ in
            handshake.offer(subprotocols)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    /// What the client's opening handshake asked for.
    private final class Handshake: @unchecked Sendable {
        private let lock = NSLock()
        private var subprotocols: [String] = []

        func offer(_ subprotocols: [String]) { lock.withLock { self.subprotocols = subprotocols } }
        var offered: [String] { lock.withLock { subprotocols } }
    }

    /// Starts listening and returns the URL the server answers at.
    func start() async throws -> URL {
        let listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    return
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connection }?.cancel()
    }

    /// The subprotocols the client offered in its handshake.
    var offeredProtocols: [String] { handshake.offered }

    /// The ids of the frames of one type the client has sent, in order.
    func ids(of type: String) -> [String] {
        lock.withLock { received.filter { $0.type == type }.compactMap(\.id) }
    }

    /// How many times the client closed its connection.
    var closed: Int { lock.withLock { closes } }

    /// How many frames of one type the client has sent.
    func count(of type: String) -> Int {
        lock.withLock { received.filter { $0.type == type }.count }
    }

    /// Acknowledges the connection, for a server made not to at once.
    func acknowledge() {
        send(#"{"type":"connection_ack"}"#)
    }

    /// Sends one text frame to the client.
    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        lock.withLock { connection }?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { self.connection = connection }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                lock.withLock { closes += 1 }
                return
            }
            guard let data else { return }
            // Parsed with `JSONSerialization` rather than the transport's own
            // frame reader, so a fault in that reader shows instead of being
            // read the same way on both ends.
            if let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = frame["type"] as? String {
                lock.withLock { received.append((type, frame["id"] as? String)) }
                if type == "connection_init", acknowledges { acknowledge() }
            }
            receive(on: connection)
        }
    }
}
