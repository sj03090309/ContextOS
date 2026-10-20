import SwiftUI
import ContextOSUsage

struct DevelopmentTimeSummary: View {
    @ObservedObject var model: WorkTimeController
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("오늘 개발 활동").font(.system(size: 11, weight: .medium))
                    Text(model.estimatedActivity.label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(model.estimatedActivity.formatted)
                    .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }.dashboardCard(radius: 16, padding: 13).contentShape(Rectangle())
        }.buttonStyle(PanelPressStyle())
            .accessibilityHint("개발 활동 추정과 연결 상태 확인")
    }
}

struct DevelopmentTimeCard: View {
    let snapshot: EstimatedActivitySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("오늘 개발 활동", systemImage: "clock").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("활동 추정").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Text(snapshot.formatted).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack(spacing: 6) {
                Circle().fill(snapshot.phase == .active ? Brand.positive : Color.secondary).frame(width: 5, height: 5)
                Text(snapshot.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if snapshot.estimatedNanoseconds == nil {
                Text("연결 전의 빈 값은 0시간을 뜻하지 않아요.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Brand.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(Brand.accent.opacity(0.12), lineWidth: 1))
    }
}

@MainActor
struct WorkTimePanel: View {
    @ObservedObject var model: WorkTimeController
    var compact = false
    @State private var mounted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DevelopmentTimeCard(snapshot: model.estimatedActivity)
                VStack(alignment: .leading, spacing: 12) {
                    PanelSectionHeading(title: "자동 활동 연결", detail: "VS Code")
                    Toggle("VS Code 자동 활동 연결", isOn: Binding(get: { model.bridgeEnabled }, set: { model.setBridgeEnabled($0) }))
                        .font(.system(size: 12))
                    Text(model.bridgeStatus).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text("연결 후 포커스·편집 등 관측 신호로 추정해요. 5분간 신호가 없으면 자동으로 멈춰요.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let status = model.activityStoreStatus { Text(status).font(.caption) }
                    DisclosureGroup("활동 추정 기준") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("포커스·편집·커서·스크롤 사건 이후 최대 5분을 활동으로 분류하는 제품 규칙입니다. 읽기·생각·방치를 정확히 구분하지 못하며 AI/프로그램 변경도 포함될 수 있어요. 여러 창의 겹친 시간은 한 번만 셉니다. 절전·연결 공백·재시작을 시간으로 채우지 않습니다.")
                            Text("집계 시각: \(model.estimatedActivity.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(model.estimatedActivity.timeZoneID)")
                            Text("관측된 내용 변경 콜백(이번 앱 실행): \(model.bridgeEditCount.map(String.init) ?? "—"). 콜백 수와 활동 추정 시간은 별개입니다.")
                        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.system(size: 11))
                }.dashboardCard(radius: 17, padding: 14)
                VStack(alignment: .leading, spacing: 13) {
                    DisclosureGroup("위젯 표시 항목") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("작은 위젯 항목", selection: $model.smallMetric) {
                                ForEach(SmallWidgetMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            Toggle("위젯에 작은 뭉치 표시", isOn: $model.showWidgetMascot)
                            Text("위젯은 같은 집계의 마지막 값을 표시해요. macOS 갱신 제한으로 상태 표시줄과 동시에 갱신되지는 않습니다.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                    Divider()
                    DisclosureGroup("별도 측정 도구") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("직접 켜는 타이머").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(WidgetTimeSnapshot.duration(model.snapshot.manualNanoseconds)).monospacedDigit()
                                }
                                Spacer()
                                Button(model.manualRunning ? "일시정지" : "시작") { if model.manualRunning { model.pauseManual() } else { model.startManual() } }
                                    .buttonStyle(PanelPressStyle())
                            }
                            Toggle("전경 에디터 체류 관측", isOn: Binding(get: { model.foregroundEnabled }, set: { model.setForegroundEnabled($0) }))
                            Text("전경 체류: \(WidgetTimeSnapshot.duration(model.snapshot.foregroundNanoseconds)). 자동 활동 추정에 더하지 않습니다.")
                            if let value = model.aiExecution {
                                Text("Codex 로그 실행구간: \(value.formatted) · \(value.state.label) · 누락 쌍 \(value.missingPairs)개")
                            } else { Text("AI 로그 실행구간: 수집기 미연결") }
                            Text("AI 실행은 별도 UTC 시작·완료 로그 구간입니다. Claude·Cursor·Gemini 명시 구간은 미지원이며 개발 활동에 더하지 않습니다.")
                        }.font(.system(size: 10.5)).padding(.top, 8)
                    }
                }.font(.system(size: 11)).dashboardCard(radius: 17, padding: 14)
            }.padding(compact ? 16 : 24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TimeDrawProbe(tick: model.lastPublishTick, onDraw: { model.recordDraw(from: $0) }).frame(width: 1, height: 1).accessibilityHidden(true))
        .onAppear { mounted = true; model.setUIVisible(NSApp.isActive) }
        .onDisappear { mounted = false; model.setUIVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if mounted { model.setUIVisible(true) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.setUIVisible(false) }
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
