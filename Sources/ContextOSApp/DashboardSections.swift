import SwiftUI
import AppKit
import ContextOSCore

// MARK: - Live header

/// "ContextOS", a pill saying whether an agent is working, and one line of who
/// is working where — or when they last did.
struct LiveHeader: View {
    @ObservedObject var live: LiveStatus
    /// Agents whose own config registers ContextOS.
    var configured: Int

    var body: some View {
        // A clock only for the "4분째" / "3시간 전" wording. Half a minute is as
        // fine as those words get, and the panel is released soon after it
        // closes, so this never ticks for long unseen.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("ContextOS")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                    Spacer(minLength: 8)
                    pill
                }
                Text(detail(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live.working ? Brand.positiveDot : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
                .background(Circle().fill((live.working ? Brand.positiveDot : .clear).opacity(0.25))
                    .frame(width: 12, height: 12))
            Text(live.working ? "\(live.agent ?? "AI") 작업 중" : "쉬는 중")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(live.working ? Brand.positive : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background((live.working ? Brand.positiveDot.opacity(0.13) : Color.primary.opacity(0.07)),
                    in: Capsule())
        .animation(.snappy(duration: 0.25), value: live.working)
    }

    private func detail(now: Date) -> String {
        var parts: [String] = []
        if live.working {
            let elapsed = live.since.map { Self.elapsed(since: $0, now: now) } ?? "방금 시작"
            parts.append(live.project.map { "\($0)에서 \(elapsed)" } ?? elapsed)
            if configured > 0 { parts.append("MCP 연결 \(configured)개") }
        } else if let since = live.since {
            parts.append("마지막 작업 " + Self.ago(since, now: now))
            if let project = live.project { parts.append(project) }
        } else {
            parts.append(configured > 0 ? "MCP 연결 \(configured)개" : "아직 연결된 AI 도구가 없어요")
        }
        return parts.joined(separator: " · ")
    }

    /// "방금 시작", "4분째", "2시간째".
    static func elapsed(since: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        if seconds < 60 { return "방금 시작" }
        if seconds < 3600 { return "\(seconds / 60)분째" }
        return "\(seconds / 3600)시간째"
    }

    /// "방금", "3분 전", "2시간 전", "4일 전".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }
}

// MARK: - Hero

/// The one number that matters at a glance, with its trend and today's share.
struct HeroSection: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        let trend = Self.lastDays(14, from: model.savingsByDay)
        let week = trend.suffix(7).reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("누적 아낀 토큰")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    // Proportional figures: tabular digits space a lone big
                    // number out as if it were a column.
                    Text(TokenEstimator.korean(model.totalSaved))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .tracking(-1.1)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.totalSaved)
                }
                Spacer(minLength: 8)
                TrendBars(values: trend)
                    .frame(width: 104)
                    .padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                Text("오늘 +\(TokenEstimator.korean(model.todaySaved))")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Brand.accent.opacity(0.14), in: Capsule())
                Text("이번 주 +\(TokenEstimator.korean(week))")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                    (Text("\(model.queryCount)").foregroundStyle(.primary).fontWeight(.semibold) + Text("회"))
                        .font(.system(size: 11.5).monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .help("ContextOS가 컨텍스트를 골라 준 횟수")
            }
        }
    }

    /// The last `count` local days, oldest first, zero where nothing was saved.
    static func lastDays(_ count: Int, from byDay: [String: Int], now: Double = Date().timeIntervalSince1970) -> [Int] {
        (0..<count).reversed().map { back in
            byDay[TimeKeys.localDay(now - Double(back) * 86_400)] ?? 0
        }
    }
}

/// The last two weeks of savings as a row of small columns, today in the
/// accent and the days before it quieter.
///
/// Columns rather than a line: savings arrive in bursts — a heavy day, then
/// nothing for three — and a line drawn through that zigzags like a heart
/// monitor, suggesting a flow between days that never happened. A column per
/// day says what it is, a day's amount, and an empty day stays a quiet stub on
/// the baseline instead of a cliff.
struct TrendBars: View {
    /// Oldest first; the last value is today.
    var values: [Int]
    var now = Date()

