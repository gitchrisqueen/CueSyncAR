//
//  DebugMirrorServer.swift
//  CueSync AR
//
//  Remote debug mirror: a tiny HTTP server on the LAN that serves the
//  latest rendered ARView snapshot (camera + spatial overlays) plus a
//  tracking-state JSON. Purpose: the iPad sits at the pool table out of
//  arm's reach of the Mac, and QuickTime mirroring needs a cable — this
//  lets any browser on the same Wi-Fi (person or debugging agent) watch
//  what's on screen and inspect pipeline state live.
//
//  Scope: debugging aid, LAN-only, read-only, off by default; started
//  from the HUD toggle. Serves:
//    GET /            auto-refreshing HTML viewer
//    GET /frame.jpg   latest ARView snapshot (JPEG)
//    GET /state.json  tracking/calibration/guide state
//

import Foundation
import Network
import os

final class DebugMirrorServer: @unchecked Sendable {
    static let port: UInt16 = 8787
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "mirror")

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cuesync.debugmirror")
    private let lock = NSLock()
    private var latestJPEG: Data?
    private var latestStateJSON: Data?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters,
                                  on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        Self.log.info("debug mirror listening on port \(Self.port)")
    }

    func stop() {
        listener.cancel()
        Self.log.info("debug mirror stopped")
    }

    /// Publish the newest snapshot + state (called ~1 Hz from the app).
    func update(jpeg: Data?, stateJSON: Data?) {
        lock.lock()
        if let jpeg { latestJPEG = jpeg }
        if let stateJSON { latestStateJSON = stateJSON }
        lock.unlock()
    }

    /// Best-effort LAN address for showing the URL in the HUD (en0 = Wi-Fi).
    static func deviceIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer = interfaces
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let namePtr = interface.ifa_name,
                  Self.string(fromCString: namePtr) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = host.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress.map { Self.string(fromCString: $0) }
                }
            }
        }
        return address
    }

    /// Null-terminated C string → String without the deprecated
    /// `String(cString:)` (truncates at the terminator, decodes UTF-8).
    private static func string(fromCString pointer: UnsafePointer<CChar>) -> String {
        let length = strlen(pointer)
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            String(bytes: UnsafeBufferPointer(start: bytes, count: length),
                   encoding: .utf8) ?? ""
        }
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response = self.response(for: path)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for rawPath: String) -> Data {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        switch path {
        case "/frame.jpg":
            lock.lock(); let jpeg = latestJPEG; lock.unlock()
            guard let jpeg else { return Self.httpResponse(status: "404 Not Found") }
            return Self.httpResponse(body: jpeg, contentType: "image/jpeg")
        case "/state.json":
            lock.lock(); let json = latestStateJSON; lock.unlock()
            return Self.httpResponse(body: json ?? Data("{}".utf8),
                                     contentType: "application/json")
        case "/":
            return Self.httpResponse(body: Data(Self.viewerHTML.utf8),
                                     contentType: "text/html; charset=utf-8")
        default:
            return Self.httpResponse(status: "404 Not Found")
        }
    }

    private static func httpResponse(status: String = "200 OK",
                                     body: Data = Data(),
                                     contentType: String = "text/plain") -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static let viewerHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <title>CueSync AR — Debug Mirror</title>
    <style>
      body { margin: 0; background: #101614; color: #d9e5df; \
    font: 13px -apple-system, system-ui, monospace; }
      #wrap { display: flex; flex-wrap: wrap; gap: 12px; padding: 12px; }
      img { max-width: min(72vw, 1100px); border-radius: 8px; \
    border: 1px solid #2FA36B; }
      pre { flex: 1; min-width: 260px; white-space: pre-wrap; \
    background: #182420; padding: 10px; border-radius: 8px; margin: 0; }
      h1 { font-size: 15px; padding: 10px 12px 0; margin: 0; color: #2FA36B; }
    </style></head><body>
    <h1>CueSync AR — Debug Mirror</h1>
    <div id="wrap"><img id="frame" alt="waiting for first frame…">
    <pre id="state">waiting…</pre></div>
    <script>
      const img = document.getElementById('frame');
      const pre = document.getElementById('state');
      setInterval(() => { img.src = '/frame.jpg?' + Date.now(); }, 700);
      setInterval(async () => {
        try {
          const r = await fetch('/state.json');
          pre.textContent = JSON.stringify(await r.json(), null, 2);
        } catch (e) { pre.textContent = 'state fetch failed: ' + e; }
      }, 1000);
    </script></body></html>
    """
}
