import SwiftUI
import ContextOSCore

struct ConnectionPreviewSheet: View {
    let preview: ConnectionPreview
    @EnvironmentObject var model: DashboardModel
    private var title: String {
        switch preview.action {
        case "disconnect": return "연결 해제"
        case "restore": return "설정 백업 복구"
        default: return "연결 설정"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preview.agent.rawValue + " · " + title).font(.headline)
            Text("아래 설정의 ContextOS 항목을 변경합니다. 다른 도구의 설정은 보존합니다.")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(preview.files, id: \.self) { file in
                        Text(file).font(.system(.caption, design: .monospaced))
                    }
                    ForEach(preview.warnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            Text("변경 전 백업은 이 Mac에만 저장됩니다. 설정에 개인정보가 있을 수 있으니 백업을 공유하지 마세요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("취소") { model.cancelConnectionPreview() }
                    .keyboardShortcut(.cancelAction).disabled(model.connectionBusy)
                Spacer()
                if model.connectionBusy { ProgressView().controlSize(.small) }
                Button(preview.hasChanges ? "적용" : "확인") { model.applyConnectionPreview() }
                    .keyboardShortcut(.defaultAction).disabled(model.connectionBusy)
            }
        }.padding(22).frame(width: 380)
        .interactiveDismissDisabled(model.connectionBusy)
    }
}
