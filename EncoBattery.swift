// EncoBattery — OPPO Enco Air5 Pro 菜单栏助手：电量 + 降噪 + 音效 + 固件版本
//
// v2.0 起改为长连接会话：打开一次 RFCOMM 通道不关闭，靠耳机主动上报（0x0402）
// 实时刷新电量/降噪状态，手机端改设置这边会同步跟着变。
//
// 协议速查（实测自 Air5 Pro，与 HeyMelody/欢律 同一控制通道）：
//   传输：经典蓝牙 SPP，服务 UUID 0000079A-D102-11E1-9B23-00025B00A5A5
//         RFCOMM 通道号从 SDP record 里取，取不到再退回 5
//   帧：  AA <len:7bit变长> 00 00 <opcode大端> <seq> <paylen小端> <payload>
//         len = payload 长度 + 7；无校验和
//   opcode（大端字节序）：
//         00 01  hello（建立会话）
//         06 01 → 06 81  查电量 / 回包
//         05 01 → 05 81  查设备信息（固件版本）
//         0f 01 → 0f 81  查均衡器 / 回包；04 05 均衡器主动上报
//         04 04          写降噪模式（payload 01 01 <value>）
//         06 04          写均衡器预设（payload 单字节）
//         04 02          主动状态上报，payload 按「块」组织
//   04 02 块结构：<type> <count> <条目...>
//         type 01 电量：条目 = (id, 值)；id 1=左 2=右 3=仓；值 bit7=充电，低 7 位百分比
//                       上报里 0 = 该槽休眠（未知）；查询回包里 0 = 真 0%
//         type 02 放置：条目 = (id, 值)；04=盒内 05=盒外；进仓且没在充电就清掉该耳旧电量
//         type 03 降噪：count 必须 1，条目 = (01, 值 u16 小端)
//                       0x0008=关 0x0100=通透 0x0010=深度 0x0020=中度 0x0040=轻度 0x0080=智能
//                       count != 1 的伴随块（智能模式"当前强度"）直接按长度跳过
//   写命令纪律：只发一次、绝不重试；发完 3 秒内等耳机回报确认，没确认 UI 就报「未确认」，
//         不乐观更新。查询按序匹配，串行发送，间隔 0.2s。
//   坑：进程内第一次 openRFCOMMChannelSync 必定 3.1 秒超时（RFCOMM mux 建立被算进这次
//         调用），紧接着重试即成功——所以打开流程带预热重试。
//
// 编译：./build.sh

import Cocoa
import IOBluetooth
import SwiftUI

let kServiceUUIDBytes: [UInt8] = [
    0x00, 0x00, 0x07, 0x9a, 0xd1, 0x02, 0x11, 0xe1,
    0x9b, 0x23, 0x00, 0x02, 0x5b, 0x00, 0xa5, 0xa5,
]
let kFallbackChannelID: UInt8 = 5
let kOfflineAfter: TimeInterval = 20      // 兜底：超过 20 秒没新数据显示未连接
let kFrameSilenceAfter: TimeInterval = 15 // 通道还开着但 15 秒没帧 = 链路已经断了

let isDebug = ProcessInfo.processInfo.environment["EB_DEBUG"] != nil

func debugLog(_ text: @autoclosure () -> String) {
    guard isDebug else { return }
    print(text())
    fflush(stdout)
}

// MARK: - 降噪 / 均衡器 取值

/// 降噪三态。anc 表示「降噪开着」，具体强度在 ANCLevel。
enum NoiseMode: Hashable {
    case noise
    case transparency
    case off

    var label: String {
        switch self {
        case .noise: return "降噪"
        case .transparency: return "通透"
        case .off: return "关闭"
        }
    }

    /// 写命令用的单字节值（不带强度时 anc 用 0x02，耳机会用上次的强度）
    var commandValue: UInt8 {
        switch self {
        case .noise: return 0x02
        case .transparency: return 0x04
        case .off: return 0x01
        }
    }
}

enum ANCLevel: String, Hashable, CaseIterable {
    case max, moderate, mild, smart

    var label: String {
        switch self {
        case .max: return "深度"
        case .moderate: return "中度"
        case .mild: return "轻度"
        case .smart: return "智能"
        }
    }

    var commandValue: UInt8 {
        switch self {
        case .max: return 0x10
        case .moderate: return 0x20
        case .mild: return 0x40
        case .smart: return 0x80
        }
    }

