import Combine
import Foundation
import SwiftUI

// MARK: - 设置（持久化到 UserDefaults）

final class SettingsStore: ObservableObject {
    /// 菜单栏图标开关；关掉后图标从菜单栏消失，从 Dock 点图标能回到设置
    @Published var menuBarIconVisible: Bool {
        didSet { UserDefaults.standard.set(menuBarIconVisible, forKey: Self.kMenuBarIconVisible) }
    }
    /// 菜单栏分耳显示：三格各自开关，全关就是单数字模式
    @Published var showLeftInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showLeftInMenuBar, forKey: Self.kMenuBarShowLeft) }
    }
    @Published var showRightInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showRightInMenuBar, forKey: Self.kMenuBarShowRight) }
    }
    @Published var showCaseInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showCaseInMenuBar, forKey: Self.kMenuBarShowCase) }
    }

    private static let kMenuBarIconVisible = "EBMenuBarIconVisible"
    private static let kMenuBarShowLeft = "EBMenuBarShowLeft"
    private static let kMenuBarShowRight = "EBMenuBarShowRight"
    private static let kMenuBarShowCase = "EBMenuBarShowCase"

    init() {
        let d = UserDefaults.standard
        menuBarIconVisible = d.object(forKey: Self.kMenuBarIconVisible) as? Bool ?? true
        showLeftInMenuBar = d.object(forKey: Self.kMenuBarShowLeft) as? Bool ?? false
        showRightInMenuBar = d.object(forKey: Self.kMenuBarShowRight) as? Bool ?? false
        showCaseInMenuBar = d.object(forKey: Self.kMenuBarShowCase) as? Bool ?? false

        // 2.1.0 早期的总开关迁移成三格
        if let legacy = d.object(forKey: "EBMenuBarDetailed") as? Bool {
            if legacy && !showLeftInMenuBar && !showRightInMenuBar && !showCaseInMenuBar {
                showLeftInMenuBar = true
                showRightInMenuBar = true
                showCaseInMenuBar = true
            }
            d.removeObject(forKey: "EBMenuBarDetailed")
        }
    }
}

// MARK: - 设置页

struct SettingsPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: BatteryModel

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return version.isEmpty ? "—" : "\(version) (\(build))"
    }

    private var firmwareText: String {
        if let firmware = model.firmware { return firmware }
        return model.online ? "正在读取…" : "未连接"
    }

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("显示图标", isOn: $settings.menuBarIconVisible)
                Toggle("左耳电量", isOn: $settings.showLeftInMenuBar)
                    .disabled(!settings.menuBarIconVisible)
                Toggle("右耳电量", isOn: $settings.showRightInMenuBar)
                    .disabled(!settings.menuBarIconVisible)
                Toggle("充电仓电量", isOn: $settings.showCaseInMenuBar)
                    .disabled(!settings.menuBarIconVisible)
            }
            Section("关于") {
                LabeledContent("固件版本", value: firmwareText)
                LabeledContent("版本", value: versionText)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .frame(width: 360, height: 372)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.primary.opacity(colorScheme == .light ? 0.08 : 0))
                .ignoresSafeArea()
        }
    }
}
