import Foundation
import Network

/// Registro de los archivos que la app web manda al código nativo.
final class MoonFileStore {
    static let shared = MoonFileStore()
    private let lock = NSLock()
    private var map: [String: URL] = [:]
    var folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("moon-export", isDirectory: true)

    func create(name: String) -> (id: String, url: URL)? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = folder.appendingPathComponent("\(id)-\(safe)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        lock.lock(); map[id] = url; lock.unlock()
        return (id, url)
    }

    func url(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }
}

/// Canal para pasar archivos grandes de la app web al código nativo sin convertirlos en texto:
/// un servidor mínimo que solo escucha dentro del propio teléfono (127.0.0.1) y exige una clave al azar.
final class MoonUploadServer {
    static let shared = MoonUploadServer()

    private final class Session {
        let conn: NWConnection
        var buffer = Data()
        var headersDone = false
        var contentLength = 0
        var received = 0
        var handle: FileHandle?
        var responded = false
        init(_ c: NWConnection) { conn = c }
    }

    private let queue = DispatchQueue(label: "moon.upload.server")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private(set) var port: UInt16 = 0
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// Arranca el servidor (una sola vez) y devuelve el puerto.
    func start() throws -> UInt16 {
        if listener != nil && port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self, weak l] st in
            switch st {
            case .ready: self?.port = l?.port?.rawValue ?? 0; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        guard port != 0 else { l.cancel(); throw MoonError.bad("No se pudo abrir el canal para pasar archivos") }
        listener = l
        return port
    }

    private func accept(_ c: NWConnection) {
        let s = Session(c)
        sessions[ObjectIdentifier(s)] = s
        c.stateUpdateHandler = { [weak self, weak s] st in
            switch st {
            case .failed, .cancelled: if let s = s { self?.close(s) }
            default: break
            }
        }
        c.start(queue: queue)
        receive(s)
    }

    private func close(_ s: Session) {
        try? s.handle?.close()
        s.handle = nil
        sessions[ObjectIdentifier(s)] = nil
    }

    private func receive(_ s: Session) {
        s.conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.consume(s, d) }
            if error != nil || complete {
                if !s.responded { self.close(s); s.conn.cancel() }
                return
            }
            if !s.responded { self.receive(s) }
        }
    }

    private func respond(_ s: Session, _ status: String) {
        guard !s.responded else { return }
        s.responded = true
        try? s.handle?.close(); s.handle = nil
        let head = "HTTP/1.1 \(status)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Max-Age: 600\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        s.conn.send(content: head.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            s.conn.cancel()
            self?.close(s)
        })
    }

    private func consume(_ s: Session, _ d: Data) {
        if s.headersDone { body(s, d); return }
        s.buffer.append(d)
        guard let r = s.buffer.range(of: Data([13, 10, 13, 10])) else {
            if s.buffer.count > 64 * 1024 { respond(s, "431 Request Header Fields Too Large") }
            return
        }
        let head = String(decoding: s.buffer[s.buffer.startIndex..<r.lowerBound], as: UTF8.self)
        let rest = Data(s.buffer[r.upperBound...])
        s.buffer = Data()
        s.headersDone = true
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2 else { respond(s, "400 Bad Request"); return }
        let method = String(first[0]), path = String(first[1])
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 && kv[0].lowercased() == "content-length" { s.contentLength = Int(kv[1]) ?? 0 }
        }
        if method == "OPTIONS" { respond(s, "204 No Content"); return }
        let parts = path.split(separator: "/").map(String.init)      // put / clave / id
        guard method == "POST", parts.count == 3, parts[0] == "put", parts[1] == token else { respond(s, "403 Forbidden"); return }
        guard let url = MoonFileStore.shared.url(parts[2]), let h = try? FileHandle(forWritingTo: url) else { respond(s, "404 Not Found"); return }
        try? h.truncate(atOffset: 0)
        s.handle = h
        if s.contentLength == 0 { respond(s, "204 No Content"); return }
        if !rest.isEmpty { body(s, rest) }
    }

    private func body(_ s: Session, _ d: Data) {
        guard let h = s.handle, !s.responded else { return }
        do { try h.write(contentsOf: d) } catch { respond(s, "500 Internal Server Error"); return }
        s.received += d.count
        if s.received >= s.contentLength { respond(s, "204 No Content") }
    }
}
