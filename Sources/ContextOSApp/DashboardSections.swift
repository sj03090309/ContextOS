import SwiftUI
import AppKit
import ContextOSCore
import ContextOSUsage

// MARK: - Live header

/// A glanceable activity banner, with space for the separately hosted mascot.
struct LiveHeader: View {
    @ObservedObject var live: LiveStatus
    @ObservedObject var mascot: MascotState
    let agentLogCollectionEnabled: Bool
    var hidePrivateDetails = false
    var surface: DashboardSurface = .popover
    @State private var expiredCompletion: Date?
    @State private var hidden = false

    var body: some View {
        let completedAt = hidden ? nil : mascot.optimizationCompletedAt
        let showsCompletion = !hidden && completedAt != expiredCompletion
            && mascot.showsOptimizationCompletion(at: Date())
        TimelineView(PanelClockSchedule(paused: hidden)) { context in
            HStack(spacing: 10) {
                Color.clear.frame(width: DashboardLayout.mascotWidth, height: DashboardLayout.mascotHeight)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(phaseTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        Text("ContextOS")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if showsCompletion {
                        Label {
                            Text("컨텍스트 최적화 완료")
                        } icon: {
                            Image(systemName: "checkmark.circle").foregroundStyle(Brand.positive)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    } else {
                        let detail = detail(now: context.date)
                        HStack(spacing: 4) {
                            Text(detail.status).layoutPriority(1)
                            if let project = detail.project {
                                Text("·").accessibilityHidden(true)
                                Text(project).truncationMode(.middle)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 2)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(.horizontal, DashboardLayout.mascotLeading - 2)
        .padding(.top, DashboardLayout.mascotTop - 6)
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { notification in
            if notification.object as? DashboardSurface == surface { hidden = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverClosed)) { notification in
            if notification.object as? DashboardSurface == surface { hidden = true }
        }
        .task(id: completedAt) {
            guard let completedAt else { return }
            let delay = completedAt.addingTimeInterval(MascotState.completionDuration).timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if !Task.isCancelled { expiredCompletion = completedAt }
        }
    }

    private var statusColor: Color {
        guard agentLogCollectionEnabled else { return Color.secondary.opacity(0.55) }
        switch live.phase {
        case .working: return Brand.positiveDot
        case .waiting: return Brand.caution
        case .interrupted: return Brand.negative
        case .completed, .unknown: return Color.secondary.opacity(0.55)
        }
    }

    private var phaseTitle: String {
        guard agentLogCollectionEnabled else { return "로그 집계 꺼짐" }
        let agent = live.agent ?? "AI"
        switch live.phase {
        case .working: return agent + " 작업 중"
        case .waiting: return agent + (live.pendingTools > 0 ? " 도구 대기" : " 응답 대기")
        case .completed: return "응답 종료"
        case .interrupted: return "작업 중단"
        case .unknown: return "AI 상태 미확인"
        }
    }

    private func detail(now: Date) -> (status: String, project: String?) {
        guard agentLogCollectionEnabled else { return ("설정에서 AI 로그 집계를 켤 수 있어요", nil) }
        if live.snapshot.optimizing { return ("파일 최적화 호출 중", nil) }
        if live.snapshot.planning { return ("ContextOS 도구 호출 중", nil) }

        let project = hidePrivateDetails ? nil : live.project
        if live.working {
            let elapsed = live.since.map { Self.elapsed(since: $0, now: now) } ?? "작업 신호 확인"
            let active = live.snapshot.activeSessions
            return (active > 1 ? "\(elapsed) · 진행 세션 \(active)개" : elapsed, project)
        } else if (live.phase == .completed || live.phase == .interrupted), let ended = live.endedAt {
            return (Self.ago(ended, now: now), project)
        } else if let last = live.lastEventAt {
            return ("최근 로그 변경 " + Self.ago(last, now: now), project)
        }
        return ("확인 가능한 작업 로그가 없어요", nil)
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

// MARK: - Savings

struct CompactSavingsSummary: View {
    @EnvironmentObject var model: DashboardModel
    let compact: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("오늘 추정 절감")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(TokenEstimator.korean(model.todaySaved))
                        .font(.system(size: compact ? 28 : 34, weight: .semibold, design: .rounded))
                        .monospacedDigit().tracking(-0.6)
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text("토큰").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("오늘 추정 절감 토큰")
                .accessibilityValue(String(model.todaySaved))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text("누적 \(TokenEstimator.korean(model.totalSaved))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("누적 추정 절감 토큰")
                    .accessibilityValue(String(model.totalSaved))
                Text("최적화 \(model.queryCount.formatted())회")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("누적 최적화 \(model.queryCount.formatted())회")
            }
            .padding(.bottom, 3)
        }
        .help("ContextOS가 선택한 컨텍스트와 전체 파일 크기를 비교한 추정치입니다. AI 제공자의 실제 청구 절감액이 아닙니다.")
    }
}

// MARK: - Overview activity

struct OverviewActivityCard: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var ui: DashboardUIState
    @Environment(\.accessibilityReduceMotion) private var reduced
    let compact: Bool

    var body: some View {
        let recent = model.recent.prefix(3)
        let tools = model.agents.filter { $0.connection.isConfigured || $0.connection.configPath != nil }
        let configured = tools.filter { $0.connection.isConfigured }.count
        let recentSummary = ui.overviewExpanded && !recent.isEmpty ? "최근 \(recent.count)건"
            : recent.first.map(savingsLabel) ?? "아직 최적화 기록이 없어요"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(ui.overviewExpanded ? "활동 상세" : "활동 요약")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    withAnimation(PanelMotion.feedback(reduced: reduced)) { ui.overviewExpanded.toggle() }
                } label: {
                    Label(ui.overviewExpanded ? "접기" : "자세히 보기",
                          systemImage: ui.overviewExpanded ? "chevron.up" : "chevron.down")
                        .labelStyle(OverviewDisclosureLabel())
                        .padding(.horizontal, 9)
                        .frame(minHeight: 26)
                        .background(Brand.accent.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityLabel(ui.overviewExpanded ? "활동 상세 접기" : "활동 요약 자세히 보기")
                .accessibilityValue(ui.overviewExpanded ? "펼쳐짐" : "접힘")
            }
            .padding(.vertical, compact ? 3 : 8)
            Divider().opacity(0.55)
            summaryRow("최근 최적화", symbol: "bolt.horizontal", summary: recentSummary, action: "전체 기록") {
                ui.navigate(to: .history)
            }
            if ui.overviewExpanded, !recent.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, event in
                        let date = Date(timeIntervalSince1970: event.timestamp)
                        detailRow(savingsLabel(event), detail: date.formatted(
                            date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                            time: .shortened))
                    }
                }
                .padding(.bottom, 8)
            }
            Divider().opacity(0.55)
            summaryRow("AI 연결", symbol: "link",
                       summary: configured == 0 ? "설정된 도구 없음" : "\(configured)개 도구 설정됨",
                       action: configured == 0 ? "연결하기" : "연결 설정") {
                ui.showConnections = true
            }
            if ui.overviewExpanded {
                VStack(spacing: 0) {
                    if tools.isEmpty {
                        detailRow("연결 설정에서 사용할 도구를 확인할 수 있어요.")
                    } else {
                        ForEach(tools) { agent in
                            detailRow(agent.name, detail: agent.connection.isConfigured ? "설정됨" : "설정 필요")
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 13)
        .dashboardCard(radius: 15, padding: 0)
    }

    private func savingsLabel(_ event: UsageEvent) -> String {
        TokenEstimator.korean(event.savedTokens) + " 토큰 절감"
    }

    private func summaryRow(_ title: String, symbol: String, summary: String,
                            action: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Brand.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Label(action, systemImage: "chevron.right")
                    .labelStyle(OverviewDisclosureLabel())
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .frame(minHeight: compact ? 36 : 53)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel("\(title), \(action)")
        .accessibilityValue(summary)
    }

    private func detailRow(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(minHeight: 23)
        .padding(.leading, 37)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewDisclosureLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title.font(.system(size: 10.5, weight: .medium))
            configuration.icon.font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Calendar

/// This month in AI tokens: a real calendar grid, the Claude/Codex split, and a
/// line for the picked day — or for the week when nothing is picked.
struct CalendarCard: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState
    @Environment(\.accessibilityReduceMotion) private var reduced

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    var body: some View {
        let month = Self.month(offset: ui.monthOffset)
        let weeks = CalendarGrid.weeks(of: month)
        let keys = Set(weeks.flatMap { $0 }.compactMap { $0?.key })
        let levels = MonthCalendarView.levels(weeks: weeks, tokensByDay: model.tokensByDay)
        let today = TimeKeys.localDay(Date().timeIntervalSince1970)

        VStack(alignment: .leading, spacing: 7) {
            header(month, total: keys.contains { model.tokensByDay[$0] != nil }
                   ? CalendarGrid.total(month, model.tokensByDay) : nil)
            if !model.agentLogCollectionEnabled {
                Text("저장된 기록 · 새 로그 집계 꺼짐")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
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

    private func header(_ month: Date, total: Int?) -> some View {
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        return HStack(spacing: 6) {
            Text("\(parts.month ?? 0)월")
                .font(.system(size: 15, weight: .semibold))
            Text(String(parts.year ?? 0))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Text(total.map { TokenEstimator.korean($0) + " 토큰" } ?? "기록 없음")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help("Claude Code·Codex가 이 Mac에 남긴 기록 기준 — 칸이 진할수록 많이 쓴 날이에요")
            monthButton("chevron.left", label: "이전 달") { ui.monthOffset += 1 }
            monthButton("chevron.right", label: "다음 달") { ui.monthOffset -= 1 }
                .disabled(ui.monthOffset <= 0)
        }
    }

    private func monthButton(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(PanelMotion.response(reduced: reduced)) {
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
        .buttonStyle(PanelPressStyle())
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    /// Claude vs Codex over the month shown, when there is anything to split.
    @ViewBuilder
    private func split(keys: Set<String>) -> some View {
        let claude = Self.sum(model.agentDayTokens["Claude Code"], keys)
        let codex = Self.sum(model.agentDayTokens["Codex"], keys)
        if claude > 0 || codex > 0 {
            let fraction = Self.providerFraction(claude, other: codex)
            let claudeShare = Int((fraction * 100).rounded())
            HStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: codex > 0 && claude > 0 ? 2 : 0) {
                        if claude > 0 {
                            Capsule().fill(Brand.claude)
                                .frame(width: max(3, geo.size.width * fraction))
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
                withAnimation(PanelMotion.response(reduced: reduced)) {
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
            if !ui.hidePrivateDetails {
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
                .buttonStyle(PanelPressStyle())
            }
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
        return keys.reduce(0) { Int(UsageNumbers.add(Int64($0), Int64(byDay[$1] ?? 0))) }
    }

    static func providerFraction(_ tokens: Int, other: Int) -> Double {
        let part = Double(max(0, tokens))
        let total = part + Double(max(0, other))
        return total > 0 ? part / total : 0
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
    @Environment(\.accessibilityReduceMotion) private var reduced
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
                .scaleEffect(hovering && !isFuture && !reduced ? 1.035 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .disabled(isFuture)
        .onHover { hovering = $0 }
        .animation(PanelMotion.feedback(reduced: reduced), value: hovering)
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
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.projectUsage.isEmpty {
                PanelEmptyState(symbol: "folder", title: "아직 프로젝트 기록이 없어요", detail: "Claude Code·Codex의 관측 가능한 로컬 기록이 여기에 모여요.")
            } else {
                let everything = max(1, model.projectUsage.reduce(0.0) { $0 + Double($1.total) })
                ForEach(Array(model.projectUsage.enumerated()), id: \.element.id) { index, project in
                    ProjectCard(project: project,
                                share: Int((Double(project.total) / Double(everything) * 100).rounded()),
                                isOpen: ui.expanded.contains(project.id),
                                privateLabel: ui.hidePrivateDetails ? "프로젝트 \(index + 1)" : nil) {
                        withAnimation(PanelMotion.response(reduced: reduced)) {
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
    var privateLabel: String? = nil
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    if privateLabel == nil {
                        LogoBadge(subject: .project(path: project.path, mainAgent: project.byAgent.first?.agent))
                    } else {
                        Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(privateLabel ?? project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(privateLabel != nil ? "이름·경로 숨김" : (project.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10.5))
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
            .buttonStyle(PanelPressStyle())
            .accessibilityValue(isOpen ? "펼쳐짐" : "접힘")
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
            if privateLabel == nil, FileManager.default.fileExists(atPath: project.path) {
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
        .buttonStyle(PanelPressStyle())
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
            let total = max(1, shown.reduce(CGFloat.zero) { $0 + CGFloat($1.value) })
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
    @EnvironmentObject var ui: DashboardUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.recent.isEmpty {
                PanelEmptyState(symbol: "sparkle", title: "아직 최적화 기록이 없어요", detail: "ContextOS의 최적화 호출이 기록되면 여기에 표시돼요.")
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
                Text(ui.hidePrivateDetails || e.query.isEmpty ? "컨텍스트 최적화" : e.query)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text((ui.hidePrivateDetails ? "프로젝트 숨김" : (e.project as NSString).lastPathComponent) + " · 파일 \(e.fileCount)개 · "
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
    @Environment(\.accessibilityReduceMotion) private var reduced
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ui.hidePrivateDetails {
                Text("연결 설정을 변경하려면 개인 정보 표시를 켜 주세요.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(ui.hidePrivateDetails ? "연결 안내가 있어요. 개인 정보 표시 후 내용을 확인할 수 있어요." : notice).lineLimit(2)
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
                    if model.agentLogCollectionEnabled {
                        Text("이 Mac의 로컬 기록 ")
                            + Text(TokenEstimator.korean(model.aiTokens) + " 토큰").fontWeight(.semibold)
                    } else {
                        Text("AI 로컬 로그 집계 꺼짐")
                    }
                    Spacer()
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .help("Claude Code·Codex가 이 Mac에 남긴 기록 기준")
                ForEach(Self.ordered(model.agents)) { agent in row(agent) }
            }
        }
        .animation(PanelMotion.response(reduced: reduced), value: model.notice)
    }

    private func row(_ agent: DetectedAgent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                LogoBadge(subject: .agent(agent.name), side: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text([agent.usage.summary, ui.hidePrivateDetails ? nil : agent.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                // The status never truncates; the name and usage give way first.
                status(agent)
                    .fixedSize()
            }
            if let path = agent.connection.configPath, !ui.hidePrivateDetails {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if ManagedAgent(rawValue: agent.name) != nil, !ui.hidePrivateDetails {
                HStack(spacing: 12) {
                    Button("연결 설정") { model.connect(agent: agent.name) }
                    if agent.connection.isConfigured {
                        Button("해제") { model.disconnect(agent: agent.name) }
                    }
                    Button("최근 백업 복구") { model.restoreSettings(agent: agent.name) }
                }
                .font(.system(size: 10.5))
                .buttonStyle(.plain)
                .foregroundStyle(Brand.accent)
                .disabled(model.connectionBusy || model.connecting.contains(agent.name))
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
            if ManagedAgent(rawValue: agent.name) == nil {
                Text("수동 설정 필요").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.connecting.contains(agent.name) {
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
                .buttonStyle(PanelPressStyle())
                .disabled(ui.hidePrivateDetails || model.connectionBusy)
                .help(ui.hidePrivateDetails
                      ? "개인 정보 표시를 켠 뒤 연결 설정을 확인하세요"
                      : "\(agent.name) 설정에 ContextOS MCP 서버를 등록해요")
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
