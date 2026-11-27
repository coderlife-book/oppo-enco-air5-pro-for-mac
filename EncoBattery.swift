// EncoBattery — 菜单栏显示 OPPO Enco Air5 Pro 左右耳 + 充电仓电量
//
// 只读：通过经典蓝牙 SPP（RFCOMM channel 5，服务 UUID 0000079A-D102-11E1-9B23-00025B00A5A5）
// 向耳机发「查询电量」指令，不写任何设置。
//
// 协议（OPOv1 / HeyMelody 家族）：
//   帧: AA <len> 00 00 <cmd LE16> <seq> <paylen LE16> <payload>
//       len = 帧总长 - 2
//   0x0106 查电量 → 0x8106: payload = status(0) + count + count×(设备字节, 电量字节)
//       设备字节 1=左 2=右 3=仓；电量低 7 位为百分比，bit7 = 充电中
//   0x0103 产品 id → 0x8103: payload = status + 3 字节 LE（Enco Air5 Pro = 0x06C410）
//
// 注意：进程内第一次 openRFCOMMChannelSync 必定 3.1 秒超时失败（RFCOMM mux 建立
// 被算进这次调用），紧接着重试即成功——所以下面有「预热 + 重试」。
//
// 编译：./build.sh

import Cocoa
import IOBluetooth
import SwiftUI

let kServiceUUID = "0000079a-d102-11e1-9b23-00025b00a5a5"
let kChannelID: UInt8 = 5
let kOfflineAfter: TimeInterval = 20

// MARK: - 快照

struct Snapshot {
    var online = false
    var name = "Enco Air5 Pro"
    var productID: Int? = nil
    var left: Int? = nil
    var right: Int? = nil
    var caseLevel: Int? = nil
    var leftCharging = false
    var rightCharging = false
    var caseCharging = false
    var updatedAt: Date? = nil
}

// MARK: - 状态

final class BatteryModel: ObservableObject {
    @Published var online = false
    @Published var name = "Enco Air5 Pro"
    @Published var left: Int? = nil
    @Published var right: Int? = nil
    @Published var caseLevel: Int? = nil
    @Published var leftCharging = false
    @Published var rightCharging = false
    @Published var caseCharging = false
    @Published var lastUpdate: Date? = nil

    func apply(_ s: Snapshot) {
        name = s.name
        online = s.online
        left = s.left
        right = s.right
        caseLevel = s.caseLevel
        leftCharging = s.leftCharging
        rightCharging = s.rightCharging
        caseCharging = s.caseCharging
        if let t = s.updatedAt { lastUpdate = t }
    }

    /// 菜单栏和标题用的「整体电量」：取左右耳里更低的那只
    var overallLevel: Int? {
        let levels = [left, right].compactMap { $0 }
        return levels.min()
    }

    var anyCharging: Bool { leftCharging || rightCharging || caseCharging }

    var percentage: String { overallLevel.map { "\($0)%" } ?? "—" }

    var statusTitle: String {
        guard online else { return "未连接" }
        if anyCharging { return "正在充电" }
        if let overallLevel, overallLevel >= 100 { return "已充满" }
        if let overallLevel, overallLevel <= 10 { return "低电量" }
        return "正在使用"
    }
}

// MARK: - 行

private struct LevelRow: View {
    let badge: String
    let title: String
    let level: Int?
    let charging: Bool

    private var tint: Color {
        guard let level else { return .secondary }
        if charging { return .green }
        if level <= 10 { return .red }
        if level <= 20 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(badge)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                )
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(level == nil ? Color.secondary : Color.primary)
                .frame(width: 52, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let level, level > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geometry.size.width * CGFloat(level) / 100))
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 3) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
                Text(level.map { "\($0)%" } ?? "—")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(level.map { "\($0)%" } ?? "未知")\(charging ? "，充电中" : "")")
    }
}

// MARK: - 浮层内容

