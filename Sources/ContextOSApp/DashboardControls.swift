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
    @Environment(\.accessibilityReduceMotion) private var reduced
    @FocusState private var focusedOption: Option?
    @State private var hovered: Option?
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
                    guard selection != option else { return }
                    withAnimation(PanelMotion.response(reduced: reduced)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? Brand.onAccent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Brand.accent)
                                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            } else if hovered == option {
                                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .focused($focusedOption, equals: option)
                .onHover { hovered = $0 ? option : nil }
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Brand.accent.opacity(focusedOption == option ? 0.85 : 0), lineWidth: 2)
                    .padding(-2))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onMoveCommand { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            let delta = direction == .right ? 1 : direction == .left ? -1 : 0
            guard delta != 0 else { return }
            let next = min(options.count - 1, max(0, index + delta))
            withAnimation(PanelMotion.response(reduced: reduced)) { selection = options[next] }
            focusedOption = options[next]
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState
    var surface: DashboardSurface = .popover
    @State private var refreshTurn = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updated(now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if surface == .popover, let openWindow = ui.openWindow {
                    PanelIconButton(symbol: "macwindow", help: "창으로 열기 (⇧⌘O)", action: openWindow)
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                }
                PanelIconButton(symbol: ui.hidePrivateDetails ? "eye.slash" : "eye",
                                help: ui.hidePrivateDetails ? "개인 정보 표시" : "개인 정보 숨기기",
                                isOn: ui.hidePrivateDetails) {
                    ui.hidePrivateDetails.toggle()
                }
                .accessibilityValue(ui.hidePrivateDetails ? "숨김" : "표시 중")
                PanelIconButton(symbol: "arrow.clockwise", help: "새로고침 (⌘R)", rotation: .degrees(refreshTurn)) {
                    // One turn acknowledges this action. Background collection
                    // never starts an idle animation or a second timer.
                    refreshTurn += 360
                    model.refresh()
                }
                    .keyboardShortcut("r", modifiers: .command)
                if !ui.hidePrivateDetails {
                    PanelIconButton(symbol: "list.bullet.rectangle", help: "빌드 로그 (⌘B)") { BuildLogWindow.show() }
                        .keyboardShortcut("b", modifiers: .command)
                }
                PanelIconButton(symbol: "gearshape", help: "설정", isOn: ui.showSettings) {
                    ui.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 11)
        }
    }

    private func updated(now: Date) -> String {
        guard let last = model.lastUpdated else { return "불러오는 중…" }
        let ago = LiveHeader.ago(last, now: now)
        return "통계 확인 " + ago
    }
}

/// A square icon button with a soft fill that brightens on hover.
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var rotation: Angle = .zero
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(reduced ? .identity : .symbolEffect(.replace))
                .rotationEffect(reduced ? .zero : rotation)
                .animation(reduced ? nil : .easeInOut(duration: 0.45), value: rotation)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(isOn ? 0.13 : hovering && isEnabled ? 0.09 : 0.035),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .foregroundStyle(isOn ? Brand.accent : Color.secondary)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Brand.accent.opacity(focused && isEnabled ? 0.8 : 0), lineWidth: 2)
            .allowsHitTesting(false))
        .onHover { hovering = $0 }
        .animation(PanelMotion.feedback(reduced: reduced), value: hovering)
        .animation(PanelMotion.feedback(reduced: reduced), value: symbol)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Settings

struct ConnectionSettingsOverlay: View {
    @EnvironmentObject private var ui: DashboardUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 연결 설정").font(.system(size: 16, weight: .semibold))
                Spacer()
                PanelIconButton(symbol: "xmark", help: "AI 연결 설정 닫기") { ui.showConnections = false }
                    .keyboardShortcut(.cancelAction)
            }
            Button(ui.hidePrivateDetails ? "개인 정보 표시" : "개인 정보 숨기기") {
                ui.hidePrivateDetails.toggle()
            }
            .buttonStyle(PanelPressStyle())
            .font(.system(size: 11.5))
            .foregroundStyle(Brand.accent)
            ScrollView { AgentsList() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.canvas)
        .onExitCommand { ui.showConnections = false }
        .accessibilityAddTraits(.isModal)
    }
}

