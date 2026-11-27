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
