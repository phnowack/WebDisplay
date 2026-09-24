import UIKit
import AVFoundation
import ImageIO
import VideoToolbox

enum Theme {
    static let ink = UIColor.black
    static let paper = UIColor.white
    static let fill = UIColor(red: 0xfd / 255.0, green: 0xf0 / 255.0, blue: 0xe2 / 255.0, alpha: 1)
    static let line = UIColor(red: 0xf0 / 255.0, green: 0xd8 / 255.0, blue: 0xbd / 255.0, alpha: 1)
    static let dot = UIColor(red: 0xe8 / 255.0, green: 0x95 / 255.0, blue: 0x5a / 255.0, alpha: 1)
    static let hair = UIColor(white: 0.9, alpha: 1)
    static let mute = UIColor(white: 0.42, alpha: 1)
}

struct StreamCfg { var w: Int; var h: Int; var hevc: Bool; var mode: Int; var cs: CGFloat; var fps: Int }

final class StageController: UIViewController {
    let link = PaneLink()
    private let video = AVSampleBufferDisplayLayer()
    private let surface = Surface()
    private let cursor = CALayer()
    private let hello = HelloView()
    private let menu = MenuView()
    private var cfg: StreamCfg?
    private(set) var fit = (s: CGFloat(1), ox: CGFloat(0), oy: CGFloat(0))
    private var sentWH = ""
    private var connected = false
    private var cur = (x: CGFloat(0), y: CGFloat(0), w: CGFloat(1), h: CGFloat(1), vis: false)
    private var displayLink: CADisplayLink?
    private var helloTimer: Timer?

    // link-queue state
    private let annexB = AnnexB()
    private var needKey = true
    private var vIn = 0
    private var mode = 0
    private let patchQ = DispatchQueue(label: "pane.patch", qos: .userInitiated)

    // main-thread state
    private var vSeq = 0
    private var recentClears: [(seq: Int, rects: [CGRect])] = []
    private var shown = 0, shownSec = 0
    private var hostFps = 0, hostKbps = 0

    override func loadView() {
        let v = StageView(); v.ctl = self; view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        video.videoGravity = .resize
        video.backgroundColor = UIColor.black.cgColor
        cursor.anchorPoint = .zero
        cursor.magnificationFilter = .nearest
        cursor.isHidden = true
        for l in [video, cursor] as [CALayer] { l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "transform": NSNull()] }
        view.layer.addSublayer(video)
        view.layer.addSublayer(surface.layer)
        view.layer.addSublayer(cursor)

