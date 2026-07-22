import Foundation
import Network

/// A tiny, dependency-free HTTP/1.1 server that serves photobooth sessions to
/// phones. It is bound to **loopback only** (`127.0.0.1`) — the only thing that
/// connects to it is the local `cloudflared` tunnel, which exposes it publicly.
/// Binding to loopback avoids the macOS firewall / local-network permission
/// prompts a LAN-facing listener would trigger.
///
/// Routes:
///   GET /healthz                 → "ok"
///   GET /s/<id>/                 → mobile share page (HTML)
///   GET /s/<id>/strip.png        → the printable strip image
///   GET /s/<id>/montage.mp4      → the montage video (HTTP range / byte-serving)
///
/// `<id>` is the session folder name (a timestamp). Files are resolved strictly
/// inside `~/Pictures/Photobooth/<id>/` with a path-traversal guard.
final class ShareServer {
    private let queue = DispatchQueue(label: "photobooth.shareserver")
    private var listener: NWListener?
    private(set) var port: UInt16?

    /// Bind to the first free port in `range` on loopback, **without blocking the
    /// caller**. `completion` is invoked (on the server's queue) with the chosen
    /// port, or an error if none could be bound. Safe to call from the main actor.
    func start(preferred range: ClosedRange<UInt16> = 8088...8098,
               completion: @escaping (Result<UInt16, Error>) -> Void) {
        if let port { completion(.success(port)); return }
        queue.async { [weak self] in
            self?.bind(ports: Array(range), index: 0, completion: completion)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.port = nil
        }
    }

    // MARK: - Listener

    /// Try each port in turn. NWListener reports bind success/failure
    /// asynchronously via `stateUpdateHandler`; on failure we advance to the next
    /// port. Runs entirely on `queue` — never the main thread.
    private func bind(ports: [UInt16], index: Int,
                      completion: @escaping (Result<UInt16, Error>) -> Void) {
        guard index < ports.count else {
            completion(.failure(ShareServerError.noFreePort))
            return
        }
        let port = ports[index]
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind explicitly to loopback so we never accept off-device connections.
        params.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            bind(ports: ports, index: index + 1, completion: completion)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        var settled = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !settled else { return }
            switch state {
            case .ready:
                settled = true
                self.listener = listener
                self.port = port
                completion(.success(port))
            case .failed, .cancelled:
                settled = true
                listener.cancel()
                self.bind(ports: ports, index: index + 1, completion: completion)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            // GET requests carry no body, so headers ending in CRLFCRLF = done.
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                self.handle(header: header, on: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    // MARK: - Routing

    private func handle(header: Data, on connection: NWConnection) {
        guard let text = String(data: header, encoding: .utf8) else {
            return finish(connection, Response.plain(400, "bad request"))
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return finish(connection, Response.plain(405, "method not allowed"))
        }
        let rawPath = String(parts[1])
        let path = rawPath.removingPercentEncoding ?? rawPath
        let rangeHeader = headerValue("Range", in: lines)

        let response = route(path: path, range: rangeHeader)
        finish(connection, response)
    }

    private func route(path: String, range: String?) -> Response {
        let clean = path.split(separator: "?").first.map(String.init) ?? path

        if clean == "/healthz" { return Response.plain(200, "ok") }

        // /s/<id>            → page
        // /s/<id>/           → page
        // /s/<id>/<file>     → asset
        let comps = clean.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.first == "s", comps.count >= 2 else {
            return Response.plain(404, "not found")
        }
        let id = comps[1]
        guard isSafeID(id), let folder = sessionFolder(for: id) else {
            return Response.plain(404, "not found")
        }

        // Page request (no file component).
        if comps.count == 2 {
            return Response.html(200, SharePage.html(id: id, folder: folder))
        }

        let file = comps[2]
        switch file {
        case "strip.png":
            return fileResponse(folder.appendingPathComponent("strip.png"),
                                type: "image/png", range: range)
        case "strip.jpg":
            return fileResponse(folder.appendingPathComponent("strip.jpg"),
                                type: "image/jpeg", range: range)
        case "strip.gif":
            return fileResponse(folder.appendingPathComponent("strip.gif"),
                                type: "image/gif", range: range)
        case "montage.mp4":
            return fileResponse(folder.appendingPathComponent("montage.mp4"),
                                type: "video/mp4", range: range)
        default:
            return Response.plain(404, "not found")
        }
    }

    // MARK: - File serving (with HTTP range support)

    private func fileResponse(_ url: URL, type: String, range: String?) -> Response {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? Int, size > 0 else {
            return Response.plain(404, "not found")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Response.plain(404, "not found")
        }
        defer { try? handle.close() }

        var headers = [
            "Content-Type": type,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]

        if let (start, end) = parseRange(range, fileSize: size) {
            let length = end - start + 1
            try? handle.seek(toOffset: UInt64(start))
            let body = (try? handle.read(upToCount: length)) ?? Data()
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            headers["Content-Length"] = String(body.count)
            return Response(status: 206, headers: headers, body: body)
        }

        let body = (try? handle.readToEnd()) ?? Data()
        headers["Content-Length"] = String(body.count)
        return Response(status: 200, headers: headers, body: body)
    }

    /// Parse `bytes=start-end` (end optional). Returns nil for absent/invalid.
    private func parseRange(_ header: String?, fileSize: Int) -> (Int, Int)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = bounds.first else { return nil }

        if first.isEmpty {
            // Suffix range: bytes=-N → last N bytes.
            guard bounds.count == 2, let n = Int(bounds[1]), n > 0 else { return nil }
            let start = max(0, fileSize - n)
            return (start, fileSize - 1)
        }
        guard let start = Int(first), start < fileSize else { return nil }
        var end = fileSize - 1
        if bounds.count == 2, !bounds[1].isEmpty, let parsed = Int(bounds[1]) {
            end = min(parsed, fileSize - 1)
        }
        guard end >= start else { return nil }
        return (start, end)
    }

    // MARK: - Helpers

    private func headerValue(_ name: String, in lines: [String]) -> String? {
        let prefix = name.lowercased() + ":"
        for line in lines.dropFirst() where line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// IDs are session folder names: digits, dashes, underscores only.
    private func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func sessionFolder(for id: String) -> URL? {
        guard let base = try? SessionStore.baseDirectory else { return nil }
        let folder = base.appendingPathComponent(id, isDirectory: true)
        // Defense in depth: the resolved path must stay inside the base dir.
        guard folder.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    private func finish(_ connection: NWConnection, _ response: Response) {
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Response

private struct Response {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func plain(_ status: Int, _ text: String) -> Response {
        Response(status: status,
                 headers: ["Content-Type": "text/plain; charset=utf-8"],
                 body: Data(text.utf8))
    }

    static func html(_ status: Int, _ html: String) -> Response {
        Response(status: status,
                 headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"],
                 body: Data(html.utf8))
    }

    func serialized() -> Data {
        var headers = self.headers
        headers["Connection"] = "close"
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(body.count)
        }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "OK"
        }
    }
}

enum ShareServerError: LocalizedError {
    case noFreePort

    var errorDescription: String? {
        switch self {
        case .noFreePort: return "No free local port for the share server."
        }
    }
}
