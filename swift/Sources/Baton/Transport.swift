import Foundation

/// What a request carries of its operation: the text the compiler printed,
/// or the id a server registered it under. Never both: the build decides,
/// under `persistConfig`, and the binary holds no text to fall back to.
public enum Document: Hashable, Sendable {
    case text(String)
    case id(String)
}

/// One operation execution over the wire.
public struct Request: Sendable {
    /// The kind of operation, so a wrapper never retries a mutation the
    /// server may have received.
    public enum Kind: Sendable {
        case query, mutation, subscription
    }

    public let operationName: String
    public let kind: Kind
    public let document: Document
    public let variables: Variables
    /// The `onError` request parameter, when the environment sets one.
    public let errorBehavior: ErrorBehavior?
    /// Whether the operation may answer in parts (`@defer`), so the transport
    /// asks for and reads an incremental response.
    public let incremental: Bool

    public init(operationName: String, kind: Kind, document: Document, variables: Variables, errorBehavior: ErrorBehavior? = nil, incremental: Bool = false) {
        self.operationName = operationName
        self.kind = kind
        self.document = document
        self.variables = variables
        self.errorBehavior = errorBehavior
        self.incremental = incremental
    }

    /// The JSON a server receives for the request, by the standard encoding.
    public var body: Data { Encoding.standard.body(self) }
}

/// The one function from a request to the JSON a server receives, for the
/// HTTP body and the socket's subscribe payload alike. The standard one
/// writes `operationName`, `variables`, `onError` when set, and `query` for
/// a text or `documentId` for an id, after the GraphQL-over-HTTP working
/// group's proposal. A server with another convention replaces the function
/// and keeps the built-in transports.
public struct Encoding: Sendable {
    public let body: @Sendable (Request) -> Data

    public init(body: @escaping @Sendable (Request) -> Data) { self.body = body }

    public static let standard = Encoding { request in
        var json = "{\"operationName\":" + Variable.quote(request.operationName)
        switch request.document {
        case .text(let text): json += ",\"query\":" + Variable.quote(text)
        case .id(let id): json += ",\"documentId\":" + Variable.quote(id)
        }
        json += ",\"variables\":" + request.variables.json
        if let errorBehavior = request.errorBehavior { json += ",\"onError\":" + Variable.quote(errorBehavior.rawValue) }
        json += "}"
        return Data(json.utf8)
    }
}

/// One verb: a request yields a stream of payloads, each a GraphQL response
/// body. A query's stream carries one payload; a deferred response's its
/// parts, the first with `data`; a subscription's its events. A wrapper
/// wraps one method, whatever the operation's kind.
public protocol Transport: Sendable {
    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error>
}

extension Transport {
    /// The one payload of a request that answers once: the stream's first,
    /// or the failure a stream that delivers none is.
    public func payload(_ request: Request) async throws -> Data {
        for try await payload in send(request) { return payload }
        throw TransportError(statusCode: 0, body: "the transport delivered no payload for \(request.operationName)")
    }

    /// A stream of one payload, for a transport that answers once.
    public static func once(_ answer: @escaping @Sendable () async throws -> Data) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await answer())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A response with an HTTP status outside 200 to 299, or, with status 0, a
/// request that got no response: a socket that closed under it, or a
/// recorded transport with nothing recorded for it. A connection that fails
/// under `URLSession` throws the system's `URLError` instead, and a request
/// error answered as `application/graphql-response+json` with a 4xx or 5xx
/// status throws `GraphQLErrors`.
public struct TransportError: Error, CustomStringConvertible, Sendable, LocalizedError {
    /// The response's HTTP status, or 0 when there was none, as the web's
    /// `XMLHttpRequest` reports it.
    public let statusCode: Int
    /// The response's body, or, without a response, what went wrong.
    public let body: String

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    public var description: String {
        let body = body.prefix(200)
        return statusCode == 0 ? String(body) : "HTTP \(statusCode): \(body)"
    }

