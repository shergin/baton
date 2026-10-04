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
        let urlRequest = urlRequest(request)
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var response: HTTPURLResponse?
                    var parser: MultipartParser?
                    var body = Data()
                    for try await delivery in Deliveries.of(urlRequest, on: session) {
                        switch delivery {
                        case .response(let received):
                            response = received as? HTTPURLResponse
                            let contentType = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
                            parser = MultipartParser.boundary(in: contentType).map(MultipartParser.init(boundary:))
                        case .chunk(let chunk):
                            guard var reader = parser, let response, (200..<300).contains(response.statusCode) else {
                                body.append(chunk)
                                continue
                            }
                            for part in reader.push(chunk) { continuation.yield(part) }
                            parser = reader
                        }
                    }
                    if let response, !(200..<300).contains(response.statusCode) {
                        throw TransportError(statusCode: response.statusCode, body: String(decoding: body, as: UTF8.self))
                    }
                    if var reader = parser {
                        for part in reader.finish() { continuation.yield(part) }
                    } else {
                        continuation.yield(body)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A data task's response and its body in the chunks the loading system
/// hands over, from a delegate of the task's own: an async sequence of bytes
/// would be iterated a byte at a time.
private final class Deliveries: NSObject, URLSessionDataDelegate, Sendable {
    enum Delivery: Sendable {
        case response(URLResponse)
        case chunk(Data)
    }

    private let continuation: AsyncThrowingStream<Delivery, any Error>.Continuation

    private init(_ continuation: AsyncThrowingStream<Delivery, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// Starts the request; ending the iteration cancels it.
    static func of(_ request: URLRequest, on session: URLSession) -> AsyncThrowingStream<Delivery, any Error> {
        let (deliveries, continuation) = AsyncThrowingStream<Delivery, any Error>.makeStream()
        let task = session.dataTask(with: request)
        task.delegate = Deliveries(continuation)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        return deliveries
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        continuation.yield(.response(response))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.chunk(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Splits a `multipart/mixed` body into the bodies of its parts, however the
/// bytes are chunked. Bytes before the first delimiter are a preamble and
/// are dropped; each part's headers are dropped; the body between the
/// headers' blank line and the next delimiter is a part. What a delimiter
/// closes is let go, so the buffer holds one part at most.
public struct MultipartParser: Sendable {
    private let delimiter: [UInt8]
    private var buffer: [UInt8] = []
    /// Where the line being read starts.
    private var lineStart = 0
    /// How far the buffer has been searched for a line end.
    private var scanned = 0
    /// Whether a delimiter has been read, so the bytes after it are a part.
    private var inPart = false
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
        push(CollectionOfOne(byte))
    }

    /// Feeds a chunk; returns the parts completed within it.
    public mutating func push(_ chunk: some Collection<UInt8>) -> [Data] {
        if finished { return [] }
        buffer.append(contentsOf: chunk)
        var parts: [Data] = []
        while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
            scanned = newline + 1
            var lineEnd = newline
            if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let line = buffer[lineStart..<lineEnd]
            guard line.starts(with: delimiter) else {
                if !inPart {
                    // A preamble line: nothing keeps it.
                    buffer.removeSubrange(0..<scanned)
                    scanned = 0
                }
                lineStart = scanned
                continue
            }
            if inPart, let part = body(buffer[0..<lineStart]) { parts.append(part) }
            inPart = true
            if line.count >= delimiter.count + 2, line[line.startIndex + delimiter.count] == 0x2D, line[line.startIndex + delimiter.count + 1] == 0x2D {
                finished = true
                buffer = []
                return parts
            }
            buffer.removeSubrange(0..<scanned)
            scanned = 0
            lineStart = 0
        }
        scanned = buffer.count
        return parts
    }

    /// The last part, when the stream ended without a closing delimiter.
    public mutating func finish() -> [Data] {
        if finished { return [] }
        finished = true
        guard inPart else { return [] }
        return body(buffer[...]).map { [$0] } ?? []
    }

    /// A part's body: after its headers' blank line, without the trailing line break.
    private func body(_ part: ArraySlice<UInt8>) -> Data? {
        var bytes = part
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes = bytes.dropLast() }
        if bytes.isEmpty { return nil }
        // A part without headers opens with the blank line that ends them.
        if bytes.first == 0x0A { return Data(bytes.dropFirst()) }
        if bytes.first == 0x0D, bytes.dropFirst().first == 0x0A { return Data(bytes.dropFirst(2)) }
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
    /// The subscriptions waiting for `connection_ack`, by id.
    private var waitingForAck: [String: CheckedContinuation<Void, any Error>] = [:]
    /// How many subscriptions have started and are not yet listed in
    /// `subscribers`: opening the connection, waiting for its
    /// acknowledgement, or resumed by it and not yet run.
    private var starting = 0
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
        // Counted until it is listed or gives up, so the connection it opens
        // or waits on is not closed under it.
        starting += 1
        do {
            try await connect(id)
        } catch {
            starting -= 1
            continuation.finish(throwing: error)
            closeIfUnused()
            return
        }
        starting -= 1
        // The stream may have ended while the connection opened, and then
        // nothing may be left on it.
        guard !Task.isCancelled else {
            closeIfUnused()
            return
        }
        subscribers[id] = continuation
        let payload = "{\"query\":" + Variable.quote(request.text)
            + ",\"operationName\":" + Variable.quote(request.operationName)
            + ",\"variables\":" + request.variables.json + "}"
        do {
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
        closeIfUnused()
    }

    /// Closes the connection when no subscription is on it and none is
    /// starting on it; the next subscription opens another.
    private func closeIfUnused() {
        guard subscribers.isEmpty, starting == 0, socket != nil else { return }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        acknowledged = false
        receiving?.cancel()
        receiving = nil
    }

    private func connect(_ id: String) async throws {
        if acknowledged { return }
        if socket == nil {
            var urlRequest = URLRequest(url: url)
            for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            urlRequest.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let socket = session.webSocketTask(with: urlRequest)
            self.socket = socket
            socket.resume()
            receiving = Task { await self.receive(from: socket) }
            let payload = connectionParams.map { ",\"payload\":" + $0.json } ?? ""
            try await send("{\"type\":\"connection_init\"\(payload)}")
            // While the frame was on its way the socket may have failed, and
            // then nothing would answer, or been acknowledged already.
            guard self.socket === socket else { throw TransportError(statusCode: 0, body: "the socket is closed") }
            if acknowledged { return }
        }
        // A stream that ends while it waits stops waiting, for the
        // acknowledgement may never come; one that ended before does not
        // start.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waitingForAck[id] = continuation
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: String) {
        waitingForAck.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func send(_ text: String) async throws {
        guard let socket else { throw TransportError(statusCode: 0, body: "the socket is closed") }
        try await socket.send(.string(text))
    }

    /// Reads one socket's frames. A socket that is no longer the current one
    /// was closed on purpose or replaced, so neither its frames nor its end
    /// concern the subscriptions on the current one.
    private func receive(from socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard self.socket === socket else { return }
                let data: Data = switch message {
                case .data(let data): data
                case .string(let text): Data(text.utf8)
                @unknown default: Data()
                }
                try handle(data)
            } catch {
                guard self.socket === socket else { return }
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
            for waiting in waitingForAck.values { waiting.resume() }
            waitingForAck.removeAll()
        case "ping":
            Task { try? await send("{\"type\":\"pong\"}") }
        case "next":
            if let id = frame.id, let payload = frame.payload { subscribers[id]?.yield(payload) }
        case "error":
            if let id = frame.id {
                // The payload is the operation's GraphQL errors.
                let errors = frame.payload.flatMap { try? Ingest.responseErrors($0) } ?? []
                let messages = errors.isEmpty ? ["subscription error"] : errors.map(\.message)
                subscribers.removeValue(forKey: id)?.finish(throwing: GraphQLErrors(messages: messages))
                closeIfUnused()
            }
        case "complete":
            if let id = frame.id {
                subscribers.removeValue(forKey: id)?.finish()
                closeIfUnused()
            }
        default:
            return
        }
    }

    /// Ends every subscription and the connection; the next subscription reconnects.
    private func fail(_ error: any Error) {
        for waiting in waitingForAck.values { waiting.resume(throwing: error) }
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
    private var sent: [Request] = []

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

    /// The requests the transport was sent, in order. Read under the lock
    /// `execute` appends under, from any thread.
    public var requests: [Request] { lock.withLock { sent } }

    public var requestCount: Int { lock.withLock { sent.count } }

    public func execute(_ request: Request) async throws -> Data {
        try lock.withLock {
            sent.append(request)
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
