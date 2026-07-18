import SwiftUI
import AppKit
import ContextOSCore

/// Drives the Build Log window.
@MainActor
final class BuildLogModel: ObservableObject {

    @Published var period: BuildPeriod = .week { didSet { reload() } }
    @Published var log = BuildLog()
    @Published var tokensByDay: [String: Int] = [:]
    @Published var month = Date()
    @Published var selectedDay: String?
    @Published var loading = false

    /// Days to render — the whole period, or just the day picked on the calendar.
    var visibleDays: [BuildDay] {
        guard let selectedDay else { return log.days }
        return log.days.filter { $0.day == selectedDay }
    }

    /// Pick a day on the calendar, or unpick it by tapping it again.
    ///
    /// The calendar always shows a whole month while the timeline shows the
    /// selected period, so a tapped day is often outside the loaded range.
    /// Rather than filtering the timeline down to nothing, widen the period to
    /// the narrowest one that reaches back far enough.
    func select(day: String) {
        guard selectedDay != day else {
            selectedDay = nil
            return
        }
        selectedDay = day
        guard BuildLogReader.dayStart(day) < period.since() else { return }  // already covered
        if let wider = BuildPeriod.covering(day: day) {
            period = wider                              // didSet reloads
        }
        // Older than every period offered: the day stays selected and the
        // timeline says so, rather than silently showing nothing.
    }

    func reload(force: Bool = false) {
        loading = true
        let since = period.since()
        Task {
            let result = await Self.load(since: since, force: force)
            self.log = result.log
            self.tokensByDay = result.tokensByDay
            self.loading = false
        }
    }

    func step(months: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
        selectedDay = nil
    }

    private nonisolated static func load(since: Double, force: Bool) async
        -> (log: BuildLog, tokensByDay: [String: Int]) {
        if force {
            AgentSessionReader.invalidate()
            BuildLogReader.invalidate()
        }
        let usage = AgentSessionReader.snapshot(force: force)
        return (BuildLogReader.log(since: since, snapshot: usage), usage.byDay)
    }
}

/// Which half of the project window is showing.
enum ProjectTab: String, CaseIterable, Identifiable {
    case buildLog = "빌드 로그"
    case debt = "코드 부채"
    var id: String { rawValue }
}