    /// 主动上报里降噪块的低字节（高字节只有关/通透用到）
    static func from(reportValue: UInt16) -> (mode: NoiseMode, level: ANCLevel?)? {
        switch reportValue {
        case 0x0008: return (.off, nil)
        case 0x0100: return (.transparency, nil)
        case 0x0010: return (.noise, .max)
        case 0x0020: return (.noise, .moderate)
        case 0x0040: return (.noise, .mild)
        case 0x0080: return (.noise, .smart)
        default: return nil
        }
    }
}

/// 均衡器预设。raw 是协议里的字节：0=至臻原音 1=澎湃低音 2=纯享人声
enum EQPreset: Int, Hashable, CaseIterable {
    case original = 0
    case bass = 1
    case vocals = 2

    var label: String {
        switch self {
        case .original: return "至臻原音"
        case .bass: return "澎湃低音"
        case .vocals: return "纯享人声"
        }
    }

    static func from(raw: UInt8) -> EQPreset? {
        EQPreset(rawValue: Int(raw))
    }
}

// MARK: - 帧编解码

enum FrameCodec {

    /// 组一帧。b2 b3 固定 00 00，opcode 大端，payload 长度小端。
    static func make(opcode: UInt16, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let bodyLength = payload.count + 7
        let length: [UInt8] = bodyLength < 128
            ? [UInt8(bodyLength)]
            : [UInt8(bodyLength & 0x7f) | 0x80, UInt8(bodyLength >> 7)]
        return [0xAA] + length
            + [0x00, 0x00, UInt8(opcode >> 8), UInt8(opcode & 0xff), seq,
               UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff)]
            + payload
    }

    struct ParsedFrame {
        let opcode: UInt16
        let sequence: UInt8
        let payload: [UInt8]
    }

    /// 从缓冲里抽完整帧，遇到半截留着。粘帧、拆帧、脏字节都能重同步。
    static func drain(from buffer: inout [UInt8]) -> [ParsedFrame] {
        var frames: [ParsedFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0xAA) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 2 else { break }
            let lengthBytes = buffer[1] & 0x80 == 0 ? 1 : 2
            guard buffer.count >= 1 + lengthBytes else { break }
            if lengthBytes == 2 && buffer[2] & 0x80 != 0 {
                buffer.removeFirst() // 变长长度第三字节不该有高位，这不是帧头
                continue
            }
            let bodyLength = Int(buffer[1] & 0x7f) + (lengthBytes == 2 ? Int(buffer[2]) << 7 : 0)
            guard bodyLength >= 7 else {
                buffer.removeFirst() // 太短不可能是帧，丢掉这个 0xAA 找下一个
                continue
            }
            let total = 1 + lengthBytes + bodyLength
            guard buffer.count >= total else { break }
            let body = Array(buffer[(1 + lengthBytes)..<total])
            let paylen = Int(body[5]) | (Int(body[6]) << 8)
            guard paylen + 7 == bodyLength else {
                buffer.removeFirst() // 两个长度对不上，说明这不是真帧边界
                continue
            }
            buffer.removeFirst(total)
            frames.append(ParsedFrame(
                opcode: UInt16(body[2]) << 8 | UInt16(body[3]),
                sequence: body[4],
                payload: Array(body[7...])))
        }
        return frames
    }
}

// MARK: - 04 02 状态块解析

struct StatusReport {
    var battery: [(id: UInt8, raw: UInt8)] = []
    var placement: [(id: UInt8, value: UInt8)] = []
    var noiseValue: UInt16? = nil
    var hasNoise = false

    /// payload = 若干个块：<type> <count> <条目...>，电量/放置条目 2 字节，降噪条目 3 字节
    static func parse(_ payload: [UInt8]) -> StatusReport {
        var report = StatusReport()
        var i = 0
        while i + 1 < payload.count {
            let type = payload[i]
            let count = Int(payload[i + 1])
            i += 2
            switch type {
            case 0x01, 0x02:
                for _ in 0..<count {
                    guard i + 1 < payload.count else { return report }
                    let id = payload[i], value = payload[i + 1]
                    i += 2
                    if type == 0x01 { report.battery.append((id, value)) }
                    else { report.placement.append((id, value)) }
                }
            case 0x03:
                // 条目 = (id, u16le)。count != 1 的是智能模式伴随块，按长度跳过不解释
                let size = count * 3
                if count == 1, i + 2 < payload.count {
                    report.noiseValue = UInt16(payload[i + 1]) | (UInt16(payload[i + 2]) << 8)
                    report.hasNoise = true
                }
                i += size
            default:
                return report // 不认识的块类型，剩下的不猜
            }
        }
        return report
    }
}

