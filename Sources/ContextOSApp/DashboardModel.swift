import Foundation
import AppKit
import ContextOSCore

/// Drives the menu-bar **monitor**. Optimization itself runs automatically via
/// the MCP server inside Claude Code — this panel just shows the results:
/// tokens saved, connected AI tools, and AI token usage.
///
/// This object lives for as long as the Mac is on, so nothing in it polls:
/// - Whether an agent is working comes from the hook and heartbeat
///   notifications plus a file-event stream on the session logs. A single
///   one-shot timer covers the moment a quiet window closes.
/// - Savings come from the MCP server's notification; a slow poll is only a
///   safety net, and what rolls "today" over at midnight.
/// - AI usage, agents and the week in code are only ever on screen inside the
///   panel, so they refresh when it opens and while it stays open. Closed, the
///   transcript cache is topped up every few minutes so opening stays instant.
@MainActor
final class DashboardModel: ObservableObject {

    @Published var todaySaved = 0
    @Published var totalSaved = 0
    @Published var queryCount = 0
    @Published var aiTokens = 0
    @Published var agents: [DetectedAgent] = []
    @Published var connected = false
    /// Token usage grouped by project, broken down per AI agent.
    @Published var projectUsage: [ProjectAIUsage] = []
    /// AI tokens per local day (`yyyy-MM-dd`), for the calendar.
    @Published var tokensByDay: [String: Int] = [:]
    /// Code shipped over the last 7 days.
    @Published var week = BuildSummary()
    /// Most recent optimization events, newest first.
    @Published var recent: [UsageEvent] = []
    /// Tokens saved per local day over the last two weeks, for the trend line.
    @Published var savingsByDay: [String: Int] = [:]
    /// agent → local day → tokens, for the calendar's per-agent split.
    @Published var agentDayTokens: [String: [String: Int]] = [:]
    /// Commits and lines for days picked on the calendar, loaded on demand.
    @Published var dayDetails: [String: DayDetail] = [:]
    /// When the panel's numbers were last brought up to date.
    @Published var lastUpdated: Date?
    /// Agents being connected right now, and what the last attempt said.
    @Published var connecting: Set<String> = []
    @Published var notice: String?
    /// What an agent is doing this minute, for the header. An object of its own
    /// so a turn starting or stopping redraws the header, not the whole panel.
    let live = LiveStatus()
    /// Chew state, shared by the menu-bar glyph and the dashboard blob so the
    /// two 뭉치 move as one. Both derive their motion from this plus the
    /// absolute clock; neither keeps its own timeline.
    let mascot = MascotState()

    /// Brief highlight when MCP just handled an optimization (energetic burst).
    ///
    /// Not `@Published`, and neither is `working`: only 뭉치 reads them, through
    /// `syncMascot`. Publishing them re-ran the whole dashboard's body — calendar,
    /// project cards and all — on every turn start and stop, with the panel shut.
    private var flashing = false { didSet { syncMascot() } }
    /// An AI agent is actively processing a command *right now* — from the
    /// moment the user hits enter until the response settles. Detected two
    /// ways: session-log writes (Claude Code/Codex, catches the very first
    /// keystroke of a turn) and MCP request heartbeats (any agent).
    private var working = false { didSet { syncMascot() } }

    /// One place decides whether 뭉치 is eating, so the two renderers can never
    /// disagree about it.
    private func syncMascot() { mascot.set(eating: flashing || working) }

    private let activityMonitor = AgentActivityMonitor()
    private var logEvents: FileEventStream?
    /// The roots `logEvents` was started on, to notice a new one (Codex
    /// installed after launch) and restart the stream.
    private var watchedPaths: [String] = []
    /// Only used when the event stream can't be started: the old rescan poll.
    private var pollTimer: Timer?
    /// Last MCP heartbeat / activity signal (posted by contextos-mcp and the
    /// UserPromptSubmit hook). Also the "turn start" time.
    private var lastActivity = Date.distantPast
    /// Last "turn ended" signal (the Stop hook). When this is newer than
    /// `lastActivity`, the agent finished and the mascot should stop *now*.
    private var lastStop = Date.distantPast
    /// Fires when the current verdict's quiet window closes — the only way
    /// `working` can change without an event.
    private var recheckTimer: Timer?
    /// Bumped by every evaluation, so a tail read that finishes after a newer
    /// evaluation has started can't overwrite it.
    private var evaluation = 0
    /// The last "does the newest log end on an unanswered tool call?" answer,
    /// and the log state it was read from, so the tail is read once per write
    /// rather than once per evaluation.
    private var pendingAnswer: (path: String, mtime: Date, pending: Bool)?