/// The project window: what was built (history), and what it owes (debt).
struct BuildLogView: View {
    @StateObject private var model = BuildLogModel()
    @StateObject private var debtModel = CodeDebtModel()
    @State private var tab: ProjectTab = .buildLog

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch tab {
            case .buildLog:
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 268)
                        .padding(14)
                    Divider()
                    timeline
                }
            case .debt:
                CodeDebtView(model: debtModel)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .tint(Brand.accent)
        .onAppear { model.reload() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(ProjectTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            if model.loading || debtModel.loading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer()
            switch tab {
            case .buildLog:
                Picker("", selection: $model.period) {
                    ForEach(BuildPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            case .debt:
                // Debt is per-project; the build log spans every repo.
                Picker("", selection: $debtModel.selected) {
                    ForEach(debtModel.projects, id: \.path) { Text($0.name).tag(Optional($0.path)) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("새로고침")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func refresh() {
        switch tab {
        case .buildLog: model.reload(force: true)
        case .debt: debtModel.reload(force: true)
        }
    }

    // MARK: - Sidebar: headline stats + calendar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            stats
            Divider()
            calendar
            Spacer()
            legend
        }
    }

    private var stats: some View {
        let s = model.log.summary
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                statTile("추가된 줄", "+\(s.added.formatted())", .green)
                statTile("삭제된 줄", "−\(s.deleted.formatted())", .red)
            }
            HStack(spacing: 8) {
                statTile("커밋", "\(s.commits)", .primary)
                statTile("AI 참여", s.commits > 0 ? "\(s.aiCommits * 100 / s.commits)%" : "—", .primary)
            }
            HStack(spacing: 8) {
                statTile("토큰", TokenEstimator.korean(s.tokens), .primary)
                statTile("작업한 날", "\(s.activeDays)일", .primary)
            }
        }
    }

    private func statTile(_ label: String, _ value: String, _ tone: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.step(months: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(CalendarGrid.title(model.month)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.step(months: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(isCurrentMonth)
            }
            MonthCalendarView(
                month: model.month, tokensByDay: model.tokensByDay,
                cellHeight: 24, spacing: 4, selected: model.selectedDay,
                onSelect: { model.select(day: $0) })
            Text(TokenEstimator.korean(CalendarGrid.total(model.month, model.tokensByDay)) + " 토큰")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var isCurrentMonth: Bool {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.isDate(model.month, equalTo: Date(), toGranularity: .month)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("적음").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach([0.12, 0.3, 0.5, 0.75, 1.0], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 2)
                    .fill(opacity == 0.12 ? Color.secondary.opacity(0.12) : Brand.accent.opacity(opacity))
                    .frame(width: 11, height: 11)
            }
            Text("많음").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let day = model.selectedDay {
                    filterBanner(day)
                }
                // A filtered day can be empty while the period as a whole is not,
                // so the empty state keys off what is actually being shown.
                if model.visibleDays.isEmpty && !model.loading {
                    empty
                } else {
                    ForEach(model.visibleDays) { day in
                        dayBlock(day)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filterBanner(_ day: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.tint)
            Text("\(CalendarGrid.heading(day)) 만 보는 중")
                .font(.system(size: 11))
            Spacer()
            Button("전체 보기") { model.selectedDay = nil }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedDay != nil ? "이 날은 기록된 작업이 없어요."
                                          : "이 기간에 기록된 작업이 없어요.")
                .font(.system(size: 13, weight: .medium))
            Text("빌드 로그는 AI로 작업한 적이 있는 Git 저장소의 커밋을 읽어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 30)
    }

    private func dayBlock(_ day: BuildDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CalendarGrid.heading(day.day))
                    .font(.system(size: 13, weight: .semibold))
                Text(CalendarGrid.weekdayLabel(day.day))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if day.tokens > 0 {
                    Text(TokenEstimator.korean(day.tokens) + " 토큰")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if day.added > 0 || day.deleted > 0 {
                    Text("+\(day.added.formatted())").foregroundStyle(.green)
                    Text("−\(day.deleted.formatted())").foregroundStyle(.red)
                }
                if !day.commits.isEmpty {
                    Text("커밋 \(day.commits.count)").foregroundStyle(.secondary)
                }
                if day.uncommittedAdded > 0 || day.uncommittedDeleted > 0 {
                    Label("미커밋 +\(day.uncommittedAdded) −\(day.uncommittedDeleted)",
                          systemImage: "pencil.line")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())

            if day.commits.isEmpty, day.tokens > 0 {
                Text("커밋 없이 작업한 날 — 탐색하거나 디버깅했을 거예요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            ForEach(day.commits) { commit in
                commitRow(commit)
            }
        }
    }

    private func commitRow(_ commit: BuildCommit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(commit.isAIAssisted ? Brand.accent : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                // The commit subject verbatim: it is already a human-written
                // summary, and paraphrasing it locally could only make it wrong.
                Text(commit.subject)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    badge(commit.projectName, systemImage: "folder")
                    Text("+\(commit.added)").foregroundStyle(.green)
                    Text("−\(commit.deleted)").foregroundStyle(.red)
                    Text("파일 \(commit.files)").foregroundStyle(.secondary)
                    ForEach(commit.agents, id: \.self) { agent in
                        badge(agent, systemImage: "sparkles")
                    }
                    Text(commit.hash)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text(Self.time(commit.timestamp))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ epoch: Double) -> String {
        clock.string(from: Date(timeIntervalSince1970: epoch))
    }

}

/// Owns the single Build Log window.
///
/// The app is a menu-bar accessory with no Dock icon, so the window has to be
/// created and focused by hand — and re-focused rather than duplicated when the
/// user asks for it again.
@MainActor
enum BuildLogWindow {
    private static var controller: NSWindowController?

    static func show() {
        if let controller, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "프로젝트"
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: BuildLogView())
        window.center()
        window.isReleasedWhenClosed = false      // we hold it; AppKit must not free it

        let holder = NSWindowController(window: window)
        controller = holder
        holder.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