// MARK: - 快照

struct Snapshot {
    var online = false
    var name = "OPPO Enco Air5 Pro"
    var left: Int? = nil
    var right: Int? = nil
    var caseLevel: Int? = nil
    var leftCharging = false
    var rightCharging = false
    var caseCharging = false
    var noiseMode: NoiseMode? = nil
    var noiseLevel: ANCLevel? = nil
    var eq: EQPreset? = nil
    var firmware: String? = nil
    var pendingNoise = false
    var pendingEQ = false
    var lastError: String? = nil
    var updatedAt: Date? = nil
}

// MARK: - 状态模型

final class BatteryModel: ObservableObject {
    @Published var online = false
    @Published var name = "OPPO Enco Air5 Pro"
    @Published var left: Int? = nil
    @Published var right: Int? = nil
    @Published var caseLevel: Int? = nil
    @Published var leftCharging = false
    @Published var rightCharging = false
    @Published var caseCharging = false
    @Published var noiseMode: NoiseMode? = nil
    @Published var noiseLevel: ANCLevel? = nil
    @Published var eq: EQPreset? = nil
    @Published var firmware: String? = nil
    @Published var pendingNoise = false
    @Published var pendingEQ = false
    @Published var lastError: String? = nil
    @Published var lastUpdate: Date? = nil

    func apply(_ s: Snapshot) {
        online = s.online
        name = s.name
        left = s.left
        right = s.right
        caseLevel = s.caseLevel
        leftCharging = s.leftCharging
        rightCharging = s.rightCharging
        caseCharging = s.caseCharging
        noiseMode = s.noiseMode
        noiseLevel = s.noiseLevel
        eq = s.eq
        firmware = s.firmware
        pendingNoise = s.pendingNoise
        pendingEQ = s.pendingEQ
        lastError = s.lastError
        if let t = s.updatedAt { lastUpdate = t }
    }

    /// 菜单栏和标题用的「整体电量」：取左右耳里更低的那只
    var overallLevel: Int? {
        [left, right].compactMap { $0 }.min()
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

// MARK: - 电量行（v1 样式保留）

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

// MARK: - 选择按钮

private struct PillRow<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value?
    let disabled: Bool
    let action: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    action(option.value)
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.quaternary))
                )
                .disabled(disabled)
            }
        }
    }
}

// MARK: - 浮层内容

private struct BatteryPopover: View {
    @ObservedObject var model: BatteryModel
    var onSetNoise: ((NoiseMode, ANCLevel?) -> Void)? = nil
    var onSetEQ: ((EQPreset) -> Void)? = nil

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    private var controlsDisabled: Bool { !model.online }

    var body: some View {
        VStack(spacing: 12) {
            header
            VStack(spacing: 9) {
                LevelRow(badge: "L", title: "左耳", level: model.left, charging: model.leftCharging)
                LevelRow(badge: "R", title: "右耳", level: model.right, charging: model.rightCharging)
                LevelRow(badge: "仓", title: "充电仓", level: model.caseLevel, charging: model.caseCharging)
            }
            Divider()
            noiseSection
            eqSection
            Divider()
            statusRow
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 336)
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

    private var noiseSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("降噪")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.pendingNoise { ProgressView().controlSize(.mini) }
            }
            PillRow(
                options: [NoiseMode.noise, .transparency, .off].map { ($0, $0.label) },
                selection: model.noiseMode,
                disabled: controlsDisabled || model.pendingNoise
            ) { mode in
                onSetNoise?(mode, nil)
            }
            if model.noiseMode == .noise {
                PillRow(
                    options: ANCLevel.allCases.map { ($0, $0.label) },
                    selection: model.noiseLevel,
                    disabled: controlsDisabled || model.pendingNoise
                ) { level in
                    onSetNoise?(.noise, level)
                }
            }
        }
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("音效")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.pendingEQ { ProgressView().controlSize(.mini) }
            }
            PillRow(
                options: [EQPreset.original, .vocals, .bass].map { ($0, $0.label) },
                selection: model.eq,
                disabled: controlsDisabled || model.pendingEQ
            ) { preset in
                onSetEQ?(preset)
            }
        }
    }

    private var statusRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.online ? (model.anyCharging ? Color.green : Color.secondary) : Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(model.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(model.online ? Color.primary : Color.secondary)

                Spacer(minLength: 8)

                Text(firmwareText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
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

    private var firmwareText: String {
        if let firmware = model.firmware { return "固件 \(firmware)" }
        return model.online ? "读取固件中…" : ""
    }
}

// MARK: - RFCOMM 接收

private final class Receiver: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onFrame: ((UInt16, UInt8, [UInt8]) -> Void)?
    var onClosed: (() -> Void)?
    private var buffer: [UInt8] = []

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        let incoming = Array(UnsafeRawBufferPointer(start: data, count: length))
        debugLog("raw-rx \(incoming.map { String(format: "%02x", $0) }.joined(separator: " "))")
        buffer.append(contentsOf: incoming)
        for frame in FrameCodec.drain(from: &buffer) {
            onFrame?(frame.opcode, frame.sequence, frame.payload)
        }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        onClosed?()
    }
}

