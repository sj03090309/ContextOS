import SwiftUI
import AppKit
import ServiceManagement
import ContextOSCore

// MARK: - Tabs

/// A pill-shaped segmented control whose highlight slides between segments.
struct PanelTabBar: View {
    @Binding var selection: DashboardTab
    @Namespace private var pill

    var body: some View {
        SlidingSegments(options: DashboardTab.allCases, selection: $selection,
                        label: \.label, namespace: pill, height: 28)
    }
}

/// The sliding-highlight segments the tab bar and the settings share.
struct SlidingSegments<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    let namespace: Namespace.ID
    var height: CGFloat = 28

    init(options: [Option], selection: Binding<Option>, label: KeyPath<Option, String>,
         namespace: Namespace.ID, height: CGFloat = 28) {
        self.options = options
        self._selection = selection
        self.label = { $0[keyPath: label] }
        self.namespace = namespace
        self.height = height
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.14))
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updated(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                PanelIconButton(symbol: "arrow.clockwise", help: "새로고침 (⌘R)") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                PanelIconButton(symbol: "list.bullet.rectangle", help: "빌드 로그 (⌘B)") { BuildLogWindow.show() }
                    .keyboardShortcut("b", modifiers: .command)
                PanelIconButton(symbol: "gearshape", help: "설정", isOn: ui.showSettings) {
                    ui.showSettings.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 11)
        }
    }

    private func updated(now: Date) -> String {
        guard let last = model.lastUpdated else { return "불러오는 중…" }
        let ago = LiveHeader.ago(last, now: now)
        return ago == "방금" ? "방금 업데이트됨" : ago + " 업데이트"
    }
}

/// A square icon button with a soft fill that brightens on hover.
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(isOn ? 0.16 : hovering ? 0.12 : 0.07),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .primary : .secondary)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Settings

/// The gear's menu, drawn inside the panel over a dimmed backdrop.
struct SettingsOverlay: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var motionPill

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { ui.showSettings = false }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("설정")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                LaunchAtLoginRow()
                toggleRow("메뉴바에 오늘 아낀 토큰", isOn: $settings.showMenuBarSavings)
                separator
                VStack(alignment: .leading, spacing: 8) {
                    Text("뭉치 움직임").font(.system(size: 13))
                    SlidingSegments(options: AppSettings.MascotMotion.allCases,
                                    selection: $settings.mascotMotion,
                                    label: \.label, namespace: motionPill, height: 26)
                    Text(settings.mascotMotion.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                separator
                menuRow("빌드 로그 열기", symbol: "list.bullet.rectangle", shortcut: "⌘B") {
                    ui.showSettings = false
                    BuildLogWindow.show()
                }
                menuRow("지금 새로고침", symbol: "arrow.clockwise", shortcut: "⌘R") {
                    ui.showSettings = false
                    model.refresh()
                }
                menuRow("AI 도구 모두 연결", symbol: "link") {
                    ui.showSettings = false
                    ui.tab = .ai
                    model.connectAll()
                }
                separator
                menuRow("ContextOS 종료", symbol: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
            .frame(width: 290)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .padding(.trailing, 12)
            .padding(.bottom, 52)
            .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
        }
        .onExitCommand { ui.showSettings = false }
    }

    private var separator: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        SettingsSwitchRow(title: title, isOn: isOn)
    }

    private func menuRow(_ title: String, symbol: String, shortcut: String? = nil,
                         action: @escaping () -> Void) -> some View {
        MenuRowButton(title: title, symbol: symbol, shortcut: shortcut, action: action)
    }
}

/// One menu item: icon, title, shortcut hint, highlighted under the pointer.
private struct MenuRowButton: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(hovering ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A settings line: the title on the left, a small switch on the right edge.
struct SettingsSwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

/// "로그인 시 시작" — registers the app as a login item via SMAppService.
/// Registration only works from a real .app bundle; a `swift run` build fails
/// silently and the switch snaps back to the actual state.
private struct LaunchAtLoginRow: View {
    /// Read when the row shows, not as the `@State` default: SwiftUI rebuilds
    /// this struct on every update, a default expression runs on each rebuild,
    /// and `SMAppService.status` is an XPC round trip to the login-items daemon.
    @State private var enabled: Bool?

    var body: some View {
        SettingsSwitchRow(title: "로그인 시 시작", isOn: Binding(
            get: { enabled ?? false },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    enabled = on
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }))
        .onAppear { enabled = SMAppService.mainApp.status == .enabled }
    }
}
