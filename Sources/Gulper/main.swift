import Cocoa
import WebKit

class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { close() }
    override func keyDown(with event: NSEvent) { close() }
}

class MainWindowController: NSObject {
    private let window: NSWindow
    private let timerLabel = NSTextField(labelWithString: "30:00")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let remindButton = NSButton(title: "立即提醒", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "运行中")

    weak var delegate: AppDelegate?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
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

        let buttonStack = NSStackView(views: [pauseButton, remindButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let intervalLabel = NSTextField(labelWithString: "提醒间隔：")
        intervalLabel.font = NSFont.systemFont(ofSize: 13)
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false

        let intervalStack = NSStackView(views: [intervalLabel, intervalPopup])
        intervalStack.orientation = .horizontal
        intervalStack.spacing = 8
        intervalStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [timerLabel, statusLabel, intervalStack, buttonStack])
        mainStack.orientation = .vertical
        mainStack.spacing = 16
        mainStack.alignment = .centerX
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            mainStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateTitle()
        startTimer()

        mainWindow = MainWindowController()
        mainWindow.delegate = self
        mainWindow.show()
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
