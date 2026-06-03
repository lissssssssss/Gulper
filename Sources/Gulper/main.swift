import Cocoa
import Network
import UniformTypeIdentifiers
import WebKit

class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { close() }
    override func keyDown(with event: NSEvent) { close() }
}

class PeerService {
    private var listener: NWListener?
    private var browser: NWBrowser?
    private(set) var peers: [NWBrowser.Result] = []
    var onPeersChanged: (() -> Void)?
    var onReceiveImage: ((Data, String) -> Void)?

    func start() {
        startListener()
        startBrowser()
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try! NWListener(using: params)
        let name = Host.current().localizedName ?? "Gulper"
        listener.service = NWListener.Service(name: name, type: "_gulper._tcp")
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleIncoming(conn)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_gulper._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            self.peers = results.filter { result in
                if case .service(let name, _, _, _) = result.endpoint {
                    return name != (Host.current().localizedName ?? "")
                }
                return true
            }
            DispatchQueue.main.async { self.onPeersChanged?() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handleIncoming(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            self?.receiveAll(conn: conn, buffer: data ?? Data())
        }
    }

    private func receiveAll(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if isComplete {
                self.parseMessage(buf)
            } else {
                self.receiveAll(conn: conn, buffer: buf)
            }
        }
    }

    private func parseMessage(_ data: Data) {
        guard data.count > 5 else { return }
        let extLen = Int(data[0])
        guard data.count > 1 + extLen + 4 else { return }
        let ext = String(data: data[1..<(1+extLen)], encoding: .utf8) ?? "png"
        let imgData = data[(1+extLen+4)...]
        DispatchQueue.main.async { self.onReceiveImage?(Data(imgData), ext) }
    }

    func send(data: Data, ext: String, to peer: NWBrowser.Result) {
        let conn = NWConnection(to: peer.endpoint, using: .tcp)
        conn.start(queue: .main)
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                var message = Data()
                let extData = ext.data(using: .utf8) ?? Data()
                message.append(UInt8(extData.count))
                message.append(extData)
                var len = UInt32(data.count).bigEndian
                message.append(Data(bytes: &len, count: 4))
                message.append(data)
                conn.send(content: message, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    func peerName(_ peer: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = peer.endpoint { return name }
        return "Unknown"
    }
}

class MainWindowController: NSObject {
    private let window: NSWindow
    private let timerLabel = NSTextField(labelWithString: "30:00")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let remindButton = NSButton(title: "立即提醒", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "运行中")
    private let importButton = NSButton(title: "导入图片…", target: nil, action: nil)
    private let customToggle = NSButton(checkboxWithTitle: "使用自定义图片", target: nil, action: nil)
    private let openFolderButton = NSButton(title: "打开图片目录", target: nil, action: nil)
    private let pushButton = NSPopUpButton(frame: .zero, pullsDown: true)

    weak var delegate: AppDelegate?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Gulper"
        window.center()
        window.isReleasedWhenClosed = false

        super.init()

        setupUI()
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        remindButton.target = self
        remindButton.action = #selector(remindNow)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        importButton.target = self
        importButton.action = #selector(importImages)
        customToggle.target = self
        customToggle.action = #selector(toggleCustom)
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolder)
        pushButton.target = self
        pushButton.action = #selector(pushToPeer(_:))
    }

