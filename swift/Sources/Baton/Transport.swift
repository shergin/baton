import Foundation

/// One operation execution over the wire.
public struct Request: Sendable {
    public let operationName: String
    public let text: String
    public let persistedID: String
    public let variables: Variables
    /// The `onError` request parameter, when the environment sets one.
    public let errorBehavior: ErrorBehavior?
    /// Whether the operation may answer in parts (`@defer`), so the transport
    /// asks for and reads an incremental response.
    public let incremental: Bool

    public init(operationName: String, text: String, persistedID: String, variables: Variables, errorBehavior: ErrorBehavior? = nil, incremental: Bool = false) {
        self.operationName = operationName
        self.text = text
        self.persistedID = persistedID
        self.variables = variables
        self.errorBehavior = errorBehavior
        self.incremental = incremental
    }

    /// The GraphQL-over-HTTP JSON body.
    public var body: Data {
        var json = "{\"operationName\":" + Variable.quote(operationName)
        json += ",\"query\":" + Variable.quote(text)
        json += ",\"variables\":" + variables.json
        if let errorBehavior { json += ",\"onError\":" + Variable.quote(errorBehavior.rawValue) }
        json += "}"
        return Data(json.utf8)
    }
}

public protocol Transport: Sendable {
    func execute(_ request: Request) async throws -> Data
    /// The parts of an incremental response, the first being the one with
    /// `data`. A transport without incremental delivery answers once.
    func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error>
}

extension Transport {
    public func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await execute(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The events of a subscription, each a GraphQL response payload.
public protocol SubscriptionTransport: Sendable {
    func subscribe(_ request: Request) -> AsyncThrowingStream<Data, any Error>
}

public struct TransportError: Error, CustomStringConvertible, Sendable {
    public let statusCode: Int
    public let body: String

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    public var description: String { "HTTP \(statusCode): \(body.prefix(200))" }
}

/// POSTs operations as JSON to one endpoint. An operation with `@defer` asks
/// for `multipart/mixed` and reads the parts as they arrive.
public struct URLSessionTransport: Transport {
    public let url: URL
    public var headers: [String: String]
    let session: URLSession

    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    private func urlRequest(_ request: Request) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let accept = request.incremental
            ? "multipart/mixed; deferSpec=20220824, application/graphql-response+json, application/json"
            : "application/graphql-response+json, application/json"
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    public func execute(_ request: Request) async throws -> Data {
        let (data, response) = try await session.data(for: urlRequest(request))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransportError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest(request))
                    let http = response as? HTTPURLResponse
                    if let http, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw TransportError(statusCode: http.statusCode, body: String(decoding: body, as: UTF8.self))
                    }
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    guard let boundary = MultipartParser.boundary(in: contentType) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        continuation.yield(body)
                        continuation.finish()
                        return
                    }
                    var parser = MultipartParser(boundary: boundary)
                    for try await byte in bytes {
                        for part in parser.push(byte) { continuation.yield(part) }
                        if parser.finished { break }
                    }
                    for part in parser.finish() { continuation.yield(part) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Splits a `multipart/mixed` body into the bodies of its parts, byte by
/// byte, however the bytes are chunked. Each part's headers are dropped; the
/// body between the header's blank line and the next delimiter is a part.
public struct MultipartParser: Sendable {
    private let delimiter: [UInt8]
    private var buffer: [UInt8] = []
    private var lineStart = 0
    private var partStart = 0
    public private(set) var finished = false

    public init(boundary: String) {
        delimiter = Array(("--" + boundary).utf8)
    }

    /// The `boundary` parameter of a `multipart/mixed` content type, if it is one.
    public static func boundary(in contentType: String) -> String? {
        guard contentType.lowercased().hasPrefix("multipart/") else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            return String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "-"
    }

    /// Feeds one byte; returns the parts completed by it.
    public mutating func push(_ byte: UInt8) -> [Data] {
        if finished { return [] }
        buffer.append(byte)
        guard byte == 0x0A else { return [] }
        var lineEnd = buffer.count - 1
        if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
        let line = buffer[lineStart..<lineEnd]
        var parts: [Data] = []
        if line.starts(with: delimiter) {
            if let part = body(buffer[partStart..<lineStart]) { parts.append(part) }
            if line.count >= delimiter.count + 2, line[line.startIndex + delimiter.count] == 0x2D, line[line.startIndex + delimiter.count + 1] == 0x2D {
                finished = true
            }
            partStart = buffer.count
        }
        lineStart = buffer.count
        return parts
    }

    /// Feeds a chunk; returns the parts completed within it.
    public mutating func push(_ chunk: Data) -> [Data] {
        var parts: [Data] = []
        for byte in chunk { parts.append(contentsOf: push(byte)) }
        return parts
    }

    /// The last part, when the stream ended without a closing delimiter.
    public mutating func finish() -> [Data] {
        if finished { return [] }
        finished = true
        return body(buffer[partStart...]).map { [$0] } ?? []
    }

    /// A part's body: after its headers' blank line, without the trailing line break.
    private func body(_ part: ArraySlice<UInt8>) -> Data? {
        var bytes = part
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes = bytes.dropLast() }
        if bytes.isEmpty { return nil }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                var next = index + 1
                if next < bytes.endIndex, bytes[next] == 0x0D { next += 1 }
                if next < bytes.endIndex, bytes[next] == 0x0A {
                    let body = bytes[(next + 1)...]
                    return body.isEmpty ? nil : Data(body)
                }
            }
            index += 1
        }
        // No headers: the whole part is the body.
        return Data(bytes)
    }
}

