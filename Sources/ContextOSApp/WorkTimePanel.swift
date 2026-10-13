import SwiftUI
import ContextOSUsage

@MainActor
struct WorkTimePanel: View {
    @ObservedObject var model: WorkTimeController
    @State private var mounted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("시간 측정").font(.title2.bold())
            Text("이번 관측의 시간입니다. 전경 체류·타이머를 실제 편집 시간으로 환산하지 않습니다.")
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("작업 타이머")
                    Text(WidgetTimeSnapshot.duration(model.snapshot.manualNanoseconds)).font(.title.monospacedDigit())
                    Text(model.snapshot.manualState.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.manualRunning ? "일시정지" : "시작") {
                    if model.manualRunning { model.pauseManual() } else { model.startManual() }
                }
            }
            Text("시작·종료 사이의 경과 시간이며, 켜 둔 방치도 포함될 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("전경 에디터 체류 자동 관측", isOn: Binding(get: { model.foregroundEnabled }, set: { model.setForegroundEnabled($0) }))
            HStack {
                Text(WidgetTimeSnapshot.duration(model.snapshot.foregroundNanoseconds)).font(.title.monospacedDigit())
                Spacer()
                Text(model.editorLabel ?? model.snapshot.foregroundState.label).foregroundStyle(.secondary)
            }
            Text("Xcode·VS Code·Cursor의 앱 전경만 관측합니다. 다른 앱과 미지원 에디터는 미관측이며, 읽기·방치와 편집을 구분하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("편집 이벤트: 확장 미연결 · 사람/AI 구분 안 됨").font(.caption).foregroundStyle(.secondary)
            Text("AI 실행구간: 시간 집계 미연동").font(.caption).foregroundStyle(.secondary)
            if let reason = model.boundaryReason { Text("측정 중지: \(reason). 자동 재개하지 않습니다.").font(.caption) }
            Divider()
            Picker("작은 위젯 항목", selection: $model.smallMetric) {
                ForEach(SmallWidgetMetric.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("위젯은 마지막 확인값을 표시합니다. 갱신 시점은 macOS가 결정합니다.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("관측 초기화") { model.reset() } }
            Spacer(minLength: 0)
        }.padding(24)
            .background(TimeDrawProbe(tick: model.lastPublishTick, onDraw: { model.recordDraw(from: $0) }).frame(width: 1, height: 1).accessibilityHidden(true))
            .onAppear { mounted = true; model.setUIVisible(NSApp.isActive) }
            .onDisappear { mounted = false; model.setUIVisible(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if mounted { model.setUIVisible(true) }
            }
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