// MARK: - 会话（长连接）

/// 耳机控制会话。独占一个后台线程（带 RunLoop），通道常开：
/// hello → 初始查询（电量/固件/音效）→ 之后靠主动上报刷新，每 15s 查一次电量当心跳。
/// 写命令只发一次，3 秒内等回报确认。
final class EncoLink {

    var onUpdate: ((Snapshot) -> Void)? = nil

    enum InboxCommand {
        case refresh
        case noise(NoiseMode, ANCLevel?)
        case eq(EQPreset)
        case reconnect
        case rawTest(opcode: UInt16, payload: [UInt8])
    }

    private enum QueryKind { case battery, deviceInfo, equalizer }

    private enum ItemKind {
        case hello
        case query(QueryKind)
        case writeNoise(mode: NoiseMode, level: ANCLevel?)
        case writeEQ(EQPreset)
        case rawTest(opcode: UInt16, payload: [UInt8])
    }

    private struct QueuedItem {
        let kind: ItemKind
        let frame: [UInt8]
        var attempts: Int = 0
    }

    private struct ActiveItem {
        let item: QueuedItem
        let deadline: Date
    }

    private struct PendingWrite {
        let mode: NoiseMode?
        let level: ANCLevel?
        let preset: EQPreset?
        let deadline: Date
    }

    private let keepaliveInterval: TimeInterval
    private var thread: Thread?
    private var stopped = false
    private let lock = NSLock()
    private var inbox: [InboxCommand] = []

    private var device: IOBluetoothDevice?
    private var receiver: Receiver?
    private var channel: IOBluetoothRFCOMMChannel?
    private var seq: UInt8 = 0
    private var waiting: [QueuedItem] = []
    private var active: ActiveItem?
    private var nextSendAt = Date.distantPast
    private var pendingWrite: PendingWrite?
    private var nextKeepalive = Date.distantPast
    private var lastFrameAt = Date.distantPast
    private var nextOpenAt = Date.distantPast

    private var snapshot = Snapshot()