/// Subscriptions over `graphql-transport-ws`: one WebSocket per transport,
/// opened on the first subscription, with `connection_init` and
/// `connection_ack`, then `subscribe`, `next`, `error` and `complete` by id.
public actor GraphQLTransportWebSocket: SubscriptionTransport {
    public let url: URL
    public let headers: [String: String]
    /// The `payload` of `connection_init`, for authentication.
    public let connectionParams: Variable?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var acknowledged = false
    private var waitingForAck: [CheckedContinuation<Void, any Error>] = []
    private var receiving: Task<Void, Never>?
    private var subscribers: [String: AsyncThrowingStream<Data, any Error>.Continuation] = [:]

    public init(url: URL, headers: [String: String] = [:], connectionParams: Variable? = nil, session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.connectionParams = connectionParams
        self.session = session
    }

    public nonisolated func subscribe(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        // Every stream is a subscription of its own, under its own id: equal
        // requests must not stand in for one another when one of them ends.
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            let task = Task { await self.start(id, request, continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.stop(id) }
            }
        }
    }

    private func start(_ id: String, _ request: Request, _ continuation: AsyncThrowingStream<Data, any Error>.Continuation) async {
        do {
            try await connect()
            // The stream may have ended while the connection opened.
            guard !Task.isCancelled else { return }
            subscribers[id] = continuation
            let payload = "{\"query\":" + Variable.quote(request.text)
                + ",\"operationName\":" + Variable.quote(request.operationName)
                + ",\"variables\":" + request.variables.json + "}"
            try await send("{\"id\":\"\(id)\",\"type\":\"subscribe\",\"payload\":\(payload)}")
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Completes a subscription whose stream the client stopped reading. One
    /// the server ended, or that never started, is not listed and owes the
    /// server nothing.
    private func stop(_ id: String) async {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        try? await send("{\"id\":\"\(id)\",\"type\":\"complete\"}")
    }

    private func connect() async throws {
        if acknowledged { return }
        if socket == nil {
            var urlRequest = URLRequest(url: url)
            for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            urlRequest.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let socket = session.webSocketTask(with: urlRequest)
            self.socket = socket
            socket.resume()
            receiving = Task { await self.receive() }
            let payload = connectionParams.map { ",\"payload\":" + $0.json } ?? ""
            try await send("{\"type\":\"connection_init\"\(payload)}")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waitingForAck.append(continuation)
        }
    }

    private func send(_ text: String) async throws {
        guard let socket else { throw TransportError(statusCode: 0, body: "the socket is closed") }
        try await socket.send(.string(text))
    }

    private func receive() async {
        while let socket, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data = switch message {
                case .data(let data): data
                case .string(let text): Data(text.utf8)
                @unknown default: Data()
                }
                try handle(data)
            } catch {
                fail(error)
                return
            }
        }
    }

    private func handle(_ data: Data) throws {
        let frame = try Ingest.frame(data)
        switch frame.type {
        case "connection_ack":
            acknowledged = true
            for waiting in waitingForAck { waiting.resume() }
            waitingForAck.removeAll()
        case "ping":
            Task { try? await send("{\"type\":\"pong\"}") }
        case "next":
            if let id = frame.id, let payload = frame.payload { subscribers[id]?.yield(payload) }
        case "error":
            if let id = frame.id {
                let message = frame.payload.map { String(decoding: $0, as: UTF8.self) } ?? "subscription error"
                subscribers.removeValue(forKey: id)?.finish(throwing: GraphQLErrors(messages: [message]))
            }
        case "complete":
            if let id = frame.id {
                subscribers.removeValue(forKey: id)?.finish()
            }
        default:
            return
        }
    }

    /// Ends every subscription and the connection; the next subscription reconnects.
    private func fail(_ error: any Error) {
        for waiting in waitingForAck { waiting.resume(throwing: error) }
        waitingForAck.removeAll()
        for subscriber in subscribers.values { subscriber.finish(throwing: error) }
        subscribers.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        acknowledged = false
        receiving = nil
    }
}

/// Serves recorded responses by operation name, or through a responder that
/// sees the whole request; for tests, previews and benchmarks.
public final class RecordedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Data]
    private let responder: (@Sendable (Request) -> Data?)?
    public private(set) var requests: [Request] = []

    public init(_ responses: [String: Data] = [:]) {
        self.responses = responses
        responder = nil
    }

    public init(responder: @escaping @Sendable (Request) -> Data?) {
        responses = [:]
        self.responder = responder
    }

    public func record(_ operationName: String, _ data: Data) {
        lock.withLock { responses[operationName] = data }
    }

    public var requestCount: Int { lock.withLock { requests.count } }

    public func execute(_ request: Request) async throws -> Data {
        try lock.withLock {
            requests.append(request)
            if let responder, let data = responder(request) { return data }
            guard let data = responses[request.operationName] else {
                throw TransportError(statusCode: 0, body: "no recorded response for \(request.operationName)")
            }
            return data
        }
    }
}

/// Never answers; for exercising first-body behaviour without a network.
public struct SilentTransport: Transport {
    public init() {}
    public func execute(_ request: Request) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
