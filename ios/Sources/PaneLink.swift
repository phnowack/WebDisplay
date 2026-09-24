import Foundation
import Network

/// Transport to the laptop. Same framing as WebSocket (unmasked), no HTTP/TLS.
/// USB: we listen on 9702, Pane.exe reaches us through usbmux. Wi-Fi: we dial <host>:9702.
final class PaneLink {
    enum Kind: String { case usb = "USB", wifi = "Wi-Fi" }
    static let port: UInt16 = 9702
    let queue = DispatchQueue(label: "pane.link", qos: .userInteractive)

    /// called on `queue`
    var onMessage: ((UInt8, [UInt8]) -> Void)?
    /// called on main
    var onOpen: ((Kind) -> Void)?
    var onClose: (() -> Void)?

    private var listener: NWListener?
    private var conn: NWConnection?
    private var ready = false
    private(set) var kind: Kind = .wifi
    private var buf: [UInt8] = []
    private var rd = 0
    private var active = false
    private var dialItem: DispatchWorkItem?

    static var hostSetting: String {
        get { UserDefaults.standard.string(forKey: "host") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "host") }
    }

    func resume() { queue.async { self.active = true; self.startListener(); self.dial() } }
    func pause() {
        queue.async {
            self.active = false; self.dialItem?.cancel()
            self.listener?.cancel(); self.listener = nil
            if let c = self.conn { self.drop(c) }
        }
    }
    func reconnect() { queue.async { if let c = self.conn { self.drop(c) } else { self.dial() } } }

    // MARK: sending
    func send(text: String) { send(op: 1, Array(text.utf8)) }
    func send(json: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: json), let s = String(data: d, encoding: .utf8) else { return }
        send(text: s)
    }
    private func send(op: UInt8, _ p: [UInt8]) {
        queue.async {
            guard let c = self.conn, self.ready else { return }
            c.send(content: PaneLink.frame(op, p), completion: .idempotent)
        }
    }
    static func frame(_ op: UInt8, _ p: [UInt8]) -> Data {
        var f: [UInt8] = [0x80 | op]
        let n = p.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f += [126, UInt8(n >> 8), UInt8(n & 0xff)] }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((n >> (i * 8)) & 0xff)) } }
        f += p
        return Data(f)
    }

    // MARK: connection management (all on queue)
    private static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.allowLocalEndpointReuse = true
        p.serviceClass = .interactiveVideo
        return p
    }
    private func startListener() {
        guard active, listener == nil, let port = NWEndpoint.Port(rawValue: PaneLink.port) else { return }
        guard let l = try? NWListener(using: PaneLink.params(), on: port) else {
            queue.asyncAfter(deadline: .now() + 2) { self.startListener() }; return
        }
        l.newConnectionHandler = { [weak self] c in self?.adopt(c, .usb) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l else { return }
            if case .failed = st {
                l.cancel(); if self.listener === l { self.listener = nil }
                self.queue.asyncAfter(deadline: .now() + 2) { self.startListener() }
            }
        }
        l.start(queue: queue)
        listener = l
    }
    private func dial() {
        dialItem?.cancel()
        guard active, conn == nil else { return }
        var h = PaneLink.hostSetting.trimmingCharacters(in: .whitespaces)
        var port = PaneLink.port
        if h.isEmpty { h = "pane.local" }
        if let i = h.lastIndex(of: ":"), let p = UInt16(h[h.index(after: i)...]) { port = p; h = String(h[..<i]) }
        let c = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: port)!, using: PaneLink.params())
        adopt(c, .wifi)
        queue.asyncAfter(deadline: .now() + 4) { [weak self, weak c] in
            guard let self, let c, c === self.conn, !self.ready else { return }
            self.drop(c)
        }
    }
    private func scheduleDial(_ s: Double) {
        let w = DispatchWorkItem { [weak self] in self?.dial() }
        dialItem = w
        queue.asyncAfter(deadline: .now() + s, execute: w)
    }
    private func adopt(_ c: NWConnection, _ k: Kind) {
        if let old = conn {
            if k == .wifi { c.cancel(); return }
            drop(old, redial: false)          // a new USB link always replaces the current one
        }
        dialItem?.cancel()
        conn = c; kind = k; ready = false; buf.removeAll(keepingCapacity: true); rd = 0
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                self.ready = true
                DispatchQueue.main.async { self.onOpen?(k) }
                self.receive(c)
            case .failed, .cancelled: self.drop(c)
            case .waiting: self.drop(c)
            default: break
            }
        }
        c.start(queue: queue)
    }
    private func drop(_ c: NWConnection, redial: Bool = true) {
        guard c === conn else { c.cancel(); return }
        c.stateUpdateHandler = nil
        c.cancel()
        let was = ready
        conn = nil; ready = false
        if was { DispatchQueue.main.async { self.onClose?() } }
        if redial && active { scheduleDial(was ? 0.3 : 1.5) }
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty { self.buf.append(contentsOf: data); self.parse() }
            if done || err != nil { self.drop(c); return }
            self.receive(c)
        }
    }
    private func parse() {
        while true {
            let avail = buf.count - rd
            if avail < 2 { break }
            let b0 = buf[rd], b1 = buf[rd + 1]
            var len = Int(b1 & 0x7f), o = 2
            if len == 126 {
                if avail < 4 { break }
                len = Int(buf[rd + 2]) << 8 | Int(buf[rd + 3]); o = 4
            } else if len == 127 {
                if avail < 10 { break }
                len = 0; for i in 0..<8 { len = len << 8 | Int(buf[rd + 2 + i]) }; o = 10
            }
            let masked = b1 & 0x80 != 0
            if masked { o += 4 }
            if avail < o + len { break }
            var payload = Array(buf[(rd + o)..<(rd + o + len)])
            if masked { for i in 0..<payload.count { payload[i] ^= buf[rd + o - 4 + (i & 3)] } }
            rd += o + len
            let op = b0 & 0x0f
            if op == 9 { if let c = conn { c.send(content: PaneLink.frame(10, payload), completion: .idempotent) } }
            else if op == 8 { if let c = conn { drop(c) }; return }
            else if op == 1 || op == 2 { onMessage?(op, payload) }
        }
        if rd > 0 && (rd == buf.count || rd > 1 << 20) { buf.removeFirst(rd); rd = 0 }
    }
}
