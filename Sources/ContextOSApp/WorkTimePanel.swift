import SwiftUI
import ContextOSUsage

@MainActor
struct WorkTimePanel: View {
    @ObservedObject var model: WorkTimeController
    @State private var mounted = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text("오늘 개발 활동").font(.title2.bold())
            Text(model.estimatedActivity.formatted).font(.system(size: 44, weight: .semibold)).monospacedDigit()
            Text(model.estimatedActivity.label).foregroundStyle(.secondary)
            Text("VS Code 상태 표시줄과 같은 중앙 집계입니다. 시작 버튼 없이 자동으로 쌓이고, 5분 공백 후 자동 일시정지합니다.").font(.callout)
            Toggle("VS Code 자동 활동 연결", isOn: Binding(get: { model.bridgeEnabled }, set: { model.setBridgeEnabled($0) }))
            Text(model.bridgeStatus).font(.caption).foregroundStyle(.secondary)
            Text("확장 연결 후 자동 집계합니다. 연결 전의 빈 값은 0시간을 뜻하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            if let status = model.activityStoreStatus { Text(status).font(.caption) }
            DisclosureGroup("활동 추정 기준") {
                Text("포커스·편집·커서·스크롤 사건 이후 최대 5분을 활동으로 분류하는 제품 규칙입니다. 읽기·생각·방치를 정확히 구분하지 못하며 AI/프로그램 변경도 포함될 수 있습니다. 여러 창의 겹친 시간은 한 번만 셉니다. 절전·연결 공백·재시작을 시간으로 채우지 않습니다.").font(.caption).foregroundStyle(.secondary)
                Text("집계 시각: \(model.estimatedActivity.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(model.estimatedActivity.timeZoneID)").font(.caption)
                Text("관측된 내용 변경 콜백(이번 앱 실행): \(model.bridgeEditCount.map(String.init) ?? "—"). 콜백 수와 활동 추정 시간은 별개입니다.").font(.caption)
            }
            Divider()
            Picker("작은 위젯 항목", selection: $model.smallMetric) {
                ForEach(SmallWidgetMetric.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("위젯은 같은 집계의 마지막 값을 표시합니다. macOS 갱신 제한으로 상태 표시줄과 동시에 갱신되지는 않습니다.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("별도 측정 도구") {
                HStack {
                    Text("직접 켜는 타이머: \(WidgetTimeSnapshot.duration(model.snapshot.manualNanoseconds))").monospacedDigit()
                    Spacer()
                    Button(model.manualRunning ? "일시정지" : "시작") { if model.manualRunning { model.pauseManual() } else { model.startManual() } }
                }
                Toggle("전경 에디터 체류 관측", isOn: Binding(get: { model.foregroundEnabled }, set: { model.setForegroundEnabled($0) }))
                Text("전경 체류: \(WidgetTimeSnapshot.duration(model.snapshot.foregroundNanoseconds)). 자동 활동 추정에 더하지 않습니다.").font(.caption)
                if let value = model.aiExecution {
                    Text("Codex 로그 실행구간: \(value.formatted) · \(value.state.label) · 누락 쌍 \(value.missingPairs)개").font(.caption)
                } else { Text("AI 로그 실행구간: 수집기 미연결").font(.caption) }
                Text("AI 실행은 별도 UTC 시작·완료 로그 구간입니다. Claude·Cursor·Gemini 명시 구간은 미지원이며 개발 활동에 더하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24) }
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
