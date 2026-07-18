import SwiftUI
import AppKit
import ContextOSCore

/// Drives the 코드 부채 tab.
@MainActor
final class CodeDebtModel: ObservableObject {
    /// Repos with local AI history, for the picker.
    @Published var projects: [ProjectAITokenReader.ProjectIdentity] = []
    @Published var selected: String? { didSet { if oldValue != selected { reload() } } }
    @Published var debt = CodeDebt()
    @Published var kind: DebtKind = .untested
    @Published var loading = false
    /// The analyzer ran and found nothing at all, vs. hasn't run yet.
    @Published var analyzed = false

    func loadProjects() {
        Task {
            let found = await Self.discover()
            self.projects = found
            if self.selected == nil { self.selected = found.first?.path }
        }
    }

    func reload(force: Bool = false) {
        guard let path = selected else { return }
        loading = true
        Task {
            let result = await Self.analyze(path: path, force: force)
            self.debt = result
            self.analyzed = true
            self.loading = false
        }
    }

    private nonisolated static func discover() async -> [ProjectAITokenReader.ProjectIdentity] {
        BuildLogReader.repositories(in: AgentSessionReader.snapshot())
            .map { ProjectAITokenReader.canonicalProject($0) }
    }

    private nonisolated static func analyze(path: String, force: Bool) async -> CodeDebt {
        if force { CodeDebtReader.invalidate() }
        return CodeDebtReader.analyze(root: URL(fileURLWithPath: path), force: force)
    }
}

/// Code debt: counted facts, each one somewhere you can open.
///
/// There is no health score here on purpose — see `CodeDebtReader`'s notes. The
/// UI's job is to show what was measured and the rule that produced it, so the
/// user can judge rather than be graded.
struct CodeDebtView: View {
    @ObservedObject var model: CodeDebtModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 268)
                .padding(14)
            Divider()
            items
        }
        .onAppear {
            if model.projects.isEmpty { model.loadProjects() }
        }
    }

    // MARK: - Sidebar: one card per kind

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(DebtKind.allCases, id: \.self) { kind in
                card(kind)
            }
            Spacer()
            Text("\(model.debt.filesScanned)개 파일 검사됨")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func card(_ kind: DebtKind) -> some View {
        let count = model.debt.counts[kind] ?? 0
        let isSelected = model.kind == kind
        return Button { model.kind = kind } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(count > 0 ? Color.orange : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.label).font(.system(size: 12, weight: .medium))
                    // The rule that produced the count, always visible: a number
                    // whose definition is hidden is a number you can't argue with.
                    Text(kind.rule(model.debt.thresholds))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(count)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    delta(kind)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? AnyShapeStyle(Brand.accent.opacity(0.18))
                               : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Brand.accent : .clear, lineWidth: 1))
    }

    /// Trend vs. the oldest snapshot in the window — absent until history exists.
    @ViewBuilder
    private func delta(_ kind: DebtKind) -> some View {
        if let change = model.debt.deltas[kind], change != 0 {
            Text(change > 0 ? "▲\(change)" : "▼\(-change)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(change > 0 ? Color.red : Color.green)
        }
    }

    // MARK: - Items

    private var items: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let list = model.debt.items(model.kind)
                    if list.isEmpty && model.analyzed && !model.loading {
                        empty
                    } else {
                        ForEach(list) { row($0) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.kind.label).font(.system(size: 13, weight: .semibold))
            Text("\(model.debt.items(model.kind).count)개")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if model.debt.deltas.isEmpty && model.analyzed {
                // Better to say the trend doesn't exist yet than to draw a flat
                // line that looks like "nothing is changing".
                Text("추세는 내일부터 — 오늘 첫 기록")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("이 항목은 깨끗해요.", systemImage: "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
            Text(model.kind.rule(model.debt.thresholds) + " — 해당하는 게 없습니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private func row(_ item: DebtItem) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(item.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(item.path)
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.detail).foregroundStyle(.orange)
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .help("열기: \(item.path):\(item.line)")
    }

    /// Open the file at the line, in whatever the user actually edits with.
    ///
    /// Deliberately asks LaunchServices which app owns the file rather than
    /// reaching for Xcode: `/usr/bin/xed` exists on macOS even when Xcode does
    /// not, so "is xed there?" is not the question — "is Xcode what you use?" is.
    /// Editors that can't be told a line still get the file; the row shows the
    /// line number either way.
    private func open(_ item: DebtItem) {
        guard let root = model.selected else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
        let name = editor?.deletingPathExtension().lastPathComponent ?? ""

        switch name {
        case "Xcode":
            run("/usr/bin/xed", ["--line", "\(item.line)", url.path])
        case "Visual Studio Code", "VSCodium", "Cursor", "Windsurf":
            // -g <file>:<line> is the shared VS Code-family "goto" argument.
            run("/usr/bin/open", ["-a", editor?.path ?? name, "--args",
                                  "-g", "\(url.path):\(item.line)"])
        case "Sublime Text":
            run("/usr/bin/open", ["-a", editor?.path ?? name, "--args",
                                  "\(url.path):\(item.line)"])
        default:
            NSWorkspace.shared.open(url)
        }
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
