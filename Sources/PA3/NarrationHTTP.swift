import Foundation
import Network

struct NarrationHTTPResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ status: Int, _ value: [String: Any]) -> Self {
        Self(status: status, body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> Self {
        json(status, ["error": message])
    }

    var wireData: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 409: "Conflict",
                      413: "Content Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Content",
                      429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}

struct NarrationHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case incomplete
        case request(NarrationHTTPRequest)
        case rejected(NarrationHTTPResponse)
    }

    // One bounded HTTP/1 request per connection. No transfer encodings or pipelining.
    static func parse(_ data: Data) -> ParseResult {
        let maxHeader = 16_384
        let maxBody = 512_000
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeader ? .rejected(.error(413, "Headers too large")) : .incomplete
        }
        guard separator.lowerBound <= maxHeader,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return .rejected(.error(400, "Invalid HTTP headers"))
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(first[2]), first[1].hasPrefix("/") else {
            return .rejected(.error(400, "Invalid HTTP request"))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .rejected(.error(400, "Invalid HTTP header"))
            }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else {
                return .rejected(.error(400, "Invalid or duplicate HTTP header"))
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            return .rejected(.error(400, "Use Content-Length; transfer encoding and Expect are unsupported"))
        }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength) else {
            return .rejected(.error(400, "Invalid Content-Length"))
        }
        guard length <= maxBody else { return .rejected(.error(413, "Request body too large")) }
        let expected = separator.upperBound + length
        guard data.count >= expected else { return .incomplete }
        guard data.count == expected else { return .rejected(.error(400, "Only one request per connection is supported")) }
        return .request(Self(method: String(first[0]), path: String(first[1]), headers: headers,
                             body: Data(data[separator.upperBound..<expected])))
    }
}

final class NarrationHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (NarrationHTTPRequest, @escaping @Sendable (NarrationHTTPResponse) -> Void) -> Void
    private let queue = DispatchQueue(label: "pa3.narration.http")
    private var listener: NWListener?
    private var clients: [UUID: NarrationHTTPClient] = [:]

    func start(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Logger.info("Narration HTTP listening on 127.0.0.1:\(port)")
            case .failed(let error): Logger.error("Narration HTTP listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.clients.count < 32 else { connection.cancel(); return }
            let id = UUID()
            let client = NarrationHTTPClient(connection: connection, queue: self.queue, handler: handler) { [weak self] in
                self?.clients.removeValue(forKey: id)
            }
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let current = Array(clients.values)
            clients.removeAll()
            current.forEach { $0.close() }
        }
    }
}

private final class NarrationHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: NarrationHTTPServer.Handler
    private let onClose: @Sendable () -> Void
    private var data = Data()
    private var responded = false
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping NarrationHTTPServer.Handler,
         onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed else { return }
            if self.responded { self.close() } else { self.respond(.error(408, "Request timed out")) }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let bytes { self.data.append(bytes) }
            switch NarrationHTTPRequest.parse(self.data) {
            case .incomplete:
                if complete || error != nil { self.close() } else { self.receive() }
            case .rejected(let response): self.respond(response)
            case .request(let request):
                self.handler(request) { [weak self] response in
                    guard let self else { return }
                    self.queue.async { self.respond(response) }
                }
            }
        }
    }

    private func respond(_ response: NarrationHTTPResponse) {
        guard !responded, !closed else { return }
        responded = true
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose()
    }
}