    private static let chartHeight: CGFloat = 34
    private static let gap: CGFloat = 2

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(values.indices, id: \.self) { index in
                    column(values[index], index: index, top: top)
                }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            Text("최근 14일")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 14일 동안 아낀 토큰")
        .accessibilityValue("오늘 \(TokenEstimator.korean(values.last ?? 0)), "
                            + "14일 중 가장 많은 날 \(TokenEstimator.korean(values.max() ?? 0))")
    }

    private func column(_ value: Int, index: Int, top: Int) -> some View {
        let isToday = index == values.count - 1
        // Rounded at the top, square on the baseline; a day with anything at
        // all is at least tall enough to tell apart from an empty one.
        let height = value > 0
            ? max(5, Self.chartHeight * CGFloat(value) / CGFloat(top))
            : 2
        return UnevenRoundedRectangle(topLeadingRadius: value > 0 ? 2 : 1,
                                      topTrailingRadius: value > 0 ? 2 : 1,
                                      style: .continuous)
            .fill(isToday ? Brand.accent
                  : value > 0 ? Color.primary.opacity(0.28) : Color.primary.opacity(0.12))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .help(label(value, daysAgo: values.count - 1 - index))
    }

    private func label(_ value: Int, daysAgo: Int) -> String {
        let day = TimeKeys.localDay(now.timeIntervalSince1970 - Double(daysAgo) * 86_400)
        let title = daysAgo == 0 ? "오늘" : CalendarCard.dayTitle(day)
        return value > 0 ? "\(title) · \(TokenEstimator.korean(value)) 아낌" : "\(title) · 아낀 토큰 없음"
    }
}

// MARK: - Calendar

/// This month in AI tokens: a real calendar grid, the Claude/Codex split, and a
/// line for the picked day — or for the week when nothing is picked.
struct CalendarCard: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    var body: some View {
        let month = Self.month(offset: ui.monthOffset)
        let weeks = CalendarGrid.weeks(of: month)
        let keys = Set(weeks.flatMap { $0 }.compactMap { $0?.key })
        let levels = MonthCalendarView.levels(weeks: weeks, tokensByDay: model.tokensByDay)
        let today = TimeKeys.localDay(Date().timeIntervalSince1970)