    init(keepaliveInterval: TimeInterval) {
        self.keepaliveInterval = keepaliveInterval
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "EncoLink"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func send(_ command: InboxCommand) {
        lock.lock()
        inbox.append(command)
        lock.unlock()
    }

    // MARK: 主循环

    private func run() {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)
        while !stopped {
            tick(Date())
            runLoop.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private func tick(_ now: Date) {
        drainInbox()

        if channel == nil {
            if now >= nextOpenAt {
                openChannel()
            }
            return
        }

        // 链路哑了：15 秒没帧说明耳机那边已经没了，主动重建
        if now.timeIntervalSince(lastFrameAt) > kFrameSilenceAfter {
            debugLog("link silent \(Int(now.timeIntervalSince(lastFrameAt)))s, reopening")
            closeChannel(retryDelay: 1.5)
            return
        }

        // 心跳查询
        if now >= nextKeepalive {
            enqueue(.init(kind: .query(.battery), frame: makeQuery(0x0601)))
            nextKeepalive = now.addingTimeInterval(keepaliveInterval)
        }

        // 队列推进
        if active == nil, !waiting.isEmpty, now >= nextSendAt {
            let item = waiting.removeFirst()
            sendItem(item, now: now)
        }

        // 查询超时重试一次
        if let running = active, now >= running.deadline {
            active = nil
            var item = running.item
            item.attempts += 1
            if case .query = item.kind, item.attempts < 2 {
                waiting.insert(item, at: 0)
            }
        }

        // 写命令确认超时：不重试，报「未确认」
        if let write = pendingWrite, now >= write.deadline {
            pendingWrite = nil
            snapshot.pendingNoise = false
            snapshot.pendingEQ = false
            snapshot.lastError = write.preset != nil ? "音效设置未确认" : "降噪设置未确认"
            publish()
        }
    }

    private func drainInbox() {
        lock.lock()
        let commands = inbox
        inbox = []
        lock.unlock()

        for command in commands {
            switch command {
            case .refresh:
                if channel != nil { enqueue(.init(kind: .query(.battery), frame: makeQuery(0x0601))) }
            case .reconnect:
                closeChannel(retryDelay: 0)
                nextOpenAt = Date()
            case .rawTest(let opcode, let payload):
                guard channel != nil else {
                    debugLog("rawTest skipped: no channel")
                    continue
                }
                snapshot.lastError = nil
                publish()
                enqueueFront(.init(kind: .rawTest(opcode: opcode, payload: payload),
                                   frame: FrameCodec.make(opcode: opcode, seq: nextSeq(), payload: payload)))
            case .noise(let mode, let level):
                guard channel != nil else {
                    snapshot.lastError = "耳机未连接"
                    publish()
                    continue
                }
                guard pendingWrite == nil else {
                    snapshot.lastError = "上一条设置还没确认"
                    publish()
                    continue
                }
                let value = level?.commandValue ?? mode.commandValue
                snapshot.lastError = nil
                snapshot.pendingNoise = true
                publish()
                enqueueFront(.init(
                    kind: .writeNoise(mode: mode, level: level),
                    frame: FrameCodec.make(opcode: 0x0404, seq: nextSeq(), payload: [0x01, 0x01, value])))
            case .eq(let preset):
                guard channel != nil else {
                    snapshot.lastError = "耳机未连接"
                    publish()
                    continue
                }
                guard pendingWrite == nil else {
                    snapshot.lastError = "上一条设置还没确认"
                    publish()
                    continue
                }
                snapshot.lastError = nil
                snapshot.pendingEQ = true
                publish()
                enqueueFront(.init(
                    kind: .writeEQ(preset),
                    frame: FrameCodec.make(opcode: 0x0604, seq: nextSeq(), payload: [UInt8(preset.rawValue)])))
            }
        }
    }

    // MARK: 通道

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
        debugLog("no candidate among \(paired.count) paired devices")
        return nil
    }

    /// 通道号优先从 SDP record 拿，拿不到再退回 5
    private func resolveChannelID(_ dev: IOBluetoothDevice) -> UInt8 {
        let uuid = IOBluetoothSDPUUID(bytes: kServiceUUIDBytes, length: kServiceUUIDBytes.count)
        guard let record = dev.getServiceRecord(for: uuid) else {
            return kFallbackChannelID
        }
        var channelID: BluetoothRFCOMMChannelID = kFallbackChannelID
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            return kFallbackChannelID
        }
        return UInt8(channelID)
    }

    /// 第一次 open 必定超时（mux 建立），重试拿到真通道
    private func openChannel() {
        guard let dev = resolveDevice() else {
            snapshot.online = false
            publish()
            nextOpenAt = Date().addingTimeInterval(2)
            return
        }
        guard dev.isConnected() else {
            snapshot.online = false
            publish()
            nextOpenAt = Date().addingTimeInterval(2)
            return
        }

        let channelID = resolveChannelID(dev)
        let rx = Receiver()
        rx.onFrame = { [weak self] opcode, sequence, payload in
            self?.ingest(opcode: opcode, sequence: sequence, payload: payload)
        }
        rx.onClosed = { [weak self] in
            self?.closeChannel(retryDelay: 2)
        }

        for attempt in 1...3 {
            var opened: IOBluetoothRFCOMMChannel? = nil
            let started = Date()
            let result = dev.openRFCOMMChannelSync(&opened, withChannelID: channelID, delegate: rx)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            debugLog("open ch\(channelID) #\(attempt) -> 0x\(String(UInt32(bitPattern: result), radix: 16)) \(ms)ms")
            if result == kIOReturnSuccess, let opened {
                channel = opened
                receiver = rx
                lastFrameAt = Date()
                startSession()
                return
            }
            Thread.sleep(forTimeInterval: 0.35)
        }
        snapshot.online = false
        publish()
        nextOpenAt = Date().addingTimeInterval(5)
    }