        hello.frame = view.bounds; hello.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hello)
        menu.isHidden = true
        view.addSubview(menu)
        menu.onKey = { [weak self] in self?.requestKey() }
        menu.onReconnect = { [weak self] in self?.menu.isHidden = true; self?.link.reconnect() }
        menu.onClose = { [weak self] in self?.menu.isHidden = true }

        link.onMessage = { [weak self] op, p in self?.onMessage(op, p) }
        link.onOpen = { [weak self] kind in
            guard let self else { return }
            self.connected = true
            self.hello.setState("Linked over \(kind.rawValue) — waiting for stream…", link: kind.rawValue)
            self.menu.linkText = kind.rawValue
            self.sendHello()
        }
        link.onClose = { [weak self] in
            guard let self else { return }
            self.connected = false; self.cfg = nil
            self.cursor.isHidden = true
            self.hello.isHidden = false
            self.hello.setState("Waiting for laptop…", link: "—")
            self.menu.linkText = "—"
        }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        view.addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        view.addGestureRecognizer(scroll)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickSecond() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        let (w, h) = physRes()
        hello.setDevice("\(w) × \(h)", hz: "\(maxHz()) Hz")
        startDisplayLink()
        link.resume()
    }

    @objc private func appActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        startDisplayLink(); link.resume()
    }
    @objc private func appBackground() {
        displayLink?.invalidate(); displayLink = nil
        link.pause()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let d = CADisplayLink(target: self, selector: #selector(onVsync))
        let hz = Float(maxHz())
        d.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, hz), maximum: hz, preferred: hz)
        d.add(to: .main, forMode: .common)
        displayLink = d
    }
    @objc private func onVsync() { surface.commit() }

    private func maxHz() -> Int { view.window?.windowScene?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond }

    func physRes() -> (Int, Int) {
        let sc = view.window?.windowScene?.screen ?? UIScreen.main
        let nb = sc.nativeBounds
        let a = Int(nb.width), b = Int(nb.height)
        let land = view.bounds.width >= view.bounds.height
        return land ? (max(a, b), min(a, b)) : (min(a, b), max(a, b))
    }

    private func sendHello() {
        let (w, h) = physRes()
        sentWH = "\(w)x\(h)"
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        link.send(json: ["t": "hello", "w": w, "h": h, "hz": maxHz(), "avc": 1, "hevc": hevc ? 1 : 0,
                         "dpr": Double(view.window?.windowScene?.screen.nativeScale ?? 2), "app": 1])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStage()
        let b = view.bounds
        menu.frame = CGRect(x: b.width - 316, y: 16, width: 300, height: menu.preferredHeight)
        helloTimer?.invalidate()
        helloTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, self.connected else { return }
            let (w, h) = self.physRes()
            if "\(w)x\(h)" != self.sentWH { self.sendHello() }
            self.hello.setDevice("\(w) × \(h)", hz: "\(self.maxHz()) Hz")
        }
    }

    private func layoutStage() {
        guard let c = cfg else { return }
        let b = view.bounds
        let s = min(b.width / CGFloat(c.w), b.height / CGFloat(c.h))
        let px = view.window?.windowScene?.screen.scale ?? 2       // snap to physical pixels: native stream stays 1:1 crisp
        fit = (s, ((b.width - CGFloat(c.w) * s) / 2 * px).rounded() / px, ((b.height - CGFloat(c.h) * s) / 2 * px).rounded() / px)
        quiet {
            video.frame = CGRect(x: fit.ox, y: fit.oy, width: CGFloat(c.w) * s, height: CGFloat(c.h) * s)
            surface.layer.position = CGPoint(x: fit.ox, y: fit.oy)
            surface.layer.transform = CATransform3DMakeScale(s, s, 1)
        }
        placeCursor()
    }

    // MARK: protocol (link queue)
    private func onMessage(_ op: UInt8, _ p: [UInt8]) {
        if op == 1 { onText(p); return }
        guard let t = p.first else { return }
        func u16(_ o: Int) -> Int { Int(p[o]) | Int(p[o + 1]) << 8 }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }
        switch t {
        case 1 where p.count >= 8:                                     // video
            let key = p[1] & 1 == 1, n = u16(2)
            let ts = UInt32(p[4]) | UInt32(p[5]) << 8 | UInt32(p[6]) << 16 | UInt32(p[7]) << 24
            let off = 8 + n * 8
            guard p.count > off else { return }
            if needKey && !key { return }
            needKey = false
            var rects: [CGRect] = []
            if mode == 1 { for i in 0..<n { let o = 8 + i * 8; rects.append(CGRect(x: u16(o), y: u16(o + 2), width: u16(o + 4), height: u16(o + 6))) } }
            guard let sb = annexB.sample(p, from: off, key: key, ms: ts) else { return }
            vIn += 1
            let seq = vIn
            DispatchQueue.main.async { self.showVideo(sb, rects, seq) }
        case 2 where p.count > 10:                                      // still patch
            let r = CGRect(x: u16(2), y: u16(4), width: u16(6), height: u16(8))
            let data = Data(p[10...]), seq = vIn
            patchQ.async {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
                DispatchQueue.main.async { self.showPatch(img, r, seq) }
            }
        case 3 where p.count >= 6:                                      // cursor position (top-left of shape)
            let vis = p[1] != 0, x = CGFloat(i16(2)), y = CGFloat(i16(4))
            DispatchQueue.main.async { self.cur.vis = vis; self.cur.x = x; self.cur.y = y; self.placeCursor() }
        case 4 where p.count >= 10:                                     // cursor shape RGBA
            let w = u16(2), h = u16(4)
            guard w > 0, h > 0, p.count >= 10 + w * h * 4,
                  let prov = CGDataProvider(data: Data(p[10..<(10 + w * h * 4)]) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
            DispatchQueue.main.async { self.cursor.contents = img; self.cur.w = CGFloat(w); self.cur.h = CGFloat(h); self.placeCursor() }
        default: break
        }
    }

    private func onText(_ p: [UInt8]) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(p)) as? [String: Any], let t = o["t"] as? String else { return }
        func num(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        if t == "cfg" {
            let c = StreamCfg(w: Int(num("w")), h: Int(num("h")), hevc: (o["codec"] as? String ?? "").hasPrefix("hvc"),
                              mode: Int(num("mode")), cs: CGFloat(num("cs") > 0 ? num("cs") : 1), fps: Int(num("fps")))
            annexB.reset(hevc: c.hevc); needKey = true; vIn = 0; mode = c.mode
            DispatchQueue.main.async { self.setup(c) }
        } else if t == "st" {
            let f = Int(num("fps")), k = Int(num("kbps"))
            DispatchQueue.main.async { self.hostFps = f; self.hostKbps = k }
        }
    }

    // MARK: rendering (main)
    private func setup(_ c: StreamCfg) {
        cfg = c
        vSeq = 0; recentClears = []
        renderReset()
        quiet { video.isHidden = c.mode == 2 }
        surface.reset(w: c.w, h: c.h, opaque: c.mode == 2)
        hello.isHidden = true
        menu.streamText = "\(c.w) × \(c.h) @ \(c.fps)"
        menu.codecText = (c.hevc ? "HEVC" : "H.264") + " · " + ["Video", "Hybrid", "Tiles"][max(0, min(2, c.mode))]
        layoutStage()
    }

    private func showVideo(_ sb: CMSampleBuffer, _ rects: [CGRect], _ seq: Int) {
        guard cfg != nil else { return }
        if !renderEnqueue(sb) { requestKey(); return }
        vSeq = seq; shown += 1
        if !rects.isEmpty {
            surface.clear(rects)
            recentClears.append((seq, rects)); if recentClears.count > 64 { recentClears.removeFirst() }
        }
    }

    private func showPatch(_ img: CGImage, _ r: CGRect, _ seq: Int) {
        guard let c = cfg else { return }
        if c.mode == 2 { surface.add(img, r); shown += 1; return }
        for cl in recentClears where cl.seq > seq { for x in cl.rects where x.intersects(r) { return } }   // newer video already covers it
        surface.add(img, r)
    }

    // iOS 17+ (incl. 18): the layer's sampleBufferRenderer; older: the layer itself
    private func renderEnqueue(_ sb: CMSampleBuffer) -> Bool {
        if #available(iOS 17.0, *) {
            let r = video.sampleBufferRenderer
            if r.status == .failed { r.flush(); return false }
            r.enqueue(sb)
        } else {
            if video.status == .failed { video.flush(); return false }
            video.enqueue(sb)
        }
        return true
    }
    private func renderReset() {
        if #available(iOS 17.0, *) { video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
        else { video.flushAndRemoveImage() }
    }

    private func placeCursor() {
        guard let c = cfg, cur.vis else { cursor.isHidden = true; return }
        let k = fit.s * c.cs
        quiet {
            cursor.isHidden = false
            cursor.frame = CGRect(x: fit.ox + cur.x * fit.s, y: fit.oy + cur.y * fit.s, width: cur.w * k, height: cur.h * k)
        }
    }

    private func requestKey() {
        link.queue.async { self.needKey = true }
        link.send(json: ["t": "key"])
    }

    private func tickSecond() {
        shownSec = shown; shown = 0
        menu.fpsText = "\(shownSec) / host \(hostFps) fps"
        menu.kbpsText = String(format: "%.1f Mbit/s", Double(hostKbps) / 1000)
        if connected { link.send(json: ["t": "s", "fps": shownSec, "q": 0]) }
    }

    // MARK: input
    func norm(_ p: CGPoint) -> (Double, Double)? {
        guard let c = cfg else { return nil }
        let x = (p.x - fit.ox) / (CGFloat(c.w) * fit.s), y = (p.y - fit.oy) / (CGFloat(c.h) * fit.s)
        return (Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1)))
    }
    /// k: 0 move, 1 down, 2 up — b: 1 left, 2 right
    func ptr(_ k: Int, _ p: CGPoint, b: Int = 1) {
        guard let (x, y) = norm(p) else { return }
        link.send(json: ["t": "p", "k": k, "x": x, "y": y, "b": b])
    }
    func wheel(_ p: CGPoint, _ dy: CGFloat) {
        guard let (x, y) = norm(p) else { return }
        link.send(json: ["t": "w", "x": x, "y": y, "dy": Double(dy)])
    }
    func toggleMenu() { menu.isHidden.toggle(); view.bringSubviewToFront(menu) }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        if g.state == .began || g.state == .changed { ptr(0, g.location(in: view)) }
    }
    private var lastScroll: CGFloat = 0
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view).y
        if g.state == .began { lastScroll = 0 }
        let dy = t - lastScroll
        if abs(dy) >= 1 { wheel(g.location(in: view), dy); lastScroll = t }
    }
}

