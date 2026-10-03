import Foundation

/// One operation execution over the wire.
public struct Request: Sendable {
    public let operationName: String
    public let text: String
    public let persistedID: String
    public let variables: Variables

    public init(operationName: String, text: String, persistedID: String, variables: Variables) {
        self.operationName = operationName
        self.text = text
        self.persistedID = persistedID
        self.variables = variables
    }

    /// The GraphQL-over-HTTP JSON body.
    public var body: Data {
        var json = "{\"operationName\":" + Variable.quote(operationName)
        json += ",\"query\":" + Variable.quote(text)
        json += ",\"variables\":" + variables.json + "}"
        return Data(json.utf8)
    }
}

public protocol Transport: Sendable {
    func execute(_ request: Request) async throws -> Data
}

public struct TransportError: Error, CustomStringConvertible, Sendable {
    public let statusCode: Int
    public let body: String
    public var description: String { "HTTP \(statusCode): \(body.prefix(200))" }
}

/// POSTs operations as JSON to one endpoint.
public struct URLSessionTransport: Transport {
    public let url: URL
    public var headers: [String: String]
    let session: URLSession

    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public func execute(_ request: Request) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/graphql-response+json, application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransportError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

/// Serves recorded responses by operation name; for tests, previews and benchmarks.
public final class RecordedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Data]
    public private(set) var requests: [Request] = []

    public init(_ responses: [String: Data] = [:]) {
        self.responses = responses
    }

    public func record(_ operationName: String, _ data: Data) {
        lock.withLock { responses[operationName] = data }
    }

    public func execute(_ request: Request) async throws -> Data {
        try lock.withLock {
            requests.append(request)
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
