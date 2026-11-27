import AppKit
import Combine
import SwiftUI

private let kOfflineAfter: TimeInterval = 20      // 兜底：超过 20 秒没新数据显示未连接

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = BatteryModel()
    private let settings = SettingsStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var link: EncoLink?
    private var ticker: Timer?
    private var fakeActive = false

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        let refreshItem = menu.addItem(withTitle: "刷新电量", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        let reconnectItem = menu.addItem(withTitle: "重连耳机", action: #selector(reconnect), keyEquivalent: "")
        reconnectItem.target = self
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 OPPO Enco Air5 Pro", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        schedulePopoverTest()
        startLink()
        configureDebugHooks()
        observeSettings()
        applyMenuBarVisibility(settings.menuBarIconVisible)
        debugLog("started")
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let symbol = NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
            let image = symbol?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        let popoverView = BatteryPopover(
            model: model,
            onSetNoise: { [weak self] mode, level in self?.setNoise(mode, level) },
            onSetEQ: { [weak self] preset in self?.setEQ(preset) },
            onOpenSettings: { [weak self] in self?.openSettingsWindow(fromPopover: true) })
        popover.contentViewController = NSHostingController(rootView: popoverView)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "r": self.refresh()
            case "q": self.quit()
            default: return event
            }
            return nil
        }
    }

    private func startLink() {
        let interval = Double(ProcessInfo.processInfo.environment["EB_INTERVAL"] ?? "") ?? 15
        let link = EncoLink(keepaliveInterval: interval)
        link.onUpdate = { [weak self] snapshot in
            guard let self, !self.fakeActive else { return }
            self.model.apply(snapshot)
            self.updateStatusItem()
        }
        link.start()
        self.link = link

        // 离线兜底：超过 20 秒没有新数据就显示未连接
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.fakeActive else { return }
            let stale = self.model.lastUpdate.map { Date().timeIntervalSince($0) > kOfflineAfter } ?? true
            if stale && self.model.online {
                self.model.online = false
                self.updateStatusItem()
            }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func observeSettings() {
        settings.$menuBarIconVisible
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.applyMenuBarVisibility(visible)
            }
            .store(in: &cancellables)
        for publisher in [
            settings.$showLeftInMenuBar,
            settings.$showRightInMenuBar,
            settings.$showCaseInMenuBar,
        ] {
            publisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
                .store(in: &cancellables)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(model.name)
        button.setAccessibilityValue(model.statusTitle)

        // 没有数据时只留图标（并置灰），不画破折号
        guard model.online, let level = model.overallLevel else {
            button.attributedTitle = NSAttributedString(string: "")
            button.appearsDisabled = true
            button.toolTip = "\(model.name) 未连接"
            return
        }
        button.appearsDisabled = false

        var tip = "\(model.name) · 左 \(model.left.map { "\($0)%" } ?? "—") 右 \(model.right.map { "\($0)%" } ?? "—")"
        if let c = model.caseLevel { tip += " · 仓 \(c)%" }
        if let mode = model.noiseMode {
            tip += " · 降噪 \(mode.label)\(mode == .noise ? "（\(model.noiseLevel?.label ?? "—")）" : "")"
        }
        if let eq = model.eq { tip += " · 音效 \(eq.label)" }
        if let firmware = model.firmware { tip += " · 固件 \(firmware)" }
        button.toolTip = tip

        // 分耳模式：「L82 R80 仓96」，三格各自开关，没有数据的槽不出现
        let detailed = detailedAttributedTitle()
        if detailed.length > 0 {
            button.attributedTitle = detailed
            return
        }

        let color: NSColor = level <= 10 ? .systemRed : (level <= 20 ? .systemOrange : .labelColor)
        button.attributedTitle = NSAttributedString(
            string: "\(level)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    /// 菜单栏分耳电量：「L82 R80 仓96」；绿色=充电中，橙/红=低电量
    private func detailedAttributedTitle() -> NSAttributedString {
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

        func levelColor(_ level: Int, charging: Bool) -> NSColor {
            if charging { return .systemGreen }
            if level <= 10 { return .systemRed }
            if level <= 20 { return .systemOrange }
            return .labelColor
        }

        let slots: [(String, Int?, Bool, Bool)] = [
            ("L", model.left, model.leftCharging, settings.showLeftInMenuBar),
            ("R", model.right, model.rightCharging, settings.showRightInMenuBar),
            ("仓", model.caseLevel, model.caseCharging, settings.showCaseInMenuBar),
        ]
        let segments = slots.compactMap { slot -> (String, Int, Bool)? in
            guard slot.3, let level = slot.1 else { return nil }
            return (slot.0, level, slot.2)
        }
        guard !segments.isEmpty else { return NSAttributedString() }

        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ", attributes: [
                    .font: numberFont,
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
            result.append(NSAttributedString(string: segment.0, attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            result.append(NSAttributedString(string: "\(segment.1)%", attributes: [
                .font: numberFont,
                .foregroundColor: levelColor(segment.1, charging: segment.2),
            ]))
        }
        return result
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            popover.performClose(nil)
            NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button, button.window != nil,
                  let content = popover.contentViewController?.view {
            popover.contentSize = content.fittingSize
            // LSUIElement 的后台 app 不激活的话，transient 浮层会刚出现就被收回
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            content.window?.makeKeyAndOrderFront(nil)
            // EB_APPEARANCE 只用于截图：NSPopover 自己的窗口不会跟着 NSApp.appearance 走，得单独指定
            if let name = ProcessInfo.processInfo.environment["EB_APPEARANCE"] {
                content.window?.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            }
        }
    }

    private func setNoise(_ mode: NoiseMode, _ level: ANCLevel?) {
        guard !fakeActive else { return }
        guard model.online else {
            model.lastError = "耳机未连接"
            return
        }
        model.pendingNoise = true
        model.lastError = nil
        link?.send(.noise(mode, level))
    }

    // MARK: 设置窗口与菜单栏可见性

    private func applyMenuBarVisibility(_ visible: Bool) {
        statusItem.isVisible = visible
        if visible {
            NSApp.setActivationPolicy(.accessory)
            updateStatusItem()
        } else {
            // 菜单栏没有图标时，把 Dock 图标顶出来当入口
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow(fromPopover: false)
    }

    private func openSettingsWindow(fromPopover: Bool) {
        if fromPopover { popover.performClose(nil) }
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsPage(settings: settings, model: model)))
        window.title = "OPPO Enco Air5 Pro 设置"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 从 Dock 点图标进来：菜单栏图标被关掉时的入口
        if !flag { openSettingsWindow(fromPopover: false) }
        return true
    }

    private func setEQ(_ preset: EQPreset) {
        guard !fakeActive else { return }
        guard model.online else {
            model.lastError = "耳机未连接"
            return
        }
        model.pendingEQ = true
        model.lastError = nil
        link?.send(.eq(preset))
    }

    @objc private func refresh() {
        link?.send(.refresh)
    }

    @objc private func reconnect() {
        link?.send(.reconnect)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

// MARK: - 运行时调试钩子

private extension AppDelegate {
    func schedulePopoverTest() {
        if ProcessInfo.processInfo.environment["EB_POPOVER_TEST"] == "1" {
            let expandDelay = Double(ProcessInfo.processInfo.environment["EB_EXPAND_AFTER"] ?? "") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.togglePopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let w = self.popover.contentViewController?.view.window else { exit(1) }
                    // 逐帧采样窗口高度（覆盖 EB_EXPAND_AFTER 展开 + EB_COLLAPSE_AFTER 收起）
                    var samples: [String] = []
                    let start = Date()
                    let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                        samples.append(String(format: "%.2f:%.0f", Date().timeIntervalSince(start), w.frame.size.height))
                    }
                    let settle = max(expandDelay, Double(ProcessInfo.processInfo.environment["EB_COLLAPSE_AFTER"] ?? "") ?? 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.5) {
                        timer.invalidate()
                        debugLog("samples " + samples.joined(separator: " "))
                        exit(0)
                    }
                }
            }
        }
    }

    func configureDebugHooks() {
        if let seconds = Double(ProcessInfo.processInfo.environment["EB_SHOWCARD"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.togglePopover()
            }
        }
        if let appearance = ProcessInfo.processInfo.environment["EB_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let fake = ProcessInfo.processInfo.environment["EB_FAKE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.fakeActive = true
                applyFake(fake, to: self.model)
                self.updateStatusItem()
            }
        }
        // headless 写命令自测：EB_TEST=noise:smart|noise:max|noise:moderate|noise:mild|noise:transparency|noise:off|eq:0|eq:1|eq:2
        if let test = ProcessInfo.processInfo.environment["EB_TEST"], !test.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                let parts = test.split(separator: ":").map(String.init)
                if parts.first == "raw", parts.count >= 3,
                   let opcode = UInt16(parts[1], radix: 16) {
                    let hex = parts[2...].joined()
                    var payload: [UInt8] = []
                    var i = hex.startIndex
                    while i < hex.endIndex, let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
                        if let b = UInt8(hex[i..<next], radix: 16) { payload.append(b) }
                        i = next
                    }
                    self.link?.send(.rawTest(opcode: opcode, payload: payload))
                    debugLog("EB_TEST raw opcode=\(String(format: "%04x", opcode)) payload=\(payload.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    return
                }
                switch parts.first {
                case "noise":
                    let arg = parts.count > 1 ? parts[1] : ""
                    let mode: NoiseMode
                    let level: ANCLevel?
                    switch arg {
                    case "off": mode = .off; level = nil
                    case "transparency": mode = .transparency; level = nil
                    case "max": mode = .noise; level = .max
                    case "moderate": mode = .noise; level = .moderate
                    case "mild": mode = .noise; level = .mild
                    default: mode = .noise; level = .smart
                    }
                    self.model.pendingNoise = true
                    self.updateStatusItem()
                    self.link?.send(.noise(mode, level))
                    debugLog("EB_TEST set noise mode=\(mode) level=\(String(describing: level))")
                case "eq":
                    let raw = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                    if let preset = EQPreset(rawValue: raw) {
                        self.model.pendingEQ = true
                        self.updateStatusItem()
                        self.link?.send(.eq(preset))
                        debugLog("EB_TEST set eq \(preset)")
                    }
                default:
                    debugLog("EB_TEST unknown command \(test)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.0) {
                exit(0)
            }
        }
    }
}
