import Foundation
import IOBluetooth

private let kServiceUUIDBytes: [UInt8] = [
    0x00, 0x00, 0x07, 0x9a, 0xd1, 0x02, 0x11, 0xe1,
    0x9b, 0x23, 0x00, 0x02, 0x5b, 0x00, 0xa5, 0xa5,
]
private let kFallbackChannelID: UInt8 = 5
private let kFrameSilenceAfter: TimeInterval = 15 // 通道还开着但 15 秒没帧 = 链路已经断了

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
    /// 左右耳放置状态（id 1/2 → 是否在盒内）。absent = 未知。
    /// 耳机只有进盒才可能充电；佩戴中上报/回包里的充电位不可信，用它做门禁。
    private var sideInCase: [UInt8: Bool] = [:]

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
                var charging = raw & 0x80 != 0
                let slot = payload[base]
                if slot == 1 || slot == 2 {
                    if sideInCase[slot] == false { charging = false } // 佩戴中充电位不可信
                }
                switch slot {
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
                var charging = entry.raw & 0x80 != 0
                let level: Int? = entry.raw == 0 ? nil : Int(entry.raw & 0x7f)
                if entry.id == 1 || entry.id == 2 {
                    // 佩戴中的耳机不可能在充电：已知盒外时忽略充电位
                    if sideInCase[entry.id] == false { charging = false }
                }
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
                switch entry.value {
                case 0x04: sideInCase[entry.id] = true // 盒内
                case 0x05: sideInCase[entry.id] = false // 盒外（佩戴）→ 充电态立即作废
                    if entry.id == 1 { snapshot.leftCharging = false } else { snapshot.rightCharging = false }
                default: sideInCase.removeValue(forKey: entry.id) // 过渡态不可知
                }
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