        VStack(alignment: .leading, spacing: 7) {
            header(month, total: CalendarGrid.total(month, model.tokensByDay))
            split(keys: keys)
            HStack(spacing: 4) {
                ForEach(Self.weekdays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 4) {
                ForEach(weeks.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { column in
                            cell(weeks[row][column], levels: levels, today: today)
                        }
                    }
                }
            }
            detailRow
                .padding(.top, 3)
        }
        .dashboardCard(radius: 18, padding: 13)
    }

    // MARK: Header and split

    private func header(_ month: Date, total: Int) -> some View {
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        return HStack(spacing: 6) {
            Text("\(parts.month ?? 0)월")
                .font(.system(size: 15, weight: .semibold))
            Text(String(parts.year ?? 0))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Text(TokenEstimator.korean(total) + " 토큰")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Claude Code·Codex가 이 Mac에 남긴 기록 기준 — 칸이 진할수록 많이 쓴 날이에요")
            monthButton("chevron.left", label: "이전 달") { ui.monthOffset += 1 }
            monthButton("chevron.right", label: "다음 달") { ui.monthOffset -= 1 }
                .opacity(ui.monthOffset == 0 ? 0.3 : 1)
                .allowsHitTesting(ui.monthOffset > 0)
        }
    }

    private func monthButton(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                action()
                ui.selectedDay = nil
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    /// Claude vs Codex over the month shown, when there is anything to split.
    @ViewBuilder
    private func split(keys: Set<String>) -> some View {
        let claude = Self.sum(model.agentDayTokens["Claude Code"], keys)
        let codex = Self.sum(model.agentDayTokens["Codex"], keys)
        let total = claude + codex
        if total > 0 {
            let claudeShare = Int((Double(claude) / Double(total) * 100).rounded())
            HStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: codex > 0 && claude > 0 ? 2 : 0) {
                        if claude > 0 {
                            Capsule().fill(Brand.claude)
                                .frame(width: max(3, geo.size.width * CGFloat(claude) / CGFloat(total)))
                        }
                        if codex > 0 {
                            Capsule().fill(Brand.codex)
                        }
                    }
                }
                .frame(height: 4)
                Text(codex == 0 ? "Claude 100%" : claude == 0 ? "Codex 100%"
                     : "Claude \(claudeShare)% · Codex \(100 - claudeShare)%")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        } else {
            Text("Claude Code·Codex 로컬 기록 기준")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func cell(_ day: CalendarGrid.Day?, levels: [Int], today: String) -> some View {
        if let day {
            let tokens = model.tokensByDay[day.key] ?? 0
            DayCell(day: day,
                    tokens: tokens,
                    level: Self.level(tokens, levels),
                    isFuture: day.key > today,
                    isSelected: ui.selectedDay == day.key) {
                withAnimation(.snappy(duration: 0.2)) {
                    ui.selectedDay = ui.selectedDay == day.key ? nil : day.key
                }
                if ui.selectedDay == day.key { model.loadDetail(for: day.key) }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: DayCell.height, maxHeight: DayCell.height)
        }
    }

    /// 0 for nothing, then 1…4 by the month's quartiles.
    static func level(_ tokens: Int, _ levels: [Int]) -> Int {
        guard tokens > 0, !levels.isEmpty else { return 0 }
        return 1 + levels.filter { tokens > $0 }.count
    }

    // MARK: Picked day, or the week

    @ViewBuilder
    private var detailRow: some View {
        if let day = ui.selectedDay {
            let tokens = model.tokensByDay[day] ?? 0
            let detail = model.dayDetails[day]
            let usage = tokens > 0 ? TokenEstimator.korean(tokens) + " 토큰" : "AI 기록 없음"
            detailContent(
                title: Self.dayTitle(day),
                facts: detail.map { $0.commits > 0 ? "커밋 \($0.commits)" : "커밋 없음" } ?? "…",
                lead: usage,
                added: detail?.added ?? 0, deleted: detail?.deleted ?? 0,
                action: "이날 로그") { BuildLogWindow.show(day: day) }
        } else {
            let week = model.week
            let ai = week.commits > 0 ? " · AI \(week.aiCommits * 100 / week.commits)%" : ""
            detailContent(
                title: "이번 주",
                facts: "커밋 \(week.commits)" + ai,
                lead: nil,
                added: week.added, deleted: week.deleted,
                action: "빌드 로그") { BuildLogWindow.show() }
        }
    }

    /// Title and its facts on top; tokens and colored line counts below.
    private func detailContent(title: String, facts: String, lead: String?, added: Int, deleted: Int,
                               action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(title).fontWeight(.semibold) + Text("  " + facts).foregroundStyle(.secondary))
                    .font(.system(size: 12).monospacedDigit())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let lead { Text(lead).foregroundStyle(.secondary) }
                    if added > 0 || deleted > 0 {
                        Text("+\(added.formatted())").foregroundStyle(Brand.positive)
                        Text("−\(deleted.formatted())").foregroundStyle(Brand.negative)
                    } else if lead == nil {
                        Text("아직 바뀐 줄이 없어요").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: perform) {
                HStack(spacing: 3) {
                    Text(action)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Helpers

    static func month(offset: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -offset, to: Date()) ?? Date()
    }

    static func sum(_ byDay: [String: Int]?, _ keys: Set<String>) -> Int {
        guard let byDay else { return 0 }
        return keys.reduce(0) { $0 + (byDay[$1] ?? 0) }
    }

    /// "9월 22일 (화)"
    static func dayTitle(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        let weekday = CalendarGrid.weekdayIndex(of: day).map { weekdays[$0] } ?? ""
        return "\(parts[1])월 \(parts[2])일 (\(weekday))"
    }
}

/// One day of the month: its token level as a filled squircle.
struct DayCell: View {
    let day: CalendarGrid.Day
    let tokens: Int
    let level: Int
    let isFuture: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 23

    var body: some View {
        Button(action: onTap) {
            Text("\(day.number)")
                .font(.system(size: 11, weight: day.isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFuture ? Color.clear : Self.fill(level)))
                // Today and the picked day are marked by a ring just outside
                // the cell, so the fill underneath keeps showing its level.
                .overlay {
                    if isSelected || day.isToday {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? Brand.accent : Color.primary.opacity(0.45),
                                          lineWidth: isSelected ? 1.6 : 1.1)
                            .padding(-2.5)
                    }
                }
                .scaleEffect(hovering && !isFuture ? 1.07 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(isFuture ? "" : "\(CalendarCard.dayTitle(day.key)) · "
              + (tokens > 0 ? TokenEstimator.korean(tokens) + " 토큰" : "기록 없음"))
        .accessibilityLabel(CalendarCard.dayTitle(day.key))
        .accessibilityValue(tokens > 0 ? TokenEstimator.korean(tokens) + " 토큰" : "기록 없음")
    }

    private var foreground: Color {
        if isFuture { return Color.primary.opacity(0.22) }
        return level >= 3 ? Brand.onAccent : Color.primary.opacity(0.78)
    }

    static func fill(_ level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.05)
        case 1: return Brand.accent.opacity(0.18)
        case 2: return Brand.accent.opacity(0.36)
        case 3: return Brand.accent.opacity(0.62)
        default: return Brand.accent.opacity(0.95)
        }
    }
}