/// Touch rules (same as the web client): 1 finger = left click / drag, hold 0.45 s = right click,
/// 2 fingers = scroll, 3-finger tap = menu. Pencil, trackpad and mouse act immediately.
final class StageView: UIView {
    weak var ctl: StageController?
    private struct One { let t: UITouch; let start: CGPoint; var down = false; var done = false }
    private var direct = Set<UITouch>()
    private var one: One?
    private var hold: Timer?
    private var twoY: CGFloat?
    private var threeAt: CFTimeInterval = 0
    private var buttons: [UITouch: Int] = [:]

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true }
    required init?(coder: NSCoder) { fatalError() }

    private func centroidY() -> CGFloat {
        guard !direct.isEmpty else { return 0 }
        return direct.reduce(0) { $0 + $1.location(in: self).y } / CGFloat(direct.count)
    }
    private func cancelOne(_ p: CGPoint) {
        hold?.invalidate()
        if let o = one, o.down, !o.done { ctl?.ptr(2, p) }
        one = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if t.type != .direct {
                let b = (event?.buttonMask.contains(.secondary) ?? false) ? 2 : 1
                buttons[t] = b
                ctl?.ptr(0, p); ctl?.ptr(1, p, b: b)
                continue
            }
            direct.insert(t)
            if direct.count == 1 {
                ctl?.ptr(0, p)
                one = One(t: t, start: p)
                hold?.invalidate()
                hold = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    guard let self, let o = self.one, !o.down else { return }
                    self.one?.done = true
                    self.ctl?.ptr(1, o.start, b: 2); self.ctl?.ptr(2, o.start, b: 2)
                }
            } else {
                cancelOne(p)
                if direct.count == 2 { twoY = centroidY() }
                if direct.count == 3 { threeAt = CACurrentMediaTime() }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var wheeled = false
        for t in touches {
            let p = t.location(in: self)
            if t.type != .direct { ctl?.ptr(0, p); continue }
            guard direct.contains(t) else { continue }
            if let o = one, o.t === t, !o.done {
                if !o.down && hypot(p.x - o.start.x, p.y - o.start.y) > 8 {
                    hold?.invalidate(); one?.down = true
                    ctl?.ptr(0, o.start); ctl?.ptr(1, o.start)
                }
                ctl?.ptr(0, p)
            } else if !wheeled, direct.count == 2, let y0 = twoY {
                let y = centroidY(), dy = y - y0
                if abs(dy) >= 2 { ctl?.wheel(p, dy); twoY = y }
                wheeled = true
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            let p = t.location(in: self)
            if t.type != .direct { ctl?.ptr(2, p, b: buttons.removeValue(forKey: t) ?? 1); continue }
            direct.remove(t)
            if let o = one, o.t === t {
                hold?.invalidate()
                if !o.done { if !o.down { ctl?.ptr(1, p) }; ctl?.ptr(2, p) }
                one = nil
            }
        }
        if direct.count < 2 { twoY = nil }
        if direct.isEmpty {
            if threeAt > 0 && CACurrentMediaTime() - threeAt < 0.4 { ctl?.toggleMenu() }
            threeAt = 0
        }
    }
}

