import SwiftUI
import ContextOSCore

/// The entire app: one small menu-bar panel.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            projectRow
            if !model.proactiveFiles.isEmpty { proactiveCard }
            queryBar
            if let sel = model.selection {
                resultCard(sel)
            } else if model.projectPath.isEmpty {
                hint("폴더를 선택하면 시작해요.")
            } else {
                hint("무엇을 할지 적고 ‘코드 찾기’를 눌러보세요.")
            }
            if let error = model.errorMessage {
                Text(error).font(.caption2).foregroundStyle(Theme.red)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.blue)
            Text("ContextOS").font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text("연결됨").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var projectRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.textSecondary).font(.caption)
            Text(model.projectName.isEmpty ? "폴더 없음" : model.projectName)
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(model.projectPath.isEmpty ? "폴더 선택" : "바꾸기", action: model.chooseProject)
                .controlSize(.small)
        }
    }

    private var proactiveCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.orange).font(.caption2)
                Text("지금 고치는 파일 \(model.proactiveFiles.count)개 — 코드 준비됨")
                    .font(.system(size: 11, weight: .medium))
            }
            Button(action: model.copyProactive) {
                Label(model.proactiveCopied ? "복사됐어요!" : "지금 코드 복사",
                      systemImage: model.proactiveCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(model.proactiveCopied ? Theme.green : Theme.orange)
        }
        .padding(10)
        .background(Theme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("무엇을 할까요? 예: 로그인", text: $model.query)
                    .textFieldStyle(.plain)
                    .padding(7)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit(model.runQuery)
                Button(action: model.runQuery) {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    else { Text("코드 찾기").fontWeight(.semibold) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.blue)
                .disabled(model.query.isEmpty || model.isWorking || model.projectPath.isEmpty)
            }
            HStack(spacing: 5) {
                ForEach(BudgetPreset.allCases) { p in
                    Button { model.budgetPreset = p } label: {
                        Text(p.rawValue)
                            .font(.system(size: 11, weight: model.budgetPreset == p ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(model.budgetPreset == p ? Theme.blue : Theme.card, in: Capsule())
                            .foregroundStyle(model.budgetPreset == p ? .white : Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func resultCard(_ sel: ContextSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = sel.refinement, r.changed {
                Text("이렇게 이해했어요: \(r.explanation)")
                    .font(.caption2).foregroundStyle(Theme.purple)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green).font(.caption)
                Text(summaryLine(sel)).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: model.copyBundle) {
                Label(model.copied ? "복사됐어요! AI에 붙여넣으세요" : "AI에게 복사하기",
                      systemImage: model.copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(model.copied ? Theme.green : Theme.blue).controlSize(.large)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryLine(_ sel: ContextSelection) -> String {
        if let p = model.savedPercent, p > 0 {
            return "관련 파일 \(sel.included.count)개만 골랐어요 — 전체보다 \(p)% 적어요."
        }
        return "관련 파일 \(sel.included.count)개를 골랐어요."
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Theme.textSecondary).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Text(model.projectPath.isEmpty ? "내 컴퓨터에서만 작동" : "자동 업데이트 켜짐")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
    }
}