    public var errorDescription: String? { description }
}

/// POSTs operations as JSON to one endpoint. An operation with `@defer` asks
/// for `multipart/mixed` and reads the parts as they arrive; a subscription
/// asks for `text/event-stream` and reads its events, `graphql-sse` in its
/// distinct-connections mode. Credentials are read per attempt, so a rotated
/// token reaches the next request.
public struct URLSessionTransport: Transport {
    public let url: URL
    public var headers: [String: String]
    /// Headers read for every attempt, after the fixed ones: a credential a
    /// session rotates reaches each request as it is made.
    public let credentials: @Sendable () async throws -> [String: String]
    public let encoding: Encoding
    let session: URLSession

    public init(url: URL, headers: [String: String] = [:], credentials: @escaping @Sendable () async throws -> [String: String] = { [:] }, encoding: Encoding = .standard, session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.credentials = credentials
        self.encoding = encoding
        self.session = session
    }

    private func urlRequest(_ request: Request) async throws -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A subscription asks for an event stream, `graphql-sse` in its
        // distinct-connections mode; a deferred operation for multipart.
        let accept = switch (request.kind, request.incremental) {
        case (.subscription, _): "text/event-stream, application/graphql-response+json, application/json"
        case (_, true): "multipart/mixed; deferSpec=20220824, application/graphql-response+json, application/json"
        case (_, false): "application/graphql-response+json, application/json"
        }
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in try await credentials() { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = encoding.body(request)
        return urlRequest
    }

    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try await urlRequest(request)
                    var response: HTTPURLResponse?
                    // How the body is framed, by the response's content type:
                    // multipart parts, an event stream's events, or one body.
                    var parts: MultipartParser?
                    var events: EventStreamParser?
                    var body = Data()
                    for try await delivery in Deliveries.of(urlRequest, on: session) {
                        switch delivery {
                        case .response(let received):
                            response = received as? HTTPURLResponse
                            let contentType = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
                            parts = MultipartParser.boundary(in: contentType).map(MultipartParser.init(boundary:))
                            if EventStreamParser.frames(contentType) { events = EventStreamParser() }
                        case .chunk(let chunk):
                            guard let response, (200..<300).contains(response.statusCode) else {
                                body.append(chunk)
                                continue
                            }
                            if var reader = parts {
                                for part in reader.push(chunk) { continuation.yield(part) }
                                parts = reader
                            } else if var reader = events {
                                for payload in reader.push(chunk) { continuation.yield(payload) }
                                events = reader
                            } else {
                                body.append(chunk)
                            }
                        }
                    }
                    if let response, !(200..<300).contains(response.statusCode) {
                        // A server of the GraphQL-over-HTTP media type answers
                        // a request error, a response without data, with a 4xx
                        // or 5xx status: its errors are the request kind of
                        // failure, not the transport's.
                        if Self.answersInGraphQLResponse(response), let errors = Self.requestErrors(body) { throw errors }
                        throw TransportError(statusCode: response.statusCode, body: String(decoding: body, as: UTF8.self))
                    }
                    if var reader = parts {
                        for part in reader.finish() { continuation.yield(part) }
                    } else if var reader = events {
                        for payload in reader.finish() { continuation.yield(payload) }
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

    /// Whether the response's media type is `application/graphql-response+json`,
    /// whose body is a GraphQL response whatever the status. The older
    /// `application/json` promises that only with a 2xx status.
    private static func answersInGraphQLResponse(_ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/graphql-response+json"
    }

    /// The errors of a body that is a GraphQL response with errors and no
    /// data, or nil for any other body.
    private static func requestErrors(_ body: Data) -> GraphQLErrors? {
        let bytes = [UInt8](body)
        guard !bytes.isEmpty else { return nil }
        var errors: [Ingest.ResponseError] = []
        var hasData = false
        do {
            try bytes.withUnsafeBufferPointer { buffer in
                var scanner = Ingest.Scanner(base: buffer.baseAddress!, count: buffer.count)
                try scanner.members { key, scanner in
                    switch key {
                    case "errors":
                        errors = try scanner.responseErrors()
                    case "data":
                        hasData = scanner.peek() != 0x6E
                        try scanner.skipValue()
                    default:
                        try scanner.skipValue()
                    }
                }
            }
        } catch {
            return nil
        }
        guard !hasData, !errors.isEmpty else { return nil }
        return GraphQLErrors(errors: errors.map { FieldError(message: $0.message, path: $0.path.map { Ingest.render($0) } ?? "", extensions: $0.extensions) })
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

/// Splits a `text/event-stream` body into the payloads of its `next` events,
/// however the bytes are chunked: `graphql-sse` in its distinct-connections
/// mode, one response per operation, where a `next` event carries a response
/// payload and `complete` ends the stream. A field is `name: value`, with
/// one space after the colon dropped; the `data` lines of an event join with
/// a line break; a blank line ends an event; a line beginning with a colon
/// is a comment. `id`, `retry` and an event of another name are dropped.
public struct EventStreamParser: Sendable {
    private var buffer: [UInt8] = []
    /// How far the buffer has been searched for a line end.
    private var scanned = 0
    /// The event being read: its name, and its data lines so far.
    private var event: [UInt8] = []
    private var data: [UInt8]?
    /// Whether the stream's first bytes were seen, where a byte order mark
    /// may sit.
    private var opened = false
    public private(set) var finished = false

    public init() {}

    /// Whether a content type is an event stream's.
    public static func frames(_ contentType: String) -> Bool {
        contentType.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("text/event-stream")
    }

    /// Feeds a chunk; returns the payloads of the `next` events completed
    /// within it. A line ends at a line feed, with a carriage return before it
    /// dropped; a byte order mark at the stream's start is skipped.
    public mutating func push(_ chunk: some Collection<UInt8>) -> [Data] {
        if finished { return [] }
        buffer.append(contentsOf: chunk)
        if !opened, buffer.count >= 3 {
            opened = true
            if buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF { buffer.removeFirst(3) }
        }
        var payloads: [Data] = []
        var lineStart = 0
        while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if let payload = read(buffer[lineStart..<lineEnd]) { payloads.append(payload) }
            lineStart = newline + 1
            scanned = lineStart
            if finished {
                buffer = []
                return payloads
            }
        }
        // The lines read are let go once per chunk, not once per line.
        buffer.removeSubrange(0..<lineStart)
        scanned = buffer.count
        return payloads
    }

    /// The event left open when the stream ended without a blank line.
    public mutating func finish() -> [Data] {
        if finished { return [] }
        var payloads: [Data] = []
        if !buffer.isEmpty {
            var line = buffer[...]
            if line.last == 0x0D { line = line.dropLast() }
            if let payload = read(line) { payloads.append(payload) }
            buffer = []
        }
        if !finished, let payload = dispatch() { payloads.append(payload) }
        finished = true
        return payloads
    }

    /// One line: a blank line dispatches the event; a comment is dropped; a
    /// field sets the event's name or adds a data line.
    private mutating func read(_ line: ArraySlice<UInt8>) -> Data? {
        if line.isEmpty { return dispatch() }
        if line.first == 0x3A { return nil }
        let colon = line.firstIndex(of: 0x3A) ?? line.endIndex
        let field = line[line.startIndex..<colon]
        var value = colon < line.endIndex ? line[(colon + 1)...] : line[line.endIndex...]
        if value.first == 0x20 { value = value.dropFirst() }
        if field.elementsEqual("event".utf8) {
            event = Array(value)
        } else if field.elementsEqual("data".utf8) {
            if var lines = data {
                lines.append(0x0A)
                lines.append(contentsOf: value)
                data = lines
            } else {
                data = Array(value)
            }
        }
        return nil
    }

    /// The event read so far: a `next` with data is a payload; `complete`
    /// ends the stream; anything else is dropped.
    private mutating func dispatch() -> Data? {
        defer {
            event = []
            data = nil
        }
        if event.elementsEqual("complete".utf8) {
            finished = true
            return nil
        }
        guard event.elementsEqual("next".utf8), let data else { return nil }
        return Data(data)
    }
}

/// Operations over `graphql-transport-ws`: one WebSocket per transport,
/// opened on the first request, with `connection_init` and `connection_ack`,
/// then `subscribe`, `next`, `error` and `complete` by id. A subscription's
/// stream is its events; a query's or mutation's the one payload the server
/// completes after.
public actor GraphQLTransportWebSocket: Transport {
    public let url: URL
    public let headers: [String: String]
    /// Headers read when a connection is opened, after the fixed ones.
    public let credentials: @Sendable () async throws -> [String: String]
    public let encoding: Encoding
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
    /// Awaited when a socket's read fails, before the failure is weighed.
    private var readFailed: (@Sendable () async -> Void)?

    public init(url: URL, headers: [String: String] = [:], credentials: @escaping @Sendable () async throws -> [String: String] = { [:] }, encoding: Encoding = .standard, connectionParams: Variable? = nil, session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.credentials = credentials
        self.encoding = encoding
        self.connectionParams = connectionParams
        self.session = session
    }

    public nonisolated func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
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
        let payload = String(decoding: encoding.body(request), as: UTF8.self)
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
            // Read with a suspension, which lets another request onto the
            // actor: it may have opened the socket meanwhile, and then this
            // one joins it rather than opening a second.
            let read = try await credentials()
            if acknowledged { return }
            if socket == nil {
                var urlRequest = URLRequest(url: url)
                for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
                for (name, value) in read { urlRequest.setValue(value, forHTTPHeaderField: name) }
                urlRequest.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                let socket = session.webSocketTask(with: urlRequest)
                self.socket = socket
                socket.resume()
                receiving = Task { await self.receive(from: socket) }
                let payload = connectionParams.map { ",\"payload\":" + $0.json } ?? ""
                try await send("{\"type\":\"connection_init\"\(payload)}")
                // While the frame was on its way the socket may have failed,
                // and then nothing would answer, or been acknowledged already.
                guard self.socket === socket else { throw TransportError(statusCode: 0, body: "the socket is closed") }
                if acknowledged { return }
            }
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
                await readFailed?()
                guard self.socket === socket else { return }
                fail(error)
                return
            }
        }
    }

    /// Sets what each failed read awaits before it is weighed, so a test can
    /// hold a closed socket's end until another socket has opened.
    package func awaitOnReadFailure(_ hold: @escaping @Sendable () async -> Void) {
        readFailed = hold
    }

    /// Reads a `graphql-transport-ws` frame: its type, id and payload bytes,
    /// over the ingest's scanner.
    package static func frame(_ data: Data) throws -> (type: String?, id: String?, payload: Data?) {
        let bytes = [UInt8](data)
        var type: String?
        var id: String?
        var payload: Data?
        try bytes.withUnsafeBufferPointer { buffer in
            var scanner = Ingest.Scanner(base: buffer.baseAddress!, count: buffer.count)
            try scanner.members { key, scanner in
                switch key {
                case "type": type = try scanner.stringValue()
                case "id": id = try scanner.stringValue()
                case "payload": payload = try scanner.rawValue(in: bytes)
                default: try scanner.skipValue()
                }
            }
        }
        return (type, id, payload)
    }

    private func handle(_ data: Data) throws {
        let frame = try Self.frame(data)
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
                let failure = errors.isEmpty
                    ? GraphQLErrors(messages: ["subscription error"])
                    : GraphQLErrors(errors: errors.map { FieldError(message: $0.message, path: $0.path.map { Ingest.render($0) } ?? "", extensions: $0.extensions) })
                subscribers.removeValue(forKey: id)?.finish(throwing: failure)
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