// MARK: - UI (App Framework: black/white, light-orange accent, squared dot wordmark, hairlines, 16 pt panels)

func wordmark(_ size: CGFloat) -> UIView {
    let v = UIView()
    let l = UILabel(); l.text = "Pane"; l.font = .systemFont(ofSize: size, weight: .semibold); l.textColor = Theme.ink
    let d = UIView(); d.backgroundColor = Theme.dot
    for x in [l, d] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
    NSLayoutConstraint.activate([
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor), l.topAnchor.constraint(equalTo: v.topAnchor), l.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        d.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: size * 0.04),
        d.bottomAnchor.constraint(equalTo: l.lastBaselineAnchor),
        d.widthAnchor.constraint(equalToConstant: size * 0.2), d.heightAnchor.constraint(equalToConstant: size * 0.2),
        v.trailingAnchor.constraint(equalTo: d.trailingAnchor),
    ])
    return v
}

func infoRow(_ title: String, _ value: UILabel, size: CGFloat = 18) -> UIView {
    let t = UILabel(); t.text = title; t.font = .systemFont(ofSize: size); t.textColor = Theme.ink
    value.font = .systemFont(ofSize: size); value.textColor = Theme.mute; value.textAlignment = .right
    let row = UIStackView(arrangedSubviews: [t, value]); row.distribution = .fill
    let wrap = UIView()
    let line = UIView(); line.backgroundColor = Theme.hair
    for x in [row, line] { x.translatesAutoresizingMaskIntoConstraints = false; wrap.addSubview(x) }
    NSLayoutConstraint.activate([
        line.topAnchor.constraint(equalTo: wrap.topAnchor), line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
        line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor), line.heightAnchor.constraint(equalToConstant: 1),
        row.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
        row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor), row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
    ])
    return wrap
}

