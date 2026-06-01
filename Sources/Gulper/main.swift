import Cocoa
import WebKit

class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { close() }
    override func keyDown(with event: NSEvent) { close() }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var secondsRemaining = 30 * 60
    private var interval = 30 * 60
    private var paused = false
    private var showDrink = true
    private var customFolder: URL?
    private let drinkCards = (1...10).map { "drink/drink\($0).html" }
    private let walkCards = (1...10).map { "walk/walk\($0).html" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateTitle()
        startTimer()
    }

    private func buildMenu() {
        let menu = NSMenu()

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
        menu.addItem(NSMenuItem(title: "导入自定义图片文件夹…", action: #selector(pickCustomFolder), keyEquivalent: ""))
        menu.items.last?.target = self
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
        guard !paused else { return }
        secondsRemaining -= 1
        updateTitle()
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

    @objc private func changeInterval(_ sender: NSMenuItem) {
        interval = sender.tag * 60
        secondsRemaining = interval
        for item in statusItem.menu!.items where item.action == #selector(changeInterval(_:)) {
            item.state = item.tag == sender.tag ? .on : .off
        }
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.title = paused ? "继续" : "暂停"
    }

    @objc private func manualReminder() {
        showReminder()
    }

    @objc private func showReminder() {
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
            webView.loadFileURL(cardURL, allowingReadAccessTo: cardURL.deletingLastPathComponent())
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

    @objc private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择包含自定义提醒图片的文件夹（支持 GIF/PNG/JPG）"
        if panel.runModal() == .OK {
            customFolder = panel.url
        }
    }

    private func cardURL() -> URL? {
        if let folder = customFolder,
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
           let file = files.filter({ ["gif","png","jpg","jpeg","webp"].contains($0.pathExtension.lowercased()) }).randomElement() {
            return file
        }
        let cards = showDrink ? drinkCards : walkCards
        let name = cards.randomElement()!
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
