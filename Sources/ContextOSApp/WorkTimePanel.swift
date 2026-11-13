import SwiftUI
import AppKit
import ContextOSUsage

/// Display formatting only; widgets and collectors keep their original precision.
enum DashboardDuration {
    static func text(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds else { return "—" }
        let seconds = nanoseconds / 1_000_000_000
        if nanoseconds == 0 { return "0분" }
        if seconds < 60 { return "1분 미만" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours)시간" : "\(hours)시간 \(remainder)분"
    }
}

struct DevelopmentTimeCard: View {
    let snapshot: EstimatedActivitySnapshot
    let status: String
    var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("오늘 개발 시간").font(.system(size: 12, weight: .medium))
                Spacer()
                if snapshot.partial {
                    Text("일부 기록").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .help("기록이 꺼져 있거나 앱이 실행되지 않은 시간은 포함하지 않아요.")
                }
            }
            Text(DashboardDuration.text(snapshot.estimatedNanoseconds))
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                Circle().fill(recording ? Brand.positive : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Brand.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .help("지원 IDE의 활동으로 추정한 오늘의 개발 시간이에요. 5분간 입력이 없거나 잠금·절전 중이면 기록을 쉬어요.")
        .accessibilityElement(children: .combine)
    }
}

struct EditorUsageEntry: Identifiable {
    let name: String
    let nanoseconds: UInt64
    var id: String { name }

    static func ranked(_ values: [String: UInt64]) -> [Self] {
        values.filter { $0.value > 0 }.map { Self(name: $0.key, nanoseconds: $0.value) }
            .sorted { $0.nanoseconds == $1.nanoseconds ? $0.name < $1.name : $0.nanoseconds > $1.nanoseconds }
    }
}

/// IDE foreground time has its own scope; it is not a breakdown of today's active time.
struct EditorUsageCard: View {
    let entries: [EditorUsageEntry]
    var icons: [String: NSImage] = [:]
    var recordingEnabled = true
    private var total: Double { entries.reduce(0) { $0 + Double($1.nanoseconds) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("IDE 사용 시간").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("이번 실행").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .help("ContextOS를 연 뒤 각 IDE가 화면 앞에 있었던 시간이에요. 쉬는 시간도 포함하며 오늘 개발 시간과는 별도로 집계해요. 앱을 다시 열면 새로 시작해요.")
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("아직 사용 기록이 없어요").font(.system(size: 11, weight: .medium))
                    Text(recordingEnabled ? "IDE에서 작업하면 여기에 표시돼요." : "설정에서 자동 기록을 켜 보세요.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let icon = icons[entry.name] {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Brand.accent)
                            }
                        }.frame(width: 28, height: 28).accessibilityHidden(true)
                        VStack(spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.name).font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(DashboardDuration.text(entry.nanoseconds))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .monospacedDigit().fixedSize()
                            }
                            GeometryReader { geometry in
                                Capsule().fill(Brand.accent.opacity(0.08))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Brand.accent.opacity(0.65))
                                            .frame(width: geometry.size.width * CGFloat(Double(entry.nanoseconds) / max(1, total)))
                                    }
                            }.frame(height: 4).accessibilityHidden(true)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }.dashboardCard(radius: 16, padding: 16)
    }
}

struct WorkTimePanel: View {
    @ObservedObject var model: WorkTimeController
    @EnvironmentObject private var ui: DashboardUIState
    var compact = false
    @State private var mounted = false
    @State private var editorIcons: [String: NSImage] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DevelopmentTimeCard(snapshot: model.estimatedActivity, status: model.developmentTimeStatus,
                                    recording: model.foregroundEnabled && model.estimatedActivity.phase == .active)
                EditorUsageCard(entries: EditorUsageEntry.ranked(model.editorNanoseconds), icons: editorIcons,
                                recordingEnabled: model.foregroundEnabled)
                Button { ui.openSettings(at: .time) } label: {
                    Label("시간 기록 설정", systemImage: "slider.horizontal.3")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
                }.buttonStyle(PanelPressStyle())
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.top, 4).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TimeDrawProbe(tick: model.lastPublishTick, onDraw: { model.recordDraw(from: $0) }).frame(width: 1, height: 1).accessibilityHidden(true))
        .onAppear {
            mounted = true
            let workspace = NSWorkspace.shared
            for name in ForegroundEditors.installedNames(isInstalled: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }) {
                if let url = ForegroundEditors.bundleIdentifiers(for: name).compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first {
                    editorIcons[name] = workspace.icon(forFile: url.path)
                }
            }
            model.setUIVisible(NSApp.isActive)
        }
        .onDisappear { mounted = false; model.setUIVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if mounted { model.setUIVisible(true) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.setUIVisible(false) }
    }
}

/// Controls live in settings, away from the user's time report.
struct WorkTimeSettings: View {
    @ObservedObject var model: WorkTimeController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("개발 시간").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            SettingsSwitchRow(title: "개발 시간 자동 기록", isOn: Binding(get: { model.foregroundEnabled }, set: { model.setForegroundEnabled($0) }))
            Text("IDE에서 활동한 시간을 추정해요. 5분간 입력이 없거나 잠금·절전 중이면 쉬어요. 입력 내용과 문서 제목은 읽지 않아요.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let status = model.activityStoreStatus {
                Label("시간 기록을 저장하지 못했어요", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5)).foregroundStyle(Brand.caution).help(status)
            }
            DisclosureGroup("VS Code 확장 연결") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("확장 연결", isOn: Binding(get: { model.bridgeEnabled }, set: { model.setBridgeEnabled($0) }))
                        .disabled(!model.foregroundEnabled)
                    Text(model.bridgeStatus).foregroundStyle(.secondary)
                    Text("확장 없이도 자동 기록돼요. 연결하면 활동을 더 자주 확인해요.").foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.system(size: 11))
            DisclosureGroup("작업 타이머") {
                HStack {
                    Text(WidgetTimeSnapshot.duration(model.snapshot.manualNanoseconds)).monospacedDigit()
                    Spacer()
                    Button(model.manualRunning ? "일시정지" : "시작") {
                        if model.manualRunning { model.pauseManual() } else { model.startManual() }
                    }.buttonStyle(PanelPressStyle())
                }.font(.system(size: 11)).padding(.top, 8)
                    .help("직접 켜는 별도 타이머예요. 오늘 개발 시간에 더하지 않아요.")
            }.font(.system(size: 11))
        }
    }
}

struct WidgetDisplaySettings: View {
    @ObservedObject var model: WorkTimeController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("위젯").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Picker("표시할 정보", selection: $model.smallMetric) {
                ForEach(SmallWidgetMetric.allCases, id: \.self) { metric in Text(label(for: metric)).tag(metric) }
            }.font(.system(size: 11))
            SettingsSwitchRow(title: "위젯에 뭉치 표시", isOn: $model.showWidgetMascot)
        }
    }
    private func label(for metric: SmallWidgetMetric) -> String {
        switch metric {
        case .tokens: "AI 사용량"
        case .activity: "개발 시간"
        case .workTimer: "작업 타이머"
        case .editorForeground: "IDE 사용 시간"
        }
    }
}

private struct TimeDrawProbe: NSViewRepresentable {
    var tick: UInt64
    var onDraw: (UInt64) -> Void
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        guard view.tick != tick else { return }
        view.tick = tick; view.onDraw = onDraw; view.needsDisplay = true
    }
    final class ProbeView: NSView {
        var tick: UInt64 = 0
        var onDraw: ((UInt64) -> Void)?
        override func draw(_ dirtyRect: NSRect) { onDraw?(tick) }
    }
}
