import Foundation
import Network

/// A minimal HTTP request parsed from a single connection.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]   // header names lower-cased
    var body: Data

    /// Decodes the JSON body into `T`, or returns nil.
    func json<T: Decodable>(_ type: T.Type) -> T? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }

    /// Parses the JSON body into a loosely-typed dictionary.
    func jsonObject() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// A minimal HTTP response.
struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType: String

    init(status: Int, body: Data = Data(), contentType: String = "text/plain; charset=utf-8") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    static func ok(_ text: String = "ok") -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(text.utf8))
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, body: data, contentType: "application/json")
    }

    static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(text.utf8))
    }

    static let notFound = HTTPResponse.text("not found", status: 404)
    static let unauthorized = HTTPResponse.text("unauthorized", status: 401)

    fileprivate func serialized() -> Data {
        let reason = HTTPResponse.reasonPhrase(status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

/// A tiny loopback-only HTTP/1.1 server built on Network.framework.
///
/// One request per connection (`Connection: close`), which is all the hook scripts
/// (curl) need. Handlers are async so that long-poll endpoints (approvals, M2) can
/// suspend while awaiting a user decision.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// A tiny lock-guarded reference cell, used to hand values back out of the
    /// `@Sendable` state-update closure.
    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "relay.httpserver")
    private var listener: NWListener?
    private let handler: Handler

    /// The port the server actually bound to (resolved after `start`).
    private(set) var boundPort: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts the listener on 127.0.0.1. Pass `port == 0` to let the OS pick a free
    /// port. Returns the actual bound port.
    func start(requestedPort: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only — nothing off-machine can reach us.
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let startError = LockedBox<Error?>(nil)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? requestedPort
                ready.signal()
            case .failed(let error):
                startError.set(error)
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "relay.httpserver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        if let error = startError.get() { throw error }
        return boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.tryParse(buffer) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
                return
            }

            if error != nil || isComplete {
                self.send(.text("bad request", status: 400), on: connection)
                return
            }

            // Need more bytes.
            self.receive(connection, buffer: buffer)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    /// Attempts to parse a complete HTTP request from `buffer`. Returns nil if more
    /// bytes are needed (headers not yet terminated, or body shorter than
    /// Content-Length).
    private static func tryParse(_ buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        if available < contentLength {
            return nil   // wait for the rest of the body
        }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
