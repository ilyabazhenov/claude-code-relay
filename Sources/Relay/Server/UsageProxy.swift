import Foundation
import Network

/// A loopback HTTP/1.1 pass-through proxy that sits in front of `api.anthropic.com`
/// for one purpose: to read the `anthropic-ratelimit-*` response headers so Relay can
/// show the account's 5-hour / weekly usage in the menu bar.
///
/// **Only Relay's own usage ping goes through here.** The proxy is pointed at solely by
/// the `ANTHROPIC_BASE_URL` that `UsagePinger` sets on its own throwaway `claude -p`
/// subprocess — your real Claude sessions (Desktop/CLI/IDE) talk to the API directly and
/// never pass through Relay. That's what makes usage tracking client-agnostic without
/// routing anyone's real traffic through us.
///
/// Design constraints (see AGENTS.md):
///   - **Byte-exact**: the request head is minimally rewritten (only `Host` and
///     `Connection`), everything else — request body, the entire response including
///     streamed SSE — is relayed verbatim. We never reconstruct or re-encode bodies.
///   - **One request per connection** (forces `Connection: close`), which removes all
///     keep-alive/pipelining bookkeeping.
///   - Credentials (`x-api-key` / `authorization`) pass straight through over TLS to
///     Anthropic and are **never logged or stored**. Only `anthropic-ratelimit-*`
///     response headers are surfaced.
final class UsageProxy: @unchecked Sendable {
    /// Called on the network queue with the captured `anthropic-ratelimit-*` headers
    /// (names lower-cased) each time a response head is seen.
    typealias HeadersHandler = @Sendable ([String: String]) -> Void

    private let upstreamHost: NWEndpoint.Host = "api.anthropic.com"
    private let upstreamPort: NWEndpoint.Port = 443
    private let queue = DispatchQueue(label: "relay.usageproxy")
    private let onHeaders: HeadersHandler

    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0

    /// Guard against a runaway head that never terminates.
    private let maxHeadBytes = 256 * 1024

    init(onHeaders: @escaping HeadersHandler) {
        self.onHeaders = onHeaders
    }

    /// Start listening on 127.0.0.1. Pass `0` to let the OS choose. Returns the bound
    /// port.
    func start(requestedPort: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let boxErr = ErrorBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? requestedPort
                ready.signal()
            case .failed(let error):
                boxErr.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "relay.usageproxy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "usage proxy listener did not become ready"])
        }
        if let error = boxErr.value { throw error }
        return boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private final class ErrorBox: @unchecked Sendable { var value: Error? }

    // MARK: - Per-connection plumbing

    /// Holds both legs of one proxied request and tears them down exactly once.
    private final class Link: @unchecked Sendable {
        let client: NWConnection
        let upstream: NWConnection
        private let lock = NSLock()
        private var closed = false
        init(client: NWConnection, upstream: NWConnection) {
            self.client = client
            self.upstream = upstream
        }
        func close() {
            lock.lock(); defer { lock.unlock() }
            if closed { return }
            closed = true
            client.cancel()
            upstream.cancel()
        }
    }

    private func accept(_ client: NWConnection) {
        let tls = NWProtocolTLS.Options()   // default: validates the api.anthropic.com cert + SNI
        let params = NWParameters(tls: tls)
        let upstream = NWConnection(host: upstreamHost, port: upstreamPort, using: params)
        let link = Link(client: client, upstream: upstream)

        upstream.stateUpdateHandler = { state in
            if case .failed = state { link.close() }
        }
        client.stateUpdateHandler = { state in
            if case .failed = state { link.close() }
        }
        upstream.start(queue: queue)
        client.start(queue: queue)

        // Read the request head from the client so we can fix up Host/Connection.
        readRequestHead(link, buffer: Data())
    }

    // MARK: Request path (client → upstream)

