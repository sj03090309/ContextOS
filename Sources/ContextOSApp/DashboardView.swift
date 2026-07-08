import SwiftUI
import ContextOSCore

/// The menu-bar popover: pick a project, type a task, see the optimized context.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            queryBar
            if !model.lint.isEmpty { lintView }
            if let selection = model.selection {
                resultView(selection)
                if !model.advisories.isEmpty { advisoryView }
            } else {
                Text("작업 내용을 입력하고 ⏎ 를 누르면 최소한의 컨텍스트를 보여줍니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("ContextOS").font(.headline)
                Text(model.projectName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("변경", action: model.chooseProject).controlSize(.small)
        }
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("예: 로그인 수정", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.runQuery)
                Button(action: model.runQuery) {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    else { Text("최적화") }
                }
                .disabled(model.query.isEmpty || model.isWorking)
            }
            HStack(spacing: 6) {
                Text("토큰 예산").font(.caption).foregroundStyle(.secondary)
                Stepper(value: $model.budget, in: 1000...200_000, step: 1000) {
                    Text(TokenEstimator.humanReadable(model.budget)).font(.caption.monospaced())
                }
                .controlSize(.small)
            }
        }
    }

    private var lintView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.lint, id: \.rule) { finding in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(finding.severity == .warning ? .orange : .blue)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.message).font(.caption)
                        Text(finding.suggestion).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var advisoryView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.advisories, id: \.message) { advisory in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: advisory.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(advisory.severity == .warning ? .orange : .blue)
                        .font(.caption)
                    Text(advisory.message).font(.caption)
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func resultView(_ selection: ContextSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                metric("점수", "\(selection.contextScore)", suffix: "/100",
                       tint: scoreColor(selection.contextScore))
                metric("컨텍스트", TokenEstimator.humanReadable(selection.estimatedTokens), suffix: "")
                metric("파일 수", "\(selection.included.count)", suffix: "")
            }

            if let savings = model.savings, savings.saved > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("전체 대비 \(TokenEstimator.humanReadable(savings.saved)) 절약 (\(savings.percent)%)")
                        .font(.caption).foregroundStyle(.green)
                    ProgressView(value: Double(savings.percent), total: 100).tint(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("포함된 파일").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(selection.included, id: \.path) { file in
                    HStack {
                        Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(TokenEstimator.humanReadable(file.estimatedTokens))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            if !selection.excluded.isEmpty {
                Text("제외됨 (예산 초과): \(selection.excluded.prefix(5).map(\.path).joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                if model.todaySaved > 0 {
                    Text("오늘 절약 \(TokenEstimator.humanReadable(model.todaySaved))")
                        .font(.caption2.bold()).foregroundStyle(.green)
                }
                if let s = model.summary {
                    Text("파일 \(s.files)개 · 심볼 \(s.symbols)개 · 전체 ≈ \(TokenEstimator.humanReadable(s.estimatedTotalTokens))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
    }

    private func metric(_ label: String, _ value: String, suffix: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(tint)
                Text(suffix).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }
}