final class HelloView: UIView {
    private let state = UILabel(), res = UILabel(), hz = UILabel(), linkL = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.paper
        state.font = .systemFont(ofSize: 22); state.textColor = Theme.ink; state.numberOfLines = 0
        state.text = "Waiting for laptop…"
        let hint = UILabel()
        hint.numberOfLines = 0; hint.font = .systemFont(ofSize: 18); hint.textColor = Theme.ink
        hint.text = "Start Pane.exe on the laptop, then plug in the USB cable — or join the same Wi-Fi. Allow Local Network when asked. Three-finger tap opens the menu (host address, reconnect)."
        let panel = UIView(); panel.backgroundColor = Theme.fill; panel.layer.cornerRadius = 16
        panel.layer.borderWidth = 1; panel.layer.borderColor = Theme.line.cgColor
        hint.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14), hint.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            hint.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16), hint.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
        ])
        let mark = wordmark(30)
        let markRow = UIStackView(arrangedSubviews: [mark, UIView()])
        let stack = UIStackView(arrangedSubviews: [markRow, state, infoRow("Display", res), infoRow("Refresh", hz), infoRow("Link", linkL), panel])
        stack.axis = .vertical; stack.spacing = 12
        stack.setCustomSpacing(24, after: markRow); stack.setCustomSpacing(16, after: state); stack.setCustomSpacing(16, after: stack.arrangedSubviews[4])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520).withPriority(.defaultHigh),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
        linkL.text = "—"
    }
    required init?(coder: NSCoder) { fatalError() }
    func setState(_ s: String, link: String) { state.text = s; linkL.text = link }
    func setDevice(_ r: String, hz h: String) { res.text = r; hz.text = h }
}