    private func closeChannel(retryDelay: TimeInterval) {
        if let channel { channel.close() }
        channel = nil
        receiver = nil
        waiting.removeAll()
        active = nil
        pendingWrite = nil
        nextSendAt = Date.distantPast
        snapshot.pendingNoise = false
        snapshot.pendingEQ = false
        snapshot.online = false
        publish()
        nextOpenAt = Date().addingTimeInterval(retryDelay)
        debugLog("channel closed, retry in \(retryDelay)s")
    }

    /// hello + 初始查询。查询走串行队列，间隔 0.2s 自然铺开
    private func startSession() {
        enqueue(.init(kind: .hello, frame: FrameCodec.make(opcode: 0x0001, seq: nextSeq(), payload: [])))
        enqueue(.init(kind: .query(.battery), frame: makeQuery(0x0601)))
        enqueue(.init(kind: .query(.deviceInfo), frame: makeQuery(0x0501)))
        enqueue(.init(kind: .query(.equalizer), frame: makeQuery(0x0f01)))
        nextKeepalive = Date().addingTimeInterval(keepaliveInterval)
    }

    // MARK: 收发

    private func makeQuery(_ opcode: UInt16) -> [UInt8] {
        FrameCodec.make(opcode: opcode, seq: nextSeq(), payload: [])
    }

    private func nextSeq() -> UInt8 {
        seq &+= 1
        return seq
    }

    private func enqueue(_ item: QueuedItem) {
        waiting.append(item)
    }

    private func enqueueFront(_ item: QueuedItem) {
        waiting.insert(item, at: 0)
    }

    private func sendItem(_ item: QueuedItem, now: Date) {
        guard let channel else { return }
        var bytes = item.frame
        let result = bytes.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            channel.writeSync(pointer.baseAddress!, length: UInt16(item.frame.count))
        }
        debugLog("tx \(item.frame.map { String(format: "%02x", $0) }.joined(separator: " ")) w=0x\(String(UInt32(bitPattern: result), radix: 16))")
        nextSendAt = now.addingTimeInterval(0.2)