    private var lastQueryCount = -1
    private var savingsTimer: Timer?
    private var usageTimer: Timer?
    private var panelOpen = false
    private var usageRefreshInFlight = false
    /// A refresh asked for while another was running, run as soon as it ends —
    /// so opening the panel mid-way through a background top-up still gets the
    /// week in code, which the background pass skips.
    private var queuedUsageRefresh: (includeWeek: Bool, priority: TaskPriority)?
    private var flashTask: Task<Void, Never>?
    nonisolated(unsafe) private var optimizedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activityObserver: NSObjectProtocol?
    nonisolated(unsafe) private var startObserver: NSObjectProtocol?
    nonisolated(unsafe) private var stopObserver: NSObjectProtocol?

    /// Usage refresh cadence while the panel is open — its numbers stay live.
    private static let openUsageInterval: TimeInterval = 32
    /// Cadence while it is closed. Nothing on screen depends on it: it only
    /// keeps the transcript parse caught up, so the panel opens on fresh numbers
    /// without having hours of logs to read first.
    private static let closedUsageInterval: TimeInterval = 10 * 60
    /// The savings safety net. Every recorded optimization posts a notification,
    /// which is the real trigger.
    private static let savingsInterval: TimeInterval = 60

    init() {
        refreshFast()
        refreshSlow(includeWeek: true, priority: .utility)
        let center = DistributedNotificationCenter.default()
        // Real-time: the MCP server posts this the instant it records an
        // optimization, so the mascot reacts with no polling lag.
        optimizedObserver = center.addObserver(
            forName: UsageStore.optimizedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onOptimized() }
        }
        // Turn START — the UserPromptSubmit hook fires the instant the user hits
        // enter. Start eating immediately.
        startObserver = center.addObserver(
            forName: UsageStore.turnStartNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteActivity() }
        }
        // Turn STOP — the Stop hook fires the instant the agent finishes. Stop now.
        stopObserver = center.addObserver(
            forName: UsageStore.turnStopNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lastStop = Date()
                self?.evaluateWorking()
            }
        }
        // MCP heartbeat on every request: keeps a hook-less agent's turn alive.
        activityObserver = center.addObserver(
            forName: UsageStore.activityNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteActivity() }
        }

        watchSessionLogs()
        let monitor = activityMonitor
        Task.detached(priority: .utility) { [weak self] in
            monitor.rescan()
            await self?.evaluateWorking()
        }
        savingsTimer = Self.repeating(every: Self.savingsInterval) { [weak self] in
            self?.refreshFast()
        }
        scheduleUsageRefresh()
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        [optimizedObserver, activityObserver, startObserver, stopObserver]
            .compactMap { $0 }.forEach { center.removeObserver($0) }
    }

    // MARK: - Panel lifecycle

    /// The panel just opened: bring everything on it up to date now, then keep
    /// it live while it stays open.
    func panelDidOpen() {
        panelOpen = true
        dayDetails = [:]
        refreshFast()
        refreshSlow(includeWeek: true, priority: .userInitiated)
        scheduleUsageRefresh()
    }

    /// The panel closed: nothing on it is visible, so drop to the slow cadence.
    func panelDidClose() {
        panelOpen = false
        scheduleUsageRefresh()
    }

    private func scheduleUsageRefresh() {
        usageTimer?.invalidate()
        let interval = panelOpen ? Self.openUsageInterval : Self.closedUsageInterval
        usageTimer = Self.repeating(every: interval) { [weak self] in
            guard let self else { return }
            if self.panelOpen {
                self.refreshSlow(includeWeek: true, priority: .userInitiated)
            } else {
                // Utility, not background: a panel opened mid-way waits for this
                // pass to finish, and background work can be throttled for long.
                self.refreshSlow(includeWeek: false, priority: .utility)
                self.watchSessionLogs()     // a log root may have appeared since launch
            }
        }
    }

    // Instant reaction to a just-recorded optimization: light up now, refresh the
    // numbers right away.
    private func onOptimized() {
        flash()
        refreshFast()
    }

    /// Manual refresh (the ↻ button): rebuild everything from disk now, rather
    /// than serving whatever the memo last computed.
    func refresh() {
        refreshFast()
        refreshSlow(force: true, includeWeek: true, priority: .userInitiated)
    }

    // MARK: - Working detection

    /// A turn start or an MCP tool call: the agent is working as of now.
    private func noteActivity() {
        lastActivity = Date()
        evaluateWorking()
    }

    /// Watch the session-log trees for writes. Each one tells the monitor which
    /// log is hottest, replacing the directory rescan the old 2s poll did every
    /// few seconds for as long as the app ran.
    private func watchSessionLogs() {
        let fm = FileManager.default
        // A root that doesn't exist yet is watched through its parent, so the
        // agent's first session after install is seen too.
        let paths = activityMonitor.watchRoots.compactMap { root -> String? in
            if fm.fileExists(atPath: root.path) { return root.path }
            let parent = root.deletingLastPathComponent().path
            return fm.fileExists(atPath: parent) ? parent : nil
        }
        guard paths != watchedPaths || (logEvents == nil && pollTimer == nil) else { return }
        watchedPaths = paths
        logEvents?.stop()
        logEvents = nil
        pollTimer?.invalidate()
        pollTimer = nil
        // No agent installed at all: nothing to watch, and nothing to poll either.
        // The closed-panel refresh calls back in here, so a later install is seen.
        guard !paths.isEmpty else { return }

        let monitor = activityMonitor
        let stream = FileEventStream(paths: paths) { [weak self] events in
            var wrote = false
            var lost = false
            for event in events {
                if event.requiresRescan {
                    lost = true
                } else if monitor.noteWrite(atPath: event.path) {
                    wrote = true
                }
            }
            if lost { monitor.rescan() }
            guard wrote || lost else { return }
            Task { @MainActor in self?.evaluateWorking() }
        }
        if stream.start() {
            logEvents = stream
        } else {
            // No event stream: fall back to rescanning on a timer, like before.
            pollTimer = Self.repeating(every: 4) { [weak self] in
                Task.detached(priority: .utility) {
                    monitor.rescan()
                    await self?.evaluateWorking()
                }
            }
        }
    }

    /// Re-decide whether an agent is working, and arm a timer for the moment
    /// that answer next changes on its own.
    private func evaluateWorking() {
        evaluation += 1
        let ticket = evaluation
        recheckTimer?.invalidate()
        recheckTimer = nil

        let newest = activityMonitor.newestLog
        var pending: Bool?
        if let newest, let answer = pendingAnswer,
           answer.path == newest.url.path, answer.mtime == newest.mtime {
            pending = answer.pending
        }
        let verdict = TurnActivity.evaluate(now: Date(), lastActivity: lastActivity,
                                            lastStop: lastStop, lastLogWrite: newest?.mtime,
                                            pendingToolCall: pending)
        if verdict.needsPendingCheck, let newest {
            // The log has gone quiet: is it waiting on a long tool? That is a
            // tail read — off the main thread, once per write. `working` keeps
            // its value until the answer is in, so 뭉치 doesn't blink.
            Task.detached(priority: .utility) { [weak self] in
                let answer = AgentActivityMonitor.hasPendingToolCall(newest.url)
                await self?.pendingChecked(ticket: ticket, log: newest, pending: answer)
            }
            return
        }
        update(\.working, verdict.working)
        updateLive(working: verdict.working, newest: newest)
        if let at = verdict.recheckAt {
            let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateWorking() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            recheckTimer = timer
        }
    }

    /// Tell the header who is working where. The agent and project come from
    /// the newest session log, but only while that log is fresh: a heartbeat
    /// from some other MCP client says nothing about whose log went quiet an
    /// hour ago.
    private func updateLive(working: Bool, newest: (url: URL, mtime: Date)?) {
        var agent: String?
        var project: String?
        if let newest {
            let fresh = Date().timeIntervalSince(newest.mtime) < 120
            if fresh || !working {
                agent = activityMonitor.agent(ofLog: newest.url)
                project = AgentSessionReader.project(ofTranscript: newest.url.path)
                    .map { ($0 as NSString).lastPathComponent }
            }
        }
        live.update(working: working, agent: agent, project: project,
                    lastWrite: newest?.mtime)
    }

    private func pendingChecked(ticket: Int, log: (url: URL, mtime: Date), pending: Bool) {
        pendingAnswer = (log.url.path, log.mtime, pending)
        // A newer evaluation is already under way; it will pick the answer up
        // if it's still about the same write.
        guard ticket == evaluation else { return }
        evaluateWorking()
    }

    // MARK: - Data

    /// Assign only when the value actually changed.
    ///
    /// `@Published` fires on every assignment, equal or not, and each fire
    /// re-runs the whole panel's SwiftUI body. Through a key path the old value
    /// is read first and the setter is skipped outright; the `inout` helper this
    /// replaces could not do that — Swift writes an `inout` property back through
    /// its setter whether or not it changed, so every poll published anyway.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<DashboardModel, T>, _ value: T) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    // Cheap: savings counters from the local usage DB.
    private func refreshFast() {
        Task(priority: .utility) {
            let s = await Self.loadSavings()
            update(\.todaySaved, s.todaySaved)
            update(\.totalSaved, s.totalSaved)
            update(\.recent, s.recent)
            update(\.savingsByDay, s.savingsByDay)
            lastUpdated = Date()
            if lastQueryCount >= 0, s.queryCount > lastQueryCount { flash() }
            lastQueryCount = s.queryCount
            update(\.queryCount, s.queryCount)
        }
    }

    // Heavier: AI token usage (parses session logs) + agent detection, and — only
    // when the panel will show it — the week in code, which shells out to git.
    private func refreshSlow(force: Bool = false, includeWeek: Bool, priority: TaskPriority) {
        // One at a time: a refresh that lands while another is still parsing
        // would only wait on the same lock and redo its work. Remember it instead.
        guard force || !usageRefreshInFlight else {
            let queued = queuedUsageRefresh
            queuedUsageRefresh = (includeWeek || queued?.includeWeek == true,
                                  max(priority, queued?.priority ?? priority))
            return
        }
        usageRefreshInFlight = true
        Task(priority: priority) {
            let a = await Self.loadAgentsAndUsage(force: force, includeWeek: includeWeek)
            usageRefreshInFlight = false
            update(\.aiTokens, a.aiTokens)
            update(\.agents, a.agents)
            update(\.connected, a.connected)
            update(\.projectUsage, a.projectUsage)
            update(\.tokensByDay, a.tokensByDay)
            update(\.agentDayTokens, a.agentDayTokens)
            if let week = a.week { update(\.week, week) }
            lastUpdated = Date()
            if let next = queuedUsageRefresh {
                queuedUsageRefresh = nil
                refreshSlow(includeWeek: next.includeWeek, priority: next.priority)
            }
        }
    }

    // MARK: - Calendar days

    /// Load a picked day's commits and lines, unless they are already known.
    func loadDetail(for day: String) {
        guard dayDetails[day] == nil else { return }
        Task(priority: .userInitiated) {
            dayDetails[day] = await Self.loadDayDetail(day)
        }
    }

    private nonisolated static func loadDayDetail(_ day: String) async -> DayDetail {
        let usage = AgentSessionReader.snapshot()
        let log = BuildLogReader.log(since: BuildLogReader.dayStart(day), snapshot: usage)
        guard let entry = log.days.first(where: { $0.day == day }) else { return DayDetail() }
        return DayDetail(commits: entry.commits.count, added: entry.added, deleted: entry.deleted)
    }

    // MARK: - Connecting agents

    /// Register ContextOS with one agent that isn't connected yet.
    func connect(agent name: String) { connect([name]) }

    /// Every detected agent ContextOS can wire in but hasn't yet.
    func connectAll() {
        let names = agents.filter {
            if case .notConfigured = $0.connection { return true }
            return false
        }.map(\.name)
        guard !names.isEmpty else {
            showNotice("더 연결할 AI 도구가 없어요.")
            return
        }
        connect(names)
    }

    private func connect(_ names: [String]) {
        let pending = names.filter { !connecting.contains($0) }
        guard !pending.isEmpty else { return }
        connecting.formUnion(pending)
        Task(priority: .userInitiated) {
            let result = await Self.performConnect(pending)
            connecting.subtract(pending)
            if let command = result.manualCommand {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            showNotice(result.message)
            refreshSlow(includeWeek: false, priority: .userInitiated)
        }
    }

    private var noticeTask: Task<Void, Never>?

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    private struct ConnectResult: Sendable {
        var message: String
        /// A command the user has to run themselves, already on the clipboard.
        var manualCommand: String?
    }

    private nonisolated static func performConnect(_ names: [String]) async -> ConnectResult {
        guard let mcp = bundledBinary("contextos-mcp") else {
            return ConnectResult(message: "연결에 필요한 contextos-mcp 를 찾지 못했어요.")
        }
        let cli = bundledBinary("contextos") ?? mcp
        var connected: [String] = []
        var manual: String?
        for name in names {
            if name == "Claude Code" {
                if ClaudeIntegration.connect(mcpBinaryPath: mcp, cliBinaryPath: cli) {
                    connected.append(name)
                } else {
                    manual = ClaudeIntegration.mcpAddCommand(mcpBinaryPath: mcp)
                }
            } else if (try? AgentIntegration.connect(agent: name, mcpBinaryPath: mcp)) != nil {
                connected.append(name)
            }
        }
        if let manual {
            return ConnectResult(message: "Claude Code는 터미널에서 등록해야 해요. 명령어를 복사해 뒀어요.",
                                 manualCommand: manual)
        }
        guard !connected.isEmpty else {
            return ConnectResult(message: "연결하지 못했어요. 설정 파일을 확인해 주세요.")
        }
        return ConnectResult(message: connected.joined(separator: ", ") + " 연결됨 · 다시 시작하면 적용돼요")
    }

    /// A binary shipped with the app: in the bundle's Resources, or beside the
    /// executable for a `swift run` build.
    private nonisolated static func bundledBinary(_ name: String) -> String? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)]
        return candidates.compactMap { $0?.path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Show the bolt while ContextOS is actively working. Each new optimization
    // keeps it lit; it reverts to sparkles ~6s after the last activity, so during
    // a busy Claude Code session the bolt stays on.
    private func flash() {
        flashing = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.flashing = false }
        }
    }

    /// A repeating main-run-loop timer with enough tolerance for macOS to fold
    /// its wakeups in with everyone else's.
    private static func repeating(every interval: TimeInterval,
                                  _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    struct Savings: Sendable {
        var todaySaved = 0, totalSaved = 0, queryCount = 0
        var recent: [UsageEvent] = []
        var savingsByDay: [String: Int] = [:]
    }
    /// One calendar day's work in Git.
    struct DayDetail: Sendable, Equatable {
        var commits = 0
        var added = 0
        var deleted = 0
    }
    struct AgentsUsage: Sendable {
        var aiTokens = 0
        var agents: [DetectedAgent] = []
        var connected = false
        var projectUsage: [ProjectAIUsage] = []
        var tokensByDay: [String: Int] = [:]
        var agentDayTokens: [String: [String: Int]] = [:]
        /// Nil when this refresh skipped git.
        var week: BuildSummary?
    }

    private nonisolated static func loadSavings() async -> Savings {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return Savings() }
        let totals = store.savingsTotals(
            since: Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let twoWeeks = TimeKeys.localStartOfDay(Date().timeIntervalSince1970 - 13 * 86_400)
        return Savings(todaySaved: totals.todaySaved, totalSaved: totals.totalSaved,
                       queryCount: totals.queryCount, recent: store.recentEvents(limit: 30),
                       savingsByDay: store.savingsByDay(since: twoWeeks))
    }

    private nonisolated static func loadAgentsAndUsage(force: Bool, includeWeek: Bool) async -> AgentsUsage {
        if force {
            AgentSessionReader.invalidate()
            BuildLogReader.invalidate()
            ProjectAITokenReader.invalidate()
        }
        // One transcript pass feeds the headline figure, the per-project cards,
        // the calendar, and the week strip; they used to walk ~/.claude/projects
        // independently.
        let usage = AgentSessionReader.snapshot(maxAge: 5, force: force)
        let week = includeWeek
            ? BuildLogReader.log(
                since: TimeKeys.localStartOfDay(Date().timeIntervalSince1970 - 6 * 86_400),
                snapshot: usage).summary
            : nil
        let agents = AgentDetector.detect(usage: usage)
        return AgentsUsage(aiTokens: usage.totalTokens,
                           agents: agents,
                           connected: agents.contains { $0.connection.isConfigured },
                           projectUsage: ProjectAITokenReader.topProjects(snapshot: usage),
                           tokensByDay: usage.byDay,
                           agentDayTokens: usage.byAgentDay,
                           week: week)
    }
}

/// Who is working where, right now — the dashboard header's live line.
@MainActor
final class LiveStatus: ObservableObject {
    @Published private(set) var working = false
    /// The agent and project of the newest session log, when known.
    @Published private(set) var agent: String?
    @Published private(set) var project: String?
    /// When the current turn started — or, while idle, when the last one ended.
    @Published private(set) var since: Date?

    func update(working: Bool, agent: String?, project: String?, lastWrite: Date?, now: Date = Date()) {
        if working != self.working {
            self.working = working
            since = now
        } else if since == nil {
            // The first word since launch: an idle agent was last active when
            // its log was last written.
            since = working ? now : lastWrite
        }
        if let agent, agent != self.agent { self.agent = agent }
        if let project, project != self.project { self.project = project }
    }
}