// MARK: - Projects

struct ProjectsList: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.projectUsage.isEmpty {
                emptyState("Claude Code 또는 Codex의 로컬 사용 기록이 없어요.")
            } else {
                let everything = max(1, model.projectUsage.reduce(0) { $0 + $1.total })
                ForEach(model.projectUsage) { project in
                    ProjectCard(project: project,
                                share: Int((Double(project.total) / Double(everything) * 100).rounded()),
                                isOpen: ui.expanded.contains(project.id)) {
                        withAnimation(.snappy(duration: 0.22)) {
                            if ui.expanded.contains(project.id) {
                                ui.expanded.remove(project.id)
                            } else {
                                ui.expanded.insert(project.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ProjectCard: View {
    let project: ProjectAIUsage
    let share: Int
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Text(String(project.name.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.accent)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text((project.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(TokenEstimator.korean(project.total))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        Text("전체의 \(share)%")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "접기" : "AI별 사용량 펼치기")

            SplitBar(parts: project.byAgent.map { ($0.tokens, Brand.color(forAgent: $0.agent)) })
                .frame(height: 4)

            if isOpen {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .dashboardCard(radius: 14, padding: 11)
    }

    private var details: some View {
        let top = max(1, project.byAgent.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(project.byAgent) { agent in
                HStack(spacing: 8) {
                    Circle().fill(Brand.color(forAgent: agent.agent)).frame(width: 7, height: 7)
                    Text(agent.agent == "Claude Code" ? "Claude" : agent.agent)
                        .font(.system(size: 12))
                        .frame(width: 58, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(Brand.color(forAgent: agent.agent))
                                .frame(width: max(3, geo.size.width * CGFloat(agent.tokens) / CGFloat(top)))
                        }
                    }
                    .frame(height: 4)
                    Text(TokenEstimator.korean(agent.tokens))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            // Quick actions — only for projects that still exist on disk.
            if FileManager.default.fileExists(atPath: project.path) {
                HStack(spacing: 6) {
                    chip("Finder", "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                    }
                    chip("터미널", "terminal") { Self.openTerminal(at: project.path) }
                    if FileManager.default.fileExists(atPath: project.path + "/.git") {
                        chip("코드 부채", "checklist") { BuildLogWindow.show(debtProject: project.path) }
                    }
                }
                .padding(.top, 3)
            }
        }
        .padding(.top, 1)
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Open Terminal.app at the given directory.
    private static func openTerminal(at path: String) {
        let url = URL(fileURLWithPath: path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// One horizontal bar split into proportional colored segments.
struct SplitBar: View {
    var parts: [(value: Int, color: Color)]

    var body: some View {
        GeometryReader { geo in
            let shown = parts.filter { $0.value > 0 }
            let total = CGFloat(max(1, shown.reduce(0) { $0 + $1.value }))
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown.indices, id: \.self) { index in
                    Capsule().fill(shown[index].color)
                        .frame(width: max(3, (geo.size.width - gaps) * CGFloat(shown[index].value) / total))
                }
            }
        }
    }
}

// MARK: - Activity

struct ActivityList: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.recent.isEmpty {
                emptyState("아직 최적화 기록이 없어요. AI에게 질문하면 여기에 쌓여요.")
            } else {
                ForEach(Self.groups(model.recent), id: \.day) { group in
                    Text(CalendarGrid.heading(group.day))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.leading, 2)
                    ForEach(group.events, id: \.timestamp) { event in
                        row(event, today: group.day == TimeKeys.localDay(Date().timeIntervalSince1970))
                    }
                }
            }
        }
    }

    private func row(_ e: UsageEvent, today: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(Brand.accent)
                .frame(width: 26, height: 26)
                .background(Brand.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(e.query.isEmpty ? "컨텍스트 최적화" : e.query)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\((e.project as NSString).lastPathComponent) · 파일 \(e.fileCount)개 · "
                     + (today ? LiveHeader.ago(Date(timeIntervalSince1970: e.timestamp))
                              : Self.clock.string(from: Date(timeIntervalSince1970: e.timestamp))))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("−" + TokenEstimator.korean(e.savedTokens))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Brand.positive)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()

    /// Events grouped by local day, newest day first, keeping their order.
    static func groups(_ events: [UsageEvent]) -> [(day: String, events: [UsageEvent])] {
        var out: [(day: String, events: [UsageEvent])] = []
        for event in events {
            let day = TimeKeys.localDay(event.timestamp)
            if let last = out.indices.last, out[last].day == day {
                out[last].events.append(event)
            } else {
                out.append((day, [event]))
            }
        }
        return out
    }
}

// MARK: - AI connections

/// Each row separates three distinct facts: tool presence, explicit MCP
/// configuration, and locally readable usage. These must never be inferred
/// from each other — an installed directory does not prove a connection, and
/// an absent transcript is not zero usage.
struct AgentsList: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(notice).lineLimit(2)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
            if model.agents.isEmpty {
                emptyState("찾은 AI 도구가 없어요.")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("이 Mac의 로컬 기록 ")
                        + Text(TokenEstimator.korean(model.aiTokens) + " 토큰").fontWeight(.semibold)
                    Spacer()
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .help("Claude Code·Codex가 이 Mac에 남긴 기록 기준")
                ForEach(Self.ordered(model.agents)) { agent in row(agent) }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.notice)
    }

    private func row(_ agent: DetectedAgent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(String(agent.name.prefix(1)))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text([agent.usage.summary, agent.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                // The status never truncates; the name and usage give way first.
                status(agent)
                    .fixedSize()
            }
            if let path = agent.connection.configPath {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .dashboardCard(radius: 14, padding: 11)
    }

    /// Connected tools first, then the ones a click away, then the rest.
    static func ordered(_ agents: [DetectedAgent]) -> [DetectedAgent] {
        func rank(_ agent: DetectedAgent) -> Int {
            switch agent.connection {
            case .configured: return 0
            case .notConfigured: return 1
            case .unsupported: return 2
            }
        }
        return agents.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    @ViewBuilder
    private func status(_ agent: DetectedAgent) -> some View {
        switch agent.connection {
        case .configured:
            Label("MCP 설정됨", systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.positive)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Brand.positiveDot.opacity(0.13), in: Capsule())
        case .notConfigured:
            if model.connecting.contains(agent.name) {
                ProgressView().controlSize(.small)
            } else {
                Button { model.connect(agent: agent.name) } label: {
                    Label("연결하기", systemImage: "link")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(agent.name) 설정에 ContextOS MCP 서버를 등록해요")
            }
        case .unsupported:
            Text("연동 미지원")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

/// A quiet sentence where a list would be.
func emptyState(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 2)
}
