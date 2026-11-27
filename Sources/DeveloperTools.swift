import AppKit
import SwiftUI

func runRenderHook() {
    let environment = ProcessInfo.processInfo.environment
    if let output = environment["EB_SHOT"] {
        let dark = environment["EB_APPEARANCE"] == "dark"
        let fake = environment["EB_FAKE"] ?? "full"
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated { renderShot(to: output, fake: fake, dark: dark) }
        }
        exit(0)
    }

    if let output = environment["EB_RENDER"] {
        if let appearance = environment["EB_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let fake = environment["EB_FAKE"] ?? "full"
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated { renderCard(to: output, fake: fake, dark: environment["EB_APPEARANCE"] == "dark") }
        }
        exit(0)
    }

    if let output = environment["EB_RENDER_SETTINGS"] {
        if let appearance = environment["EB_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated { renderSettings(to: output, dark: environment["EB_APPEARANCE"] == "dark") }
        }
        exit(0)
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
@MainActor private func renderShot(to path: String, fake: String, dark: Bool) {
    let model = makeFakeModel(fake)
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

@MainActor private func makeFakeModel(_ fake: String) -> BatteryModel {
    let model = BatteryModel()
    applyFake(fake, to: model)
    return model
}

@MainActor private func renderCard(to path: String, fake: String, dark: Bool) {
    let model = makeFakeModel(fake)
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

@MainActor private func renderSettings(to path: String, dark: Bool) {
    let model = BatteryModel()
    applyFake("full", to: model)
    let content = SettingsPage(settings: SettingsStore(), model: model)
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