        switch item.kind {
        case .query:
            active = ActiveItem(item: item, deadline: now.addingTimeInterval(1.5))
        case .hello:
            break
        case .writeNoise(let mode, let level):
            pendingWrite = PendingWrite(mode: mode, level: level, preset: nil, deadline: now.addingTimeInterval(3))
        case .writeEQ(let preset):
            pendingWrite = PendingWrite(mode: nil, level: nil, preset: preset,
                                        deadline: now.addingTimeInterval(3))
            // 音效写完立刻读回确认（耳机的写完上报不一定发）
            enqueue(.init(kind: .query(.equalizer), frame: makeQuery(0x0f01)))
        case .rawTest:
            break // 裸探测：只看 0484/回显，不做状态跟踪
        }
    }

    // MARK: 解析

    private func ingest(opcode: UInt16, sequence: UInt8, payload: [UInt8]) {
        lastFrameAt = Date()
        debugLog("rx \(String(format: "%04x", opcode)) \(payload.map { String(format: "%02x", $0) }.joined(separator: " "))")
        var changed = false

        switch opcode {
        case 0x0681: // 电量查询回包：status + count + (id, 值)... 这里 0 是真 0%
            guard payload.count >= 2, payload[0] == 0 else { break }
            let count = Int(payload[1])
            var left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil
            var leftCharging = false, rightCharging = false, caseCharging = false
            for i in 0..<count {
                let base = 2 + i * 2
                guard base + 1 < payload.count else { break }
                let raw = Int(payload[base + 1])
                let level = raw & 0x7f
                let charging = raw & 0x80 != 0
                switch payload[base] {
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
            changed = true
            finishQuery(.battery)

        case 0x0402: // 主动状态上报：电量 0 = 休眠，语义和查询回包不同
            let report = StatusReport.parse(payload)
            for entry in report.battery {
                let charging = entry.raw & 0x80 != 0
                let level: Int? = entry.raw == 0 ? nil : Int(entry.raw & 0x7f)
                switch entry.id {
                case 1:
                    snapshot.left = level
                    snapshot.leftCharging = charging
                case 2:
                    snapshot.right = level
                    snapshot.rightCharging = charging
                case 3:
                    snapshot.caseLevel = level
                    snapshot.caseCharging = charging
                default: break
                }
            }
            for entry in report.placement where entry.id == 1 || entry.id == 2 {
                // 进仓且没在充电：旧电量作废，等重新上报
                guard entry.value == 0x04 else { continue }
                let charging = entry.id == 1 ? snapshot.leftCharging : snapshot.rightCharging
                guard !charging else { continue }
                if entry.id == 1 { snapshot.left = nil } else { snapshot.right = nil }
            }
            if report.hasNoise, let value = report.noiseValue, let decoded = ANCLevel.from(reportValue: value) {
                snapshot.noiseMode = decoded.mode
                snapshot.noiseLevel = decoded.level
                confirmNoiseWrite(mode: decoded.mode, level: decoded.level)
            }
            snapshot.updatedAt = Date()
            changed = true

        case 0x0581: // 设备信息回包：status + 条目数 + UTF-8 CSV
            guard payload.count >= 2, payload[0] == 0 else { break }
            let csvData = Data(payload[2...])
            let fields = (String(data: csvData, encoding: .utf8) ?? "")
                .split(separator: ",").map(String.init)
            var byType: [String: String] = [:]
            for triple in stride(from: 0, to: fields.count - 2, by: 3) {
                let deviceType = fields[triple]
                let versionType = fields[triple + 1]
                let value = fields[triple + 2]
                if versionType == "2" { byType[deviceType] = value }
            }
            if let l = byType["1"], let r = byType["2"], let c = byType["3"] {
                snapshot.firmware = "\(l).\(r).\(c)"
            }
            changed = true
            finishQuery(.deviceInfo)

        case 0x0f81: // 均衡器查询回包：status + preset
            guard payload.count >= 2, payload[0] == 0, let preset = EQPreset.from(raw: payload[1]) else { break }
            snapshot.eq = preset
            changed = true
            finishQuery(.equalizer)
            confirmEQWrite(preset: preset)

        case 0x0405: // 均衡器主动上报：preset
            guard let preset = payload.first.flatMap({ EQPreset.from(raw: $0) }) else { break }
            snapshot.eq = preset
            changed = true
            confirmEQWrite(preset: preset)

        case 0x0484, 0x0684: // SET 回执：payload 首字节 00=受理，非 0=拒绝（如耳机在盒内）
            guard let status = payload.first, status != 0 else { break } // 00 时等回显确认
            let isEQ = opcode == 0x0684
            guard let write = pendingWrite,
                  (isEQ ? write.preset != nil : write.mode != nil) else { break }
            pendingWrite = nil
            snapshot.pendingNoise = false
            snapshot.pendingEQ = false
            snapshot.lastError = isEQ
                ? "耳机拒绝了音效设置（可能不在佩戴状态）"
                : "耳机拒绝了降噪设置（可能不在佩戴状态）"
            changed = true

        default:
            break
        }

        if changed {
            snapshot.online = true
            publish()
        }
    }

    private func finishQuery(_ kind: QueryKind) {
        guard let running = active, case .query(let runningKind) = running.item.kind, runningKind == kind else { return }
        active = nil
    }

    private func confirmNoiseWrite(mode: NoiseMode, level: ANCLevel?) {
        guard let write = pendingWrite, write.mode != nil else { return }
        guard write.mode == mode, write.level == nil || write.level == level else { return }
        pendingWrite = nil
        snapshot.pendingNoise = false
        snapshot.lastError = nil
        publish()
    }

    private func confirmEQWrite(preset: EQPreset) {
        guard let write = pendingWrite, write.preset != nil else { return }
        guard write.preset == preset else { return }
        pendingWrite = nil
        snapshot.pendingEQ = false
        snapshot.lastError = nil
        publish()
    }

    // MARK: 发布

    private func publish() {
        snapshot.online = snapshot.online && channel != nil
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
        let reconnectItem = menu.addItem(withTitle: "重连耳机", action: #selector(reconnect), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 EncoBattery", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        return menu
    }()

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
        let popoverView = BatteryPopover(
            model: model,
            onSetNoise: { [weak self] mode, level in self?.setNoise(mode, level) },
            onSetEQ: { [weak self] preset in self?.setEQ(preset) })
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
        debugLog("started")
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
        guard !fakeActive, model.online else { return }
        model.pendingNoise = true
        model.lastError = nil
        link?.send(.noise(mode, level))
    }

    private func setEQ(_ preset: EQPreset) {
        guard !fakeActive, model.online else { return }
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

// MARK: - 演示数据（截图与预览）

func applyFake(_ fake: String, to model: BatteryModel) {
    model.name = "OPPO Enco Air5 Pro"
    model.firmware = "158.158.105"
    switch fake {
    case "charging":
        model.online = true
        model.left = 82; model.right = 80; model.caseLevel = 96
        model.leftCharging = false; model.rightCharging = true; model.caseCharging = true
        model.noiseMode = .off
        model.eq = .original
    case "empty":
        model.online = true
        model.left = 46; model.right = 45
    case "anc":
        model.online = true
        model.left = 82; model.right = 80; model.caseLevel = 96
        model.caseCharging = true
        model.noiseMode = .noise; model.noiseLevel = .max
        model.eq = .original
    case "smart":
        model.online = true
        model.left = 64; model.right = 62
        model.noiseMode = .noise; model.noiseLevel = .smart
        model.eq = .vocals
    case "eq":
        model.online = true
        model.left = 64; model.right = 62
        model.noiseMode = .transparency
        model.eq = .vocals
    case "offline":
        model.online = false
        model.firmware = nil
    default: // full
        model.online = true
        model.left = 82; model.right = 80; model.caseLevel = 96
        model.caseCharging = true
        model.noiseMode = .noise; model.noiseLevel = .moderate
        model.eq = .original
    }
    model.lastUpdate = Date()
}

// 合成截图：菜单栏图标 + 三角指引 + 弹窗卡片，用于文档/README
private struct ShotTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct BatteryShot: View {
    @ObservedObject var model: BatteryModel
    let dark: Bool

    private var background: LinearGradient {
        dark
            ? LinearGradient(colors: [Color(red: 0.14, green: 0.14, blue: 0.15), Color(red: 0.07, green: 0.07, blue: 0.08)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.97, green: 0.97, blue: 0.98), Color(red: 0.89, green: 0.89, blue: 0.91)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var cardFill: Color { dark ? Color(red: 0.24, green: 0.24, blue: 0.26) : Color.white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "earbuds")
                    .font(.system(size: 13, weight: .medium))
                Text("\(model.overallLevel ?? 0)%")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(dark ? Color.white.opacity(0.05) : Color.white.opacity(0.5))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            }

            VStack(spacing: 0) {
                ShotTriangle()
                    .fill(cardFill)
                    .frame(width: 20, height: 10)
                BatteryPopover(model: model)
                    .background(cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .compositingGroup()
            .shadow(color: .black.opacity(dark ? 0.6 : 0.22), radius: 24, y: 12)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .frame(width: 456)
        .background(background)
    }
}

// 离屏渲染电量卡片，用于文档/截图：EB_RENDER=/tmp/card.png EB_FAKE=charging EB_APPEARANCE=dark
@MainActor func renderShot(to path: String, fake: String, dark: Bool) {
    let model = makeFakeModel(fake, dark: dark)
    let content = BatteryShot(model: model, dark: dark)
        .environment(\.colorScheme, dark ? .dark : .light)
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

@MainActor func makeFakeModel(_ fake: String, dark: Bool) -> BatteryModel {
    let model = BatteryModel()
    applyFake(fake, to: model)
    return model
}

@MainActor func renderCard(to path: String, fake: String, dark: Bool) {
    let model = makeFakeModel(fake, dark: dark)
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

if let output = ProcessInfo.processInfo.environment["EB_SHOT"] {
    let dark = ProcessInfo.processInfo.environment["EB_APPEARANCE"] == "dark"
    let fake = ProcessInfo.processInfo.environment["EB_FAKE"] ?? "full"
    if #available(macOS 14.0, *) {
        MainActor.assumeIsolated { renderShot(to: output, fake: fake, dark: dark) }
    }
    exit(0)
}

if let output = ProcessInfo.processInfo.environment["EB_RENDER"] {
    if let appearance = ProcessInfo.processInfo.environment["EB_APPEARANCE"] {
        app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    }
    let fake = ProcessInfo.processInfo.environment["EB_FAKE"] ?? "full"
    if #available(macOS 14.0, *) {
        MainActor.assumeIsolated { renderCard(to: output, fake: fake, dark: ProcessInfo.processInfo.environment["EB_APPEARANCE"] == "dark") }
    }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
