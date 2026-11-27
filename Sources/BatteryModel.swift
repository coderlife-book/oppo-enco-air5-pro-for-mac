import Combine
import Foundation

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

    func apply(_ s: EncoLink.Snapshot) {
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
