import AppKit
import WebKit

// MARK: - Terminal

/// Hosts a terminal surface.
///
/// The surface always renders at 100% (its world size) and the canvas zoom is
/// applied as a visual scale via bounds scaling. Re-rendering at each zoom
/// would change how many whole-pixel cells fit, so the grid would reflow and
/// text would jump around; keeping the grid fixed makes zoom perfectly stable.
final class TerminalTileContent: NSView, TileContent {
    let surface: TerminalSurfaceView
    private let host = FlippedView()
    private var zoom: CGFloat = 1

    override var isFlipped: Bool { true }

    init(surface: TerminalSurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
        host.addSubview(surface)
        surface.zoom = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { surface }

    func apply(zoom: CGFloat, live: Bool) {
        self.zoom = zoom
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Content size at 100%, rounded so floating-point noise from the zoom
    /// division never changes the pixel size (and so the grid).
    private var worldSize: CGSize {
        let z = max(zoom, 0.01)
        func r(_ v: CGFloat) -> CGFloat { (v / z * 2).rounded() / 2 }
        return CGSize(width: r(bounds.width), height: r(bounds.height))
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = worldSize
        guard w.width > 0, w.height > 0 else { return }
        host.setBoundsSize(w)
        if surface.frame.size != w { surface.frame = CGRect(origin: .zero, size: w) }
    }

    func setVisible(_ visible: Bool) {
        host.isHidden = !visible
        surface.setOccluded(!visible)
    }

    func willClose() { surface.destroy() }
}

// MARK: - Browser

final class BrowserTileContent: NSView, TileContent, WKNavigationDelegate, NSTextFieldDelegate {
    let web: WKWebView
    private let bar = FlippedView()
    private let urlField = NSTextField()
    private let back = NSButton()
    private let reload = NSButton()
    private var zoom: CGFloat = 1
    var onURLChange: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(url: String) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: .zero)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { web.isInspectable = true }
        addSubview(web)
        addSubview(bar)
        for (b, sym, label, sel) in [(back, "chevron.left", "Back", #selector(goBack)),
                                     (reload, "arrow.clockwise", "Reload", #selector(doReload))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.contentTintColor = Theme.text2
            b.target = self
            b.action = sel
            b.setAccessibilityLabel(label)
            bar.addSubview(b)
        }
        urlField.isBordered = false
        urlField.focusRingType = .none
        urlField.drawsBackground = false
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.delegate = self
        urlField.placeholderString = "localhost:3000"
        urlField.wantsLayer = true
        bar.addSubview(urlField)
        load(url)
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { web }

    func load(_ s: String) {
        var str = s.trimmingCharacters(in: .whitespaces)
        if !str.contains("://") {
            str = (str.hasPrefix("localhost") || str.hasPrefix("127.") || str.first?.isNumber == true ? "http://" : "https://") + str
        }
        guard let u = URL(string: str) else { return }
        urlField.stringValue = s
        web.load(URLRequest(url: u))
    }

    func apply(zoom: CGFloat, live: Bool) {
        self.zoom = zoom
        web.pageZoom = zoom
        urlField.font = .monospacedSystemFont(ofSize: 12 * zoom, weight: .regular)
        for b in [back, reload] { b.image = b.image?.withSymbolConfiguration(.init(pointSize: 12 * zoom, weight: .medium)) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = 40 * zoom
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let s = 26 * zoom
        back.frame = NSRect(x: 10 * zoom, y: (h - s) / 2, width: s, height: s)
        reload.frame = NSRect(x: back.frame.maxX + 2 * zoom, y: (h - s) / 2, width: s, height: s)
        let fh = 28 * zoom
        urlField.frame = NSRect(x: reload.frame.maxX + 8 * zoom, y: (h - fh) / 2 + 5 * zoom, width: bounds.width - reload.frame.maxX - 24 * zoom, height: fh)
        web.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.layer?.backgroundColor = Theme.tile.cgColor
        }
    }

    @objc private func goBack() { web.goBack() }
    @objc private func doReload() { web.reload() }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement { load(urlField.stringValue) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url?.absoluteString {
            urlField.stringValue = u.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
            onURLChange?(u)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let html = """
        <html><body style="font: 14px -apple-system; color: #585B63; display:flex; align-items:center; justify-content:center; height:90vh">
        <div style="text-align:center"><div style="font-weight:600; color:#1B1C1F; margin-bottom:6px">Can't reach \(urlField.stringValue)</div>
        <div>Is the dev server running? This tile retries when you press reload.</div></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Text files (note & code)

/// Live-reloading text editor for a file. Notes get light markdown styling,
/// code gets monospace + simple highlighting. Zoom uses scroll-view
/// magnification so text stays crisp.
final class TextFileTileContent: NSView, TileContent, NSTextViewDelegate {
    let path: String
    let markdown: Bool
    private let host = FlippedView()
    private var zoom: CGFloat = 1
    private let scroll = NSScrollView()
    private let textView: NSTextView
    private var lastLoaded: Date?
    private var saveWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var suppressSave = false

    override var isFlipped: Bool { true }

    init(path: String, markdown: Bool) {
        self.path = path
        self.markdown = markdown
        let tv = NSTextView(frame: .zero)
        textView = tv
        super.init(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: markdown ? 26 : 14, height: 14)
        tv.drawsBackground = false
        tv.delegate = self
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(host)
        host.addSubview(scroll)
        reload()
        watch()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { watcher?.cancel() }

    var focusTarget: NSView? { textView }

    func apply(zoom: CGFloat, live: Bool) {
        self.zoom = zoom
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Lay out at 100% and let the canvas zoom scale it visually.
        host.frame = bounds
        let world = CGSize(width: bounds.width / max(zoom, 0.01), height: bounds.height / max(zoom, 0.01))
        host.setBoundsSize(world)
        scroll.frame = CGRect(origin: .zero, size: world)
        TextFileTileContent.fit(textView, in: scroll)
    }

    /// Size a text view to its scroll view's visible width (which already
    /// accounts for magnification) so it wraps and draws correctly.
    static func fit(_ tv: NSTextView, in scroll: NSScrollView) {
        let clip = scroll.contentView.bounds.size
        tv.minSize = NSSize(width: 0, height: clip.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.containerSize = NSSize(width: clip.width, height: CGFloat.greatestFiniteMagnitude)
        if tv.frame.width != clip.width { tv.setFrameSize(NSSize(width: clip.width, height: max(tv.frame.height, clip.height))) }
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            tv.setFrameSize(NSSize(width: clip.width, height: max(used, clip.height)))
        }
    }

    private func reload() {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
            textView.string = "Couldn't read \(path)"
            return
        }
        if s == textView.string { return }
        suppressSave = true
        let sel = textView.selectedRanges
        textView.string = s
        restyle()
        TextFileTileContent.fit(textView, in: scroll)
        textView.selectedRanges = sel.filter { $0.rangeValue.upperBound <= (s as NSString).length }.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : sel
        suppressSave = false
        lastLoaded = Date()
    }

    private func watch() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.rename) || ev.contains(.delete) {
                // Editors and agents often save by replacing the file.
                src.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reload(); self.watch() }
            } else {
                self.reload()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func textDidChange(_ notification: Notification) {
        restyle()
        TextFileTileContent.fit(textView, in: scroll)
        guard !suppressSave else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.textView.string.write(toFile: self.path, atomically: true, encoding: .utf8)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    override func viewDidChangeEffectiveAppearance() { restyle() }

    private func restyle() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let s = storage.string as NSString
        effectiveAppearance.performAsCurrentDrawingAppearance {
            storage.beginEditing()
            if markdown {
                let body = NSFont.systemFont(ofSize: 14)
                let para = NSMutableParagraphStyle()
                para.lineSpacing = 4
                storage.setAttributes([.font: body, .foregroundColor: Theme.text, .paragraphStyle: para], range: full)
                s.enumerateSubstrings(in: full, options: .byLines) { line, r, _, _ in
                    guard let line else { return }
                    if line.hasPrefix("# ") { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 24, weight: .bold), range: r) }
                    else if line.hasPrefix("## ") { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 18, weight: .semibold), range: r) }
                    else if line.hasPrefix("### ") { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .semibold), range: r) }
                    else if line.hasPrefix("- [x]") || line.hasPrefix("* [x]") {
                        storage.addAttributes([.foregroundColor: Theme.text3, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: r)
                    } else if line.hasPrefix(">") {
                        storage.addAttribute(.foregroundColor, value: Theme.text2, range: r)
                    }
                    if line.hasPrefix("#") {
                        let hashes = line.prefix { $0 == "#" }.count
                        storage.addAttribute(.foregroundColor, value: Theme.text3, range: NSRange(location: r.location, length: min(hashes + 1, r.length)))
                    }
                }
                Self.apply(regex: "`[^`\\n]+`", in: storage, attrs: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .backgroundColor: Theme.pill])
                Self.apply(regex: "\\*\\*[^*\\n]+\\*\\*", in: storage, attrs: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
            } else {
                storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Theme.text], range: full)
                let kw = "\\b(func|fn|let|var|const|pub|struct|enum|impl|class|interface|type|return|if|else|for|while|match|switch|case|import|export|from|use|async|await|self|Self|true|false|nil|null|None|def|in|mut|try|catch|throw|new|static|private|public)\\b"
                Self.apply(regex: kw, in: storage, attrs: [.foregroundColor: Theme.dynamic(light: Theme.hex(0x7C4DDB), dark: Theme.hex(0xC49BFF))])
                Self.apply(regex: "\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'", in: storage, attrs: [.foregroundColor: Theme.green])
                Self.apply(regex: "\\b\\d+(\\.\\d+)?\\b", in: storage, attrs: [.foregroundColor: Theme.dynamic(light: Theme.hex(0xB26A00), dark: Theme.hex(0xF5C451))])
                Self.apply(regex: "(//|#)[^\\n]*", in: storage, attrs: [.foregroundColor: Theme.text3])
            }
            storage.endEditing()
        }
        textView.typingAttributes = [.font: markdown ? NSFont.systemFont(ofSize: 14) : NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                     .foregroundColor: Theme.text]
        textView.insertionPointColor = Theme.text
    }

    static func apply(regex: String, in storage: NSTextStorage, attrs: [NSAttributedString.Key: Any]) {
        guard let re = try? NSRegularExpression(pattern: regex) else { return }
        for m in re.matches(in: storage.string, range: NSRange(location: 0, length: storage.length)) {
            storage.addAttributes(attrs, range: m.range)
        }
    }
}

// MARK: - Image

final class ImageTileContent: NSView, TileContent {
    private let imageView = NSImageView()
    override var isFlipped: Bool { true }

    init(path: String) {
        super.init(frame: .zero)
        imageView.image = NSImage(contentsOfFile: path)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }
    var focusTarget: NSView? { nil }
    func apply(zoom: CGFloat, live: Bool) {}
    override func layout() { super.layout(); imageView.frame = bounds.insetBy(dx: 12, dy: 12) }
}

// MARK: - Diff

/// Live `git diff` of a worktree against its base, with PR / discard actions.
final class DiffTileContent: NSView, TileContent {
    let repo: String
    private let host = FlippedView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let footer = FlippedView()
    private let summary = NSTextField(labelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let openPR = NSButton(title: "Open PR", target: nil, action: nil)
    private var timer: Timer?
    private var zoom: CGFloat = 1
    var onOpenPR: (() -> Void)?

    override var isFlipped: Bool { true }

    init(repo: String) {
        self.repo = repo
        super.init(frame: .zero)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(host)
        host.addSubview(scroll)
        host.addSubview(footer)
        footer.wantsLayer = true
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Theme.text3
        footer.addSubview(summary)
        for b in [refresh, openPR] { b.bezelStyle = .push; b.controlSize = .small; footer.addSubview(b) }
        refresh.target = self; refresh.action = #selector(load)
        openPR.target = self; openPR.action = #selector(prClicked)
        openPR.keyEquivalent = ""
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.load() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    var focusTarget: NSView? { textView }
    func willClose() { timer?.invalidate() }

    func apply(zoom: CGFloat, live: Bool) {
        self.zoom = zoom
        needsLayout = true
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        let fh: CGFloat = 44
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - fh))
        footer.frame = NSRect(x: 0, y: h - fh, width: w, height: fh)
        summary.frame = NSRect(x: 16, y: (fh - 16) / 2, width: w * 0.5, height: 16)
        openPR.frame = NSRect(x: w - 100, y: (fh - 24) / 2, width: 88, height: 24)
        refresh.frame = NSRect(x: openPR.frame.minX - 86, y: openPR.frame.minY, width: 80, height: 24)
        TextFileTileContent.fit(textView, in: scroll)
    }

    @objc private func prClicked() { onOpenPR?() }

    @objc func load() {
        let repo = self.repo
        DispatchQueue.global(qos: .utility).async {
            let base = Git.baseRef(repo) ?? "HEAD"
            let diff = Git.run(["diff", base, "--no-color", "--no-ext-diff"], in: repo) ?? ""
            let untracked = Git.run(["ls-files", "--others", "--exclude-standard"], in: repo) ?? ""
            DispatchQueue.main.async { self.render(diff: diff, untracked: untracked, base: base) }
        }
    }

    private func render(diff: String, untracked: String, base: String) {
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var adds = 0, dels = 0, files = 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: Theme.text]
                if l.hasPrefix("diff --git") {
                    files += 1
                    let name = l.components(separatedBy: " b/").last ?? l
                    out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + name + "\n",
                                                  attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text]))
                    continue
                }
                if l.hasPrefix("index ") || l.hasPrefix("--- ") || l.hasPrefix("+++ ") || l.hasPrefix("new file") || l.hasPrefix("deleted file") { continue }
                if l.hasPrefix("@@") { attrs[.foregroundColor] = Theme.text3 }
                else if l.hasPrefix("+") { adds += 1; attrs[.foregroundColor] = Theme.green; attrs[.backgroundColor] = Theme.green.withAlphaComponent(0.08) }
                else if l.hasPrefix("-") { dels += 1; attrs[.foregroundColor] = Theme.red; attrs[.backgroundColor] = Theme.red.withAlphaComponent(0.07) }
                out.append(NSAttributedString(string: l + "\n", attributes: attrs))
            }
            let newFiles = untracked.split(separator: "\n")
            if !newFiles.isEmpty {
                out.append(NSAttributedString(string: "\nUntracked\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text]))
                for f in newFiles { out.append(NSAttributedString(string: "+ \(f)\n", attributes: [.font: mono, .foregroundColor: Theme.green])) }
            }
            if out.length == 0 {
                out.append(NSAttributedString(string: "No changes against \(base).", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.text3]))
            }
        }
        let y = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(out)
        TextFileTileContent.fit(textView, in: scroll)
        scroll.contentView.scroll(to: y)
        summary.stringValue = "\(files) files · +\(adds) −\(dels) vs \(base)"
    }
}

// MARK: - Sub-agent

/// A small read-only tile for a Claude Code sub-agent (Task tool).
final class SubagentTileContent: NSView, TileContent {
    private let label = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text2
        label.maximumNumberOfLines = 3
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    var focusTarget: NSView? { nil }
    private var zoom: CGFloat = 1
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; label.font = .systemFont(ofSize: 12 * zoom); needsLayout = true }
    func update(tile: Tile) { label.stringValue = tile.statusMessage ?? tile.task ?? "" }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 16 * zoom, dy: 4 * zoom) }
}

// MARK: - Compare (fan-out attempts)

import SwiftUI

/// Side-by-side status of fan-out attempts, with Open diff and Pick.
final class CompareTileContent: NSView, TileContent {
    let tileIDs: [String]
    weak var controller: CanvasController? { didSet { model.controller = controller } }
    private let model = CompareModel()
    private let hostView: NSHostingView<CompareView>
    private var zoom: CGFloat = 1
    private let host = FlippedView()

    override var isFlipped: Bool { true }

    init(tileIDs: [String]) {
        self.tileIDs = tileIDs
        model.tileIDs = tileIDs
        hostView = NSHostingView(rootView: CompareView(model: model))
        super.init(frame: .zero)
        addSubview(host)
        host.addSubview(hostView)
        model.refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { nil }
    func willClose() { model.stop() }
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; needsLayout = true }
    func update(tile: Tile) { model.objectWillChange.send() }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        hostView.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }
}

final class CompareModel: ObservableObject {
    struct Attempt: Identifiable {
        let id: String
        var name: String
        var state: AgentState
        var branch: String?
        var added = 0, removed = 0, files = 0
        var message: String?
    }
    weak var controller: CanvasController?
    var tileIDs: [String] = []
    @Published var attempts: [Attempt] = []
    private var timer: Timer?

    func refresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.load() }
        load()
    }

    func stop() { timer?.invalidate() }

    private func load() {
        let tiles = tileIDs.compactMap { Store.shared.findTile($0)?.tile }
        DispatchQueue.global(qos: .utility).async {
            let list: [Attempt] = tiles.map { t in
                var a = Attempt(id: t.id, name: t.displayName, state: t.state, branch: t.branch, message: t.statusMessage)
                if let wt = t.worktree {
                    let base = Git.baseRef(wt) ?? "HEAD"
                    let out = Git.run(["diff", "--numstat", base], in: wt) ?? ""
                    for line in out.split(separator: "\n") {
                        let p = line.split(separator: "\t")
                        if p.count >= 2 { a.added += Int(p[0]) ?? 0; a.removed += Int(p[1]) ?? 0; a.files += 1 }
                    }
                    a.files += (Git.run(["ls-files", "--others", "--exclude-standard"], in: wt) ?? "").split(separator: "\n").count
                }
                return a
            }
            DispatchQueue.main.async { self.attempts = list }
        }
    }
}

struct CompareView: View {
    @ObservedObject var model: CompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick the best attempt. Each one worked on its own branch.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.attempts) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(ns: Theme.color(for: a.state))).frame(width: 8, height: 8)
                            Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        Text(a.state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text("+\(a.added)").foregroundStyle(Color(ns: Theme.green))
                            Text("−\(a.removed)").foregroundStyle(Color(ns: Theme.red))
                            Text("\(a.files) files").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        if let m = a.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Button("Open diff") { model.controller?.newDiff(for: a.id) }
                            Button("Pick") { model.controller?.pickAttempt(a.id) }
                                .buttonStyle(.borderedProminent).tint(Color(ns: Theme.amber))
                                .disabled(a.state == .working)
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