    private func setupUI() {
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        timerLabel.alignment = .center
        timerLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        intervalPopup.addItems(withTitles: ["15 分钟", "30 分钟", "45 分钟", "60 分钟"])
        intervalPopup.selectItem(at: 1)
        intervalPopup.translatesAutoresizingMaskIntoConstraints = false

        pauseButton.bezelStyle = .rounded
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        remindButton.bezelStyle = .rounded
        remindButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false
        openFolderButton.bezelStyle = .rounded
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false

        customToggle.translatesAutoresizingMaskIntoConstraints = false

        pushButton.translatesAutoresizingMaskIntoConstraints = false
        pushButton.addItem(withTitle: "推送提醒给…")
        pushButton.item(at: 0)?.isEnabled = false

        let buttonRow1 = NSStackView(views: [pauseButton, remindButton])
        buttonRow1.orientation = .horizontal
        buttonRow1.spacing = 12
        buttonRow1.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow2 = NSStackView(views: [importButton, openFolderButton])
        buttonRow2.orientation = .horizontal
        buttonRow2.spacing = 12
        buttonRow2.translatesAutoresizingMaskIntoConstraints = false

        let intervalLabel = NSTextField(labelWithString: "提醒间隔：")
        intervalLabel.font = NSFont.systemFont(ofSize: 13)
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false

        let intervalStack = NSStackView(views: [intervalLabel, intervalPopup])
        intervalStack.orientation = .horizontal
        intervalStack.spacing = 8
        intervalStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [timerLabel, statusLabel, intervalStack, buttonRow1, customToggle, buttonRow2, pushButton])
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .centerX
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            mainStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            pushButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])

        window.contentView = contentView
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateTimer(minutes: Int, seconds: Int, paused: Bool) {
        timerLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
        statusLabel.stringValue = paused ? "已暂停" : "运行中"
        statusLabel.textColor = paused ? .systemOrange : .secondaryLabelColor
        pauseButton.title = paused ? "继续" : "暂停"
    }

    func updateInterval(index: Int) {
        intervalPopup.selectItem(at: index)
    }

    func updateCustomToggle(on: Bool) {
        customToggle.state = on ? .on : .off
    }

    func updatePeers(names: [String]) {
        pushButton.removeAllItems()
        pushButton.addItem(withTitle: "推送提醒给…")
        pushButton.item(at: 0)?.isEnabled = false
        for name in names {
            pushButton.addItem(withTitle: name)
        }
    }

    @objc private func togglePause() {
        delegate?.togglePauseFromWindow()
    }

    @objc private func remindNow() {
        delegate?.showReminder()
    }

    @objc private func intervalChanged() {
        let intervals = [15, 30, 45, 60]
        let idx = intervalPopup.indexOfSelectedItem
        delegate?.changeIntervalFromWindow(minutes: intervals[idx])
    }

    @objc private func importImages() {
        delegate?.importCustomImagesFromWindow()
    }

    @objc private func toggleCustom() {
        delegate?.toggleCustomImagesFromWindow(on: customToggle.state == .on)
    }

    @objc private func openFolder() {
        delegate?.openCustomFolderFromWindow()
    }

    @objc private func pushToPeer(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem - 1
        if idx >= 0 {
            delegate?.sendToPeerFromWindow(index: idx)
        }
        sender.selectItem(at: 0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var secondsRemaining = 30 * 60
    private var interval = 30 * 60
    private var paused = false
    private var showDrink = true
    private var customImagesDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gulper/CustomImages")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var useCustomImages = false
    private let drinkCards = (1...10).map { "drink/drink\($0).html" }
    private let walkCards = (1...10).map { "walk/walk\($0).html" }
    private var mainWindow: MainWindowController!
    private var peerService: PeerService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateTitle()
        startTimer()

        mainWindow = MainWindowController()
        mainWindow.delegate = self
        mainWindow.show()

        peerService = PeerService()
        peerService.onPeersChanged = { [weak self] in self?.rebuildPeerMenu() }
        peerService.onReceiveImage = { [weak self] data, ext in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try? data.write(to: tmp)
            self?.showReminderWithURL(tmp)
        }
        peerService.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())

        let intervals = [15, 30, 45, 60]
        for mins in intervals {
            let item = NSMenuItem(title: "\(mins) 分钟", action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.tag = mins
            item.target = self
            if mins * 60 == interval { item.state = .on }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "暂停", action: #selector(togglePause(_:)), keyEquivalent: "p"))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "立即提醒", action: #selector(manualReminder), keyEquivalent: "r"))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "导入自定义图片…", action: #selector(importCustomImages), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "使用自定义图片", action: #selector(toggleCustomImages(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "打开图片目录", action: #selector(openCustomFolder), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())

        let peerItem = NSMenuItem(title: "推送提醒给…", action: nil, keyEquivalent: "")
        peerItem.submenu = NSMenu(title: "推送提醒给…")
        peerItem.submenu?.addItem(NSMenuItem(title: "搜索中…", action: nil, keyEquivalent: ""))
        menu.addItem(peerItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func tick() {
        guard !paused else {
            mainWindow.updateTimer(minutes: secondsRemaining / 60, seconds: secondsRemaining % 60, paused: true)
            return
        }
        secondsRemaining -= 1
        updateTitle()
        mainWindow.updateTimer(minutes: secondsRemaining / 60, seconds: secondsRemaining % 60, paused: false)
        if secondsRemaining <= 0 {
            showReminder()
            secondsRemaining = interval
        }
    }

    private func updateTitle() {
        let m = secondsRemaining / 60
        let s = secondsRemaining % 60
        statusItem.button?.title = String(format: "🥤 %02d:%02d", m, s)
    }

    @objc private func showMainWindow() {
        mainWindow.show()
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        interval = sender.tag * 60
        secondsRemaining = interval
        for item in statusItem.menu!.items where item.action == #selector(changeInterval(_:)) {
            item.state = item.tag == sender.tag ? .on : .off
        }
        let idx = [15, 30, 45, 60].firstIndex(of: sender.tag) ?? 1
        mainWindow.updateInterval(index: idx)
    }

    func changeIntervalFromWindow(minutes: Int) {
        interval = minutes * 60
        secondsRemaining = interval
        for item in statusItem.menu!.items where item.action == #selector(changeInterval(_:)) {
            item.state = item.tag == minutes ? .on : .off
        }
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.title = paused ? "继续" : "暂停"
    }

    func togglePauseFromWindow() {
        paused.toggle()
        for item in statusItem.menu!.items where item.action == #selector(togglePause(_:)) {
            item.title = paused ? "继续" : "暂停"
        }
    }

    func importCustomImagesFromWindow() {
        importCustomImages()
    }

    func toggleCustomImagesFromWindow(on: Bool) {
        useCustomImages = on
        updateCustomMenuItem()
    }

    func openCustomFolderFromWindow() {
        NSWorkspace.shared.open(customImagesDir)
    }

    func sendToPeerFromWindow(index: Int) {
        guard index < peerService.peers.count else { return }
        let peer = peerService.peers[index]
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.png, .jpeg, .gif, .movie, .mpeg4Movie, .quickTimeMovie]
            panel.message = "选择要推送的图片或视频"
            if panel.runModal() == .OK, let url = panel.url,
               let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                self?.peerService.send(data: data, ext: ext, to: peer)
            }
        }
    }

    @objc private func manualReminder() {
        showReminder()
    }

    @objc func showReminder() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let panel = ReminderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
        webView.setValue(false, forKey: "drawsBackground")
        if let cardURL = cardURL() {
            let ext = cardURL.pathExtension.lowercased()
            if ["png","jpg","jpeg","gif","webp"].contains(ext) {
                let html = """
                <html><body style="margin:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;width:100vw;height:100vh;overflow:hidden">
                <img src="\(cardURL.absoluteString)" style="max-width:100vw;max-height:100vh;object-fit:contain">
                </body></html>
                """
                webView.loadHTMLString(html, baseURL: cardURL.deletingLastPathComponent())
            } else if ["mp4","mov","m4v"].contains(ext) {
                let html = """
                <html><body style="margin:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;width:100vw;height:100vh;overflow:hidden">
                <video src="\(cardURL.absoluteString)" autoplay loop muted playsinline style="max-width:100vw;max-height:100vh;object-fit:contain"></video>
                </body></html>
                """
                webView.loadHTMLString(html, baseURL: cardURL.deletingLastPathComponent())
            } else {
                webView.loadFileURL(cardURL, allowingReadAccessTo: cardURL.deletingLastPathComponent())
            }
        }

        panel.contentView = webView
        panel.makeKeyAndOrderFront(nil)
        showDrink.toggle()

        var monitors: [Any] = []
        let dismiss = { [weak panel] in
            panel?.close()
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors.removeAll()
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { _ in dismiss() }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { e in dismiss(); return e }!)
    }

    @objc private func importCustomImages() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.png, .jpeg, .gif, .movie, .mpeg4Movie, .quickTimeMovie]
            panel.message = "选择要导入的图片或视频（支持 GIF/PNG/JPG/MP4/MOV）"
            if panel.runModal() == .OK {
                for url in panel.urls {
                    let dest = self.customImagesDir.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
                self.useCustomImages = true
                self.updateCustomMenuItem()
            }
        }
    }

    @objc private func toggleCustomImages(_ sender: NSMenuItem) {
        useCustomImages.toggle()
        updateCustomMenuItem()
    }

    @objc private func openCustomFolder() {
        NSWorkspace.shared.open(customImagesDir)
    }

    private func updateCustomMenuItem() {
        for item in statusItem.menu!.items where item.action == #selector(toggleCustomImages(_:)) {
            item.state = useCustomImages ? .on : .off
        }
        mainWindow.updateCustomToggle(on: useCustomImages)
    }

    private func cardURL() -> URL? {
        if useCustomImages,
           let files = try? FileManager.default.contentsOfDirectory(at: customImagesDir, includingPropertiesForKeys: nil),
           let file = files.filter({ ["gif","png","jpg","jpeg","webp","mp4","mov","m4v"].contains($0.pathExtension.lowercased()) }).randomElement() {
            return file
        }
        let cards = showDrink ? drinkCards : walkCards
        let name = cards.randomElement()!
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }

    private func rebuildPeerMenu() {
        guard let peerItem = statusItem.menu?.items.first(where: { $0.title == "推送提醒给…" }),
              let submenu = peerItem.submenu else { return }
        submenu.removeAllItems()
        let names = peerService.peers.map { peerService.peerName($0) }
        if names.isEmpty {
            submenu.addItem(NSMenuItem(title: "未发现设备", action: nil, keyEquivalent: ""))
        } else {
            for (idx, name) in names.enumerated() {
                let item = NSMenuItem(title: name, action: #selector(sendToPeer(_:)), keyEquivalent: "")
                item.tag = idx
                item.target = self
                submenu.addItem(item)
            }
        }
        mainWindow.updatePeers(names: names)
    }

    @objc private func sendToPeer(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < peerService.peers.count else { return }
        let peer = peerService.peers[idx]
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.png, .jpeg, .gif, .movie, .mpeg4Movie, .quickTimeMovie]
            panel.message = "选择要推送的图片或视频"
            if panel.runModal() == .OK, let url = panel.url,
               let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                self?.peerService.send(data: data, ext: ext, to: peer)
            }
        }
    }

    private func showReminderWithURL(_ url: URL) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let panel = ReminderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
        webView.setValue(false, forKey: "drawsBackground")
        let ext = url.pathExtension.lowercased()
        if ["png","jpg","jpeg","gif","webp"].contains(ext) {
            let html = """
            <html><body style="margin:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;width:100vw;height:100vh;overflow:hidden">
            <img src="\(url.absoluteString)" style="max-width:100vw;max-height:100vh;object-fit:contain">
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        } else if ["mp4","mov","m4v"].contains(ext) {
            let html = """
            <html><body style="margin:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;width:100vw;height:100vh;overflow:hidden">
            <video src="\(url.absoluteString)" autoplay loop muted playsinline style="max-width:100vw;max-height:100vh;object-fit:contain"></video>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.contentView = webView
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var monitors: [Any] = []
        let dismiss = { [weak panel] in
            panel?.close()
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors.removeAll()
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { _ in dismiss() }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { e in dismiss(); return e }!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
