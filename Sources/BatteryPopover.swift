import SwiftUI

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

// MARK: - 分段选择（样式对齐系统分段控件，选中指示带滑动动画）

private struct SegmentedRow<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, label: String)]
    let selection: Value?
    let disabled: Bool
    let action: (Value) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
        )
        .opacity(disabled ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(selection.flatMap { selected in
            options.first { $0.value == selected }?.label
        } ?? "未选择")
    }

    @ViewBuilder private func segment(_ option: (value: Value, label: String)) -> some View {
        let selected = selection == option.value
        Button {
            debugLog("segment-tap \(label)/\(option.label) disabled=\(disabled)")
            guard !disabled else { return }
            action(option.value)
        } label: {
            Text(option.label)
                .font(.subheadline.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(minHeight: 18)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selected", in: indicator)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - 浮层内容

struct BatteryPopover: View {
    @ObservedObject var model: BatteryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var soundExpanded = ProcessInfo.processInfo.environment["EB_EXPAND"] == "1"
    @State private var soundVisible = ProcessInfo.processInfo.environment["EB_EXPAND"] == "1"
    @State private var revealProgress: CGFloat = ProcessInfo.processInfo.environment["EB_EXPAND"] == "1" ? 1 : 0
    @State private var detailsHeight: CGFloat = 66
    @State private var revealTimer: Timer?
    var onSetNoise: ((NoiseMode, ANCLevel?) -> Void)? = nil
    var onSetEQ: ((EQPreset) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    private var controlsDisabled: Bool { !model.online }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 9) {
                LevelRow(badge: "L", title: "左耳", level: model.left, charging: model.leftCharging)
                LevelRow(badge: "R", title: "右耳", level: model.right, charging: model.rightCharging)
                LevelRow(badge: "仓", title: "充电仓", level: model.caseLevel, charging: model.caseCharging)
            }
            Divider()
            soundSection
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
        .onAppear {
            if let delay = Double(ProcessInfo.processInfo.environment["EB_EXPAND_AFTER"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    toggleSound()
                }
            }
            if let delay = Double(ProcessInfo.processInfo.environment["EB_COLLAPSE_AFTER"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if soundExpanded { toggleSound() }
                }
            }
        }
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

    /// 展开/收起声音设置。NSPopover 的窗口尺寸没有原生动画（实测单帧瞬跳），
    /// 所以这里手动逐帧驱动容器高度：SwiftUI 每帧重排 → 宿主视图 fittingSize
    /// 逐帧变化 → popover 窗口逐帧跟随，窗口和内容才动得同步。
    private func toggleSound() {
        let expanding = !soundExpanded
        soundExpanded = expanding
        revealTimer?.invalidate()
        if reduceMotion {
            revealProgress = expanding ? 1 : 0
            soundVisible = expanding
            return
        }
        if expanding { soundVisible = true }
        let from = revealProgress
        let to: CGFloat = expanding ? 1 : 0
        let start = Date()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let x = min(Date().timeIntervalSince(start) / 0.2, 1)
            let eased = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
            revealProgress = from + (to - from) * CGFloat(eased)
            if x >= 1 {
                timer.invalidate()
                revealProgress = to
                if !expanding { soundVisible = false }
            }
        }
    }

    /// 「声音设置」入口行：默认折叠只显示摘要，点击展开详细控制。
    private var soundSection: some View {
        VStack(spacing: 0) {
            Button {
                toggleSound()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text("声音设置")
                        .font(.subheadline)

                    Text(soundSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if model.pendingNoise || model.pendingEQ {
                        ProgressView().controlSize(.mini)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(revealProgress * 90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("声音设置，\(soundSummary)")
            .accessibilityHint(soundExpanded ? "折叠" : "展开")

            ZStack(alignment: .top) {
                if soundVisible {
                    VStack(spacing: 10) {
                        noiseSection
                        eqSection
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { detailsHeight = geo.size.height }
                            .onChange(of: geo.size.height) { detailsHeight = $0 }
                    })
                    .padding(.top, 10)
                }
            }
            .frame(height: revealProgress * (detailsHeight + 10))
            .clipped()
        }
    }

    private var soundSummary: String {
        let noise: String
        switch model.noiseMode {
        case .noise:
            noise = "降噪" + (model.noiseLevel.map { "·\($0.label)" } ?? "")
        case .some(let mode):
            noise = mode.label
        case .none:
            noise = "未知"
        }
        return "\(noise) · \(model.eq.map { $0.label } ?? "未知")"
    }

    private var noiseSection: some View {
        VStack(spacing: 10) {
            controlRow(label: "降噪", pending: model.pendingNoise) {
                SegmentedRow(
                    label: "降噪模式",
                    options: [NoiseMode.noise, .transparency, .off].map { ($0, $0.label) },
                    selection: model.noiseMode,
                    disabled: controlsDisabled || model.pendingNoise
                ) { mode in
                    onSetNoise?(mode, nil)
                }
            }
            if model.noiseMode == .noise {
                controlRow(label: "强度") {
                    SegmentedRow(
                        label: "降噪强度",
                        options: ANCLevel.allCases.map { ($0, $0.label) },
                        selection: model.noiseLevel,
                        disabled: controlsDisabled || model.pendingNoise
                    ) { level in
                        onSetNoise?(.noise, level)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.noiseMode == .noise)
    }

    private var eqSection: some View {
        controlRow(label: "音效", pending: model.pendingEQ) {
            SegmentedRow(
                label: "音效预设",
                options: [EQPreset.original, .vocals, .bass].map { ($0, $0.label) },
                selection: model.eq,
                disabled: controlsDisabled || model.pendingEQ
            ) { preset in
                onSetEQ?(preset)
            }
        }
    }

    private func controlRow<Control: View>(label: String, pending: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            if pending { ProgressView().controlSize(.mini) }
            Spacer(minLength: 12)
            control()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
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

            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
            .accessibilityLabel("设置")
        }
    }

}