    private func readRequestHead(_ link: Link, buffer: Data) {
        link.client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headBlock = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
                let leftover = buffer.subdata(in: terminator.upperBound..<buffer.endIndex)
                let rewritten = Self.rewriteRequestHead(headBlock)

                // Send rewritten head, then any body bytes already buffered.
                link.upstream.send(content: rewritten, completion: .contentProcessed { _ in })
                if !leftover.isEmpty {
                    link.upstream.send(content: leftover, completion: .contentProcessed { _ in })
                }
                // Continue relaying the rest of the request body verbatim, and start
                // reading the response.
                self.pumpBody(from: link.client, to: link.upstream, link: link)
                self.readResponseHead(link, buffer: Data())
                return
            }

            if buffer.count > self.maxHeadBytes { link.close(); return }
            if error != nil || isComplete { link.close(); return }
            self.readRequestHead(link, buffer: buffer)
        }
    }

    /// Rewrite only `Host` (→ api.anthropic.com) and `Connection` (→ close); drop any
    /// `Proxy-Connection`. Everything else — including auth headers — is preserved.
    static func rewriteRequestHead(_ headBlock: Data) -> Data {
        guard let text = String(data: headBlock, encoding: .utf8) else {
            // Non-UTF8 head should never happen for HTTP; forward as-is to be safe.
            return headBlock + Data("\r\n\r\n".utf8)
        }
        let lines = text.components(separatedBy: "\r\n")
        var out: [String] = []
        var sawConnection = false
        for (index, line) in lines.enumerated() {
            if index == 0 { out.append(line); continue }   // request line
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                out.append("Host: api.anthropic.com")
            } else if lower.hasPrefix("connection:") {
                out.append("Connection: close")
                sawConnection = true
            } else if lower.hasPrefix("proxy-connection:") {
                continue
            } else {
                out.append(line)
            }
        }
        if !sawConnection { out.append("Connection: close") }
        let rebuilt = out.joined(separator: "\r\n") + "\r\n\r\n"
        return Data(rebuilt.utf8)
    }

    // MARK: Response path (upstream → client)

    private func readResponseHead(_ link: Link, buffer: Data) {
        link.upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // Forward the response head + terminator VERBATIM, then anything after.
                let headEnd = terminator.upperBound
                let headBytes = buffer.subdata(in: buffer.startIndex..<headEnd)
                let leftover = buffer.subdata(in: headEnd..<buffer.endIndex)

                self.sniff(headBytes)

                link.client.send(content: headBytes, completion: .contentProcessed { _ in })
                if !leftover.isEmpty {
                    link.client.send(content: leftover, completion: .contentProcessed { _ in })
                }
                // Relay the remaining response body (incl. streamed SSE) verbatim.
                self.pumpBody(from: link.upstream, to: link.client, link: link)
                return
            }

            if buffer.count > self.maxHeadBytes {
                // Couldn't find a head boundary: just relay whatever we have and pump.
                link.client.send(content: buffer, completion: .contentProcessed { _ in })
                self.pumpBody(from: link.upstream, to: link.client, link: link)
                return
            }
            if error != nil || isComplete {
                if !buffer.isEmpty {
                    link.client.send(content: buffer, completion: .contentProcessed { _ in })
                }
                link.close()
                return
            }
            self.readResponseHead(link, buffer: buffer)
        }
    }

    /// Parse a response head copy and hand any `anthropic-ratelimit-*` headers to the
    /// callback. Never mutates the bytes that are forwarded.
    private func sniff(_ headBytes: Data) {
        guard let text = String(data: headBytes, encoding: .utf8) else { return }
        var captured: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name.hasPrefix("anthropic-ratelimit") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            captured[name] = value
        }
        if !captured.isEmpty { onHeaders(captured) }
    }

    // MARK: Opaque byte pump

    /// Relay bytes from one connection to the other verbatim until EOF/error, then
    /// tear the whole link down.
    private func pumpBody(from source: NWConnection, to destination: NWConnection, link: Link) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                link.close()
                return
            }
            self.pumpBody(from: source, to: destination, link: link)
        }
    }
}