/// Preferences in the dashboard, with a close button that stays in view.
struct SettingsOverlay: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var ui: DashboardUIState
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var motionPill

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { ui.showSettings = false }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Text("설정").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    PanelIconButton(symbol: "xmark", help: "설정 닫기") { ui.showSettings = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Divider()
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            mascotSettings
                            separator
                            privacySettings.id(DashboardUIState.SettingsDestination.privacy)
                            separator
                            appSettings
                        }
                        .padding(6)
                    }
                    .onAppear {
                        if let destination = ui.settingsDestination {
                            scroll.scrollTo(destination, anchor: .top)
                        }
                    }
                }
            }
            .frame(width: 290)
            .frame(maxHeight: max(120, min(480, ui.panelHeight - 100)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .padding(.trailing, 12)
            .padding(.bottom, 52)
            .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
        }
        .onExitCommand { ui.showSettings = false }
        .accessibilityAddTraits(.isModal)
    }

    private var mascotSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            MascotColorSettings(settings: settings)
            VStack(alignment: .leading, spacing: 5) {
                Text("뭉치 움직임").font(.system(size: 13))
                SlidingSegments(options: AppSettings.MascotMotion.allCases,
                                selection: $settings.mascotMotion,
                                label: \.label, namespace: motionPill, height: 26)
                Text(settings.mascotMotion.hint)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("개인 정보")
            SettingsSwitchRow(title: "화면에서 개인 정보 숨기기", isOn: $ui.hidePrivateDetails)
            SettingsSwitchRow(title: "AI 로컬 로그 집계", isOn: $settings.agentLogsEnabled)
            Text("Claude Code·Codex의 로컬 세션 파일을 읽어 사용량과 작업 상태를 집계해요. 파일에는 대화·도구 출력이 포함될 수 있어요. 끄면 새 로그 읽기를 중지하며 기존 기록은 보존해요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.bottom, 8)
            Text("선택한 프로젝트 코드는 연결한 AI 도구에 전달되며, 외부 전송은 그 도구의 설정을 따라요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
    }

    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("앱")
            LaunchAtLoginRow()
            SettingsSwitchRow(title: "메뉴 막대에 오늘 아낀 토큰", isOn: $settings.showMenuBarSavings)
            separator
            if !ui.hidePrivateDetails {
                MenuRowButton(title: "빌드 로그 열기", symbol: "list.bullet.rectangle", shortcut: "⌘B") {
                    ui.showSettings = false
                    BuildLogWindow.show()
                }
            }
            MenuRowButton(title: "지금 새로고침", symbol: "arrow.clockwise", shortcut: "⌘R") {
                ui.showSettings = false
                model.refresh()
            }
            MenuRowButton(title: "AI 연결 설정", symbol: "link", shortcut: nil) {
                ui.showSettings = false
                ui.showConnections = true
            }
            MenuRowButton(title: "ContextOS 종료", symbol: "power", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private struct MascotColorSettings: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsCustomColor = false
    @State private var draft = MascotColorDraft(hex: MascotColor.mint.hex)
    @FocusState private var focusedPreset: MascotColor?

    var body: some View {
        let selectedTint = showsCustomColor ? draft.hex : settings.mascotTint
        let selectedPreset = MascotColor.allCases.first { $0.hex == selectedTint }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("뭉치 색상").font(.system(size: 13))
                Spacer()
                Text(selectedPreset?.label ?? "직접 선택한 색")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(MascotColor.allCases) { preset in
                    let selected = preset.hex == selectedTint
                    Button {
                        if showsCustomColor {
                            draft = MascotColorDraft(hex: preset.hex)
                        } else {
                            settings.setMascotTint(preset.hex)
                        }
                    } label: {
                        ZStack {
                            Circle().strokeBorder(selected || focusedPreset == preset ? Brand.accent : .clear,
                                                  lineWidth: 1.5)
                                .frame(width: 26, height: 26)
                            Circle().fill(preset.swatch)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                .frame(width: 20, height: 20)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.75))
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 31)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelPressStyle())
                    .focused($focusedPreset, equals: preset)
                    .help(preset.label)
                    .accessibilityLabel(preset.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if showsCustomColor {
                customEditor
            } else {
                Button {
                    draft = MascotColorDraft(hex: settings.mascotTint)
                    showsCustomColor = true
                } label: {
                    Label("색상 직접 선택", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityLabel("뭉치 색상 직접 선택")
            }
        }
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                MungchiFace(palette: MungchiPalette(hex: draft.hex, dark: colorScheme == .dark), gaze: 0)
                    .frame(width: 30, height: 26)
                    .accessibilityHidden(true)
                Text("색상 미리보기")
                    .font(.system(size: 11, weight: .medium))
            }
            colorSlider("색상", value: hueSelection,
                        colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                        spokenValue: "\(Int((draft.hue * 360).rounded()))도")
            colorSlider("채도", value: $draft.saturation,
                        colors: [Color(hue: draft.hue, saturation: 0, brightness: draft.brightness),
                                 Color(hue: draft.hue, saturation: 1, brightness: draft.brightness)],
                        spokenValue: "\(Int((draft.saturation * 100).rounded()))%")
            colorSlider("밝기", value: $draft.brightness,
                        colors: [.black, Color(hue: draft.hue, saturation: draft.saturation, brightness: 1)],
                        spokenValue: "\(Int((draft.brightness * 100).rounded()))%")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("취소") { showsCustomColor = false }
                Button("적용") {
                    if settings.setMascotTint(draft.hex) { showsCustomColor = false }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hueSelection: Binding<Double> {
        Binding(get: { draft.hue }, set: { hue in
            guard hue != draft.hue else { return }
            draft.hue = hue
            // Make a newly chosen hue visible even when the starting tint is gray or black.
            if draft.saturation < 0.01 { draft.saturation = 0.65 }
            if draft.brightness < 0.01 { draft.brightness = 0.85 }
        })
    }

    private func colorSlider(_ title: String, value: Binding<Double>,
                             colors: [Color], spokenValue: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5))
                .frame(width: 24, alignment: .leading)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(spacing: 1) {
                Slider(value: value, in: 0...1) { Text(title) }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityValue(spokenValue)
                GeometryReader { geometry in
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            let width = geometry.size.width
                            guard width > 0 else { return }
                            value.wrappedValue = min(1, max(0, tap.location.x / width))
                        })
                }
                .frame(height: 7)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct MascotColorDraft {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hex: String) {
        let rgb = MascotRGB(hex: hex)
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    var hex: String {
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

/// One menu item: icon, title, shortcut hint, highlighted under the pointer.
private struct MenuRowButton: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

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
            .background(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Brand.accent.opacity(focused && isEnabled ? 0.8 : 0), lineWidth: 2)
            .allowsHitTesting(false))
        .onHover { hovering = $0 }
        .animation(PanelMotion.feedback(reduced: reduced), value: hovering)
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