private struct BatteryPopover: View {
    @ObservedObject var model: BatteryModel

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(spacing: 14) {
            header
            VStack(spacing: 9) {
                LevelRow(badge: "L", title: "左耳", level: model.left, charging: model.leftCharging)
                LevelRow(badge: "R", title: "右耳", level: model.right, charging: model.rightCharging)
                LevelRow(badge: "仓", title: "充电仓", level: model.caseLevel, charging: model.caseCharging)
            }
            Divider()
            statusRow
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "earbuds")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.headline)
                Text(model.online ? "蓝牙 · 已连接" : "蓝牙 · 未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Text(model.online ? model.percentage : "—")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(model.online ? Color.primary : Color.secondary)
                .accessibilityLabel("整体电量 \(model.online ? model.percentage : "未知")")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.online ? (model.anyCharging ? Color.green : Color.secondary) : Color.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(model.statusTitle)
                .font(.subheadline)
                .foregroundStyle(model.online ? Color.primary : Color.secondary)

            Spacer(minLength: 8)

            if let lastUpdate = model.lastUpdate {
                Group {
                    if model.online {
                        Text("刚刚更新")
                    } else {
                        TimelineView(.periodic(from: lastUpdate, by: 60)) { context in
                            let age = context.date.timeIntervalSince(lastUpdate)
                            let updated = age < 60
                                ? "不到 1 分钟前"
                                : Self.relativeTime.localizedString(for: lastUpdate, relativeTo: context.date)
                            Text(updated)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 蓝牙链路

private final class Receiver: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onFrame: (([UInt8]) -> Void)?
    var onClosed: (() -> Void)?
    private var buffer: [UInt8] = []

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer.append(contentsOf: UnsafeRawBufferPointer(start: data, count: length))
        while buffer.count >= 2 {
            guard buffer[0] == 0xAA else {
                buffer.removeFirst()
                continue
            }
            // len 为 7-bit varint（帧总长 - 2）
            var value = 0
            var shift = 0
            var index = 1
            var complete = false
            while index < buffer.count, index < 5 {
                let byte = buffer[index]
                value |= Int(byte & 0x7F) << shift
                index += 1
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
            }
            guard complete else { break }
            let total = index + value
            guard buffer.count >= total else { break }
            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            onFrame?(frame)
        }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        onClosed?()
    }
}

final class EncoLink {

    var onUpdate: ((Snapshot) -> Void)?

    private let interval: TimeInterval
    private let debugMode = ProcessInfo.processInfo.environment["EB_DEBUG"] != nil
    private var thread: Thread?
    private var stopped = false
    private let lock = NSLock()
    private var manualRequest = false

    private var device: IOBluetoothDevice?
    private var receiver: Receiver?
    private var seq: UInt8 = 0
    private var snapshot = Snapshot()

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "EncoLink"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func requestRefresh() {
        lock.lock()
        manualRequest = true
        lock.unlock()
    }

    // MARK: 主循环

    private func run() {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)
        var next = Date()
        while !stopped {
            var due = Date() >= next
            lock.lock()
            if manualRequest { manualRequest = false; due = true }
            lock.unlock()
            if due {
                poll()
                next = Date().addingTimeInterval(interval)
            }
            runLoop.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func poll() {
        guard let dev = resolveDevice() else {
            publish(online: false)
            return
        }
        guard dev.isConnected() else {
            publish(online: false)
            return
        }

        let rx = Receiver()
        rx.onFrame = { [weak self] frame in self?.ingest(frame) }
        rx.onClosed = { [weak self] in self?.receiver = nil }

        guard let channel = open(dev, delegate: rx) else {
            publish(online: false)
            return
        }
        receiver = rx

        // 产品 id 只查一次
        if snapshot.productID == nil {
            send(channel, cmd: 0x0103)
            wait(0.5)
        }
        send(channel, cmd: 0x0106)
        wait(1.5)

        channel.close()
        receiver = nil
        publish(online: true)
    }

    // MARK: SPP

    /// 第一次 open 必定超时（mux 建立），这里重试拿到真通道。
    private func open(_ dev: IOBluetoothDevice, delegate: Receiver) -> IOBluetoothRFCOMMChannel? {
        for attempt in 1...3 {
            var channel: IOBluetoothRFCOMMChannel? = nil
            let started = Date()
            let result = dev.openRFCOMMChannelSync(&channel, withChannelID: kChannelID, delegate: delegate)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if debugMode {
                print(String(format: "open ch%d #%d -> 0x%X %dms", kChannelID, attempt, UInt32(bitPattern: result), ms))
                fflush(stdout)
            }
            if result == kIOReturnSuccess, let channel { return channel }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func send(_ channel: IOBluetoothRFCOMMChannel, cmd: UInt16, payload: [UInt8] = []) {
        seq &+= 1
        let declared = 7 + payload.count
        var bytes: [UInt8] = [
            0xAA,
            UInt8(declared & 0x7F),
            0x00, 0x00,
            UInt8(cmd & 0xFF), UInt8(cmd >> 8),
            seq,
            UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF),
        ]
        bytes += payload
        var mutable = bytes
        let result = mutable.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            channel.writeSync(pointer.baseAddress!, length: UInt16(bytes.count))
        }
        if debugMode {
            print("tx " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                  + String(format: " w=0x%X", UInt32(bitPattern: result)))
            fflush(stdout)
        }
    }

    private func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: 解析

    private func ingest(_ frame: [UInt8]) {
        if debugMode {
            print("rx " + frame.map { String(format: "%02x", $0) }.joined(separator: " "))
            fflush(stdout)
        }
        guard frame.count >= 9 else { return }
        let body = Array(frame[2...])
        let cmd = UInt16(body[2]) | (UInt16(body[3]) << 8)
        let payload = Array(body[7...])

        switch cmd {
        case 0x8103 where payload.count >= 4:
            snapshot.productID = Int(payload[1]) | (Int(payload[2]) << 8) | (Int(payload[3]) << 16)
            if debugMode {
                print(String(format: "product id = %06X", snapshot.productID ?? 0))
                fflush(stdout)
            }

        case 0x8106 where payload.count >= 2:
            let count = Int(payload[1])
            var left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil
            var leftCharging = false, rightCharging = false, caseCharging = false
            for i in 0..<count {
                let base = 2 + i * 2
                guard base + 1 < payload.count else { break }
                let id = payload[base]
                guard id != 0xFF else { continue }
                let raw = Int(payload[base + 1])
                let level = raw & 0x7F
                let charging = raw & 0x80 != 0
                switch id {
                case 1: left = level; leftCharging = charging
                case 2: right = level; rightCharging = charging
                case 3: caseLevel = level; caseCharging = charging
                default: break
                }
            }
            snapshot.left = left
            snapshot.right = right
            snapshot.caseLevel = caseLevel
            snapshot.leftCharging = leftCharging
            snapshot.rightCharging = rightCharging
            snapshot.caseCharging = caseCharging
            snapshot.updatedAt = Date()
            snapshot.online = true
            if debugMode {
                print("battery L=\(left.map(String.init) ?? "-") R=\(right.map(String.init) ?? "-") case=\(caseLevel.map(String.init) ?? "-")")
                fflush(stdout)
            }

        default:
            break
        }
    }

    // MARK: 设备发现

    private func resolveDevice() -> IOBluetoothDevice? {
        if let existing = device, existing.isConnected() { return existing }

        if let address = ProcessInfo.processInfo.environment["EB_ADDRESS"],
           let found = IOBluetoothDevice(addressString: address) {
            device = found
            snapshot.name = found.name ?? snapshot.name
            return found
        }

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let pattern = try? NSRegularExpression(pattern: "(?i)enco|oppo|realme|oneplus", options: [])

        func matches(_ dev: IOBluetoothDevice) -> Bool {
            guard let name = dev.name else { return false }
            let range = NSRange(name.startIndex..., in: name)
            return pattern?.firstMatch(in: name, options: [], range: range) != nil
        }

        let candidate = paired.first { $0.isConnected() && matches($0) }
            ?? paired.first(where: matches)
        if let candidate {
            device = candidate
            snapshot.name = candidate.name ?? snapshot.name
            return candidate
        }
        if debugMode {
            print("no candidate among \(paired.count) paired devices")
            fflush(stdout)
        }
        return nil
    }

    private func publish(online: Bool) {
        snapshot.online = online && snapshot.updatedAt != nil
        let snapshot = self.snapshot
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = BatteryModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var keyMonitor: Any?
    private var link: EncoLink?
    private var ticker: Timer?
    private var fakeActive = false

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        let refreshItem = menu.addItem(withTitle: "刷新电量", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 EncoBattery", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        return menu
    }()

    private var debugMode: Bool { ProcessInfo.processInfo.environment["EB_DEBUG"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BatteryPopover(model: model))
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

        let interval = Double(ProcessInfo.processInfo.environment["EB_INTERVAL"] ?? "") ?? 30
        let link = EncoLink(interval: interval)
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
                switch fake {
                case "charging":
                    self.model.online = true
                    self.model.left = 82; self.model.right = 80; self.model.caseLevel = 96
                    self.model.leftCharging = false; self.model.rightCharging = true; self.model.caseCharging = true
                    self.model.lastUpdate = Date()
                case "empty":
                    self.model.online = true
                    self.model.left = 46; self.model.right = 45
                    self.model.lastUpdate = Date()
                case "offline":
                    self.model.online = false
                default:
                    break
                }
                self.updateStatusItem()
            }
        }
        if debugMode { print("started"); fflush(stdout) }
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
        button.toolTip = tip

        let color: NSColor = level <= 10 ? .systemRed : (level <= 20 ? .systemOrange : .labelColor)
        button.attributedTitle = NSAttributedString(
            string: "\(level)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: color,
            ]
        )
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
            if ProcessInfo.processInfo.environment["EB_DEBUG"] != nil {
                print("toggle: buttonWindow=\(button.window != nil) fitting=\(content.fittingSize)")
                fflush(stdout)
            }
            popover.contentSize = content.fittingSize
            // LSUIElement 的后台 app 不激活的话，transient 浮层会刚出现就被收回
            // NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            content.window?.makeKeyAndOrderFront(nil)
            if ProcessInfo.processInfo.environment["EB_DEBUG"] != nil {
                print("after show: isShown=\(popover.isShown) vis=\(popover.contentViewController?.view.window?.isVisible ?? false) occl=\(popover.contentViewController?.view.window?.occlusionState.rawValue ?? 0) win=\(popover.contentViewController?.view.window?.frame ?? .zero) screens=\(NSScreen.screens.map { $0.frame }) buttonWin=\(button.window?.frame ?? .zero)")
                fflush(stdout)
            }
        }
    }

    @objc private func refresh() {
        link?.requestRefresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 离屏渲染电量卡片，用于文档/截图：EB_RENDER=/tmp/card.png EB_FAKE=charging EB_APPEARANCE=dark
@MainActor func renderCard(to path: String, fake: String, dark: Bool) {
    let model = BatteryModel()
    model.name = "OPPO Enco Air5 Pro"
    switch fake {
    case "charging":
        model.online = true
        model.left = 82; model.right = 80; model.caseLevel = 96
        model.leftCharging = false; model.rightCharging = true; model.caseCharging = true
    case "empty":
        model.online = true
        model.left = 46; model.right = 45
    case "offline":
        model.online = false
    default:
        break
    }
    model.lastUpdate = Date()
    let content = BatteryPopover(model: model)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color.clear)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("render failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("rendered \(path) \(Int(image.size.width))x\(Int(image.size.height))")
}

if let output = ProcessInfo.processInfo.environment["EB_RENDER"] {
    if let appearance = ProcessInfo.processInfo.environment["EB_APPEARANCE"] {
        app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    }
    let fake = ProcessInfo.processInfo.environment["EB_FAKE"] ?? "charging"
    if #available(macOS 14.0, *) {
        MainActor.assumeIsolated { renderCard(to: output, fake: fake, dark: ProcessInfo.processInfo.environment["EB_APPEARANCE"] == "dark") }
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