final class MenuView: UIView, UITextFieldDelegate {
    var onKey: (() -> Void)?, onReconnect: (() -> Void)?, onClose: (() -> Void)?
    private let stream = UILabel(), codec = UILabel(), fps = UILabel(), kbps = UILabel(), linkL = UILabel()
    private let host = UITextField()
    var streamText: String { get { stream.text ?? "" } set { stream.text = newValue } }
    var codecText: String { get { codec.text ?? "" } set { codec.text = newValue } }
    var fpsText: String { get { fps.text ?? "" } set { fps.text = newValue } }
    var kbpsText: String { get { kbps.text ?? "" } set { kbps.text = newValue } }
    var linkText: String { get { linkL.text ?? "" } set { linkL.text = newValue } }
    let preferredHeight: CGFloat = 420

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.paper; layer.cornerRadius = 16; layer.borderWidth = 1; layer.borderColor = Theme.hair.cgColor
        for l in [stream, codec, fps, kbps, linkL] { l.text = "—" }
        host.placeholder = "pane.local"; host.text = PaneLink.hostSetting
        host.font = .systemFont(ofSize: 18); host.autocapitalizationType = .none; host.autocorrectionType = .no
        host.keyboardType = .URL; host.returnKeyType = .done; host.delegate = self; host.textAlignment = .right
        host.textColor = Theme.ink
        let hostRow = infoRow("Laptop", UILabel())
        if let row = hostRow.subviews.first as? UIStackView, let old = row.arrangedSubviews.last {
            row.removeArrangedSubview(old); old.removeFromSuperview(); row.addArrangedSubview(host)
        }
        let key = button("square.dashed", "Keyframe", featured: false) { [weak self] in self?.onKey?() }
        let close = button("xmark", "Close", featured: false) { [weak self] in self?.endEditing(true); self?.onClose?() }
        let re = button("arrow.clockwise", "Reconnect", featured: true) { [weak self] in self?.endEditing(true); self?.onReconnect?() }
        let btns = UIStackView(arrangedSubviews: [UIView(), key, close, re]); btns.spacing = 8
        let stack = UIStackView(arrangedSubviews: [UIStackView(arrangedSubviews: [wordmark(22), UIView()]),
                                                   infoRow("Link", linkL), infoRow("Stream", stream), infoRow("Codec", codec),
                                                   infoRow("Frames", fps), infoRow("Bitrate", kbps), hostRow, btns])
        stack.axis = .vertical; stack.spacing = 0; stack.setCustomSpacing(12, after: stack.arrangedSubviews[0]); stack.setCustomSpacing(16, after: hostRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ label: String, featured: Bool, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .light)), for: .normal)
        b.accessibilityLabel = label
        b.tintColor = featured ? Theme.paper : Theme.ink
        b.backgroundColor = featured ? Theme.ink : Theme.paper
        b.layer.cornerRadius = 22; b.layer.borderWidth = 1; b.layer.borderColor = (featured ? Theme.ink : Theme.hair).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 44).isActive = true
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    func textFieldShouldReturn(_ t: UITextField) -> Bool { t.resignFirstResponder(); return true }
    func textFieldDidEndEditing(_ t: UITextField) {
        let v = (t.text ?? "").trimmingCharacters(in: .whitespaces)
        if v != PaneLink.hostSetting { PaneLink.hostSetting = v; onReconnect?() }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}
