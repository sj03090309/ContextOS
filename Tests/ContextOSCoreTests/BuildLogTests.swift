import Foundation
import Testing
@testable import ContextOSCore

@Suite("BuildLog")
struct BuildLogTests {

    // MARK: - Noise filtering

    @Test("lock files and generated output never count as work")
    func filtersNoise() {
        // The failure this prevents: one refreshed lock file is tens of thousands
        // of lines and would dwarf every real number in the log.
        for path in ["package-lock.json", "ios/Podfile.lock", "Package.resolved",
                     "go.sum", "Cargo.lock", "sub/dir/yarn.lock",
                     "node_modules/react/index.js", "vendor/foo/bar.go",
                     ".build/debug/thing.o", "web/dist/app.js", "Pods/Alamofire/x.swift",
                     "static/app.min.js", "static/app.min.css", "app.js.map",
                     "App.xcodeproj/project.pbxproj", "api/service.pb.go",
                     "gen/schema_pb2.py", "__snapshots__/Button.snap",
                     ".contextos/index.sqlite", "src/.contextos/cache"] {
            #expect(BuildLogReader.isNoise(path), "should be filtered: \(path)")
        }
    }

    @Test("real source is never mistaken for noise")
    func keepsRealWork() {
        for path in ["src/login.py", "Sources/App/Main.swift", "README.md",
                     "package.json", "Cargo.toml", "go.mod", "Dockerfile",
                     "Tests/AppTests/LoginTests.swift", "app/models/user.rb"] {
            #expect(!BuildLogReader.isNoise(path), "should be kept: \(path)")
        }
    }

    @Test("directory filters anchor at a path boundary")
    func directoryFiltersAnchor() {
        // "build/" must not swallow "rebuild/" or "buildkite.yml" — the bug you
        // get from a naive `contains`.
        #expect(!BuildLogReader.isNoise("rebuild/tool.swift"))
        #expect(!BuildLogReader.isNoise("src/buildkite.yml"))
        #expect(!BuildLogReader.isNoise("distribution/notes.md"))
        #expect(!BuildLogReader.isNoise("outbox/mail.rb"))
        #expect(BuildLogReader.isNoise("build/tool.o"))
        #expect(BuildLogReader.isNoise("packages/web/build/main.js"))
    }

    @Test("rename notation resolves to the destination path")
    func parsesRenames() {
        #expect(BuildLogReader.renameTarget("old/a.swift => new/b.swift") == "new/b.swift")
        #expect(BuildLogReader.renameTarget("src/{old => new}/file.swift") == "src/new/file.swift")
        #expect(BuildLogReader.renameTarget("src/{ => new}/file.swift") == "src/new/file.swift")
        #expect(BuildLogReader.renameTarget("plain/file.swift") == "plain/file.swift")
        // A file renamed *into* a lock file is still noise.
        #expect(BuildLogReader.isNoise(BuildLogReader.renameTarget("a.json => yarn.lock")))
    }

    // MARK: - numstat

    @Test("numstat sums real files and skips binary and noise")
    func parsesNumstat() {
        let stats = BuildLogReader.numstat("""
        10\t2\tsrc/login.py
        5\t1\tsrc/auth.py
        -\t-\tassets/logo.png
        9000\t8000\tpackage-lock.json
        """)
        #expect(stats.added == 15)      // binary and the lock file contribute nothing
        #expect(stats.deleted == 3)
        #expect(stats.files == 2)
    }

    @Test("numstat tolerates empty and malformed input")
    func numstatEdgeCases() {
        #expect(BuildLogReader.numstat("").files == 0)
        #expect(BuildLogReader.numstat("\n\n").files == 0)
        #expect(BuildLogReader.numstat("garbage without tabs").files == 0)
        // A path containing a tab still parses: maxSplits keeps it in one column.
        #expect(BuildLogReader.numstat("1\t1\tsrc/a b.py").files == 1)
    }

    // MARK: - AI attribution

    @Test("credits the agent named in a Co-Authored-By trailer")
    func attributesByTrailer() {
        let agents = BuildLogReader.attribute(
            body: "Some body\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>\n",
            at: 1000, project: "/tmp/x", usage: AgentUsageSnapshot())
        #expect(agents == ["Claude Code"])
    }

    @Test("credits an agent whose session was live when the commit landed")
    func attributesBySessionOverlap() {
        // Codex adds no trailer, so overlap is the only signal there is.
        var usage = AgentUsageSnapshot()
        usage.sessions = [AgentSession(agent: "Codex", project: "/tmp/proj",
                                       start: 900, end: 1100, tokens: 500)]
        let inside = BuildLogReader.attribute(body: "no trailer", at: 1000,
                                              project: "/tmp/proj", usage: usage)
        #expect(inside == ["Codex"])

        let outside = BuildLogReader.attribute(body: "no trailer", at: 2000,
                                               project: "/tmp/proj", usage: usage)
        #expect(outside.isEmpty)
    }

    @Test("a session in another project does not get the credit")
    func attributionIsProjectScoped() {
        var usage = AgentUsageSnapshot()
        usage.sessions = [AgentSession(agent: "Codex", project: "/tmp/other",
                                       start: 900, end: 1100, tokens: 500)]
        #expect(BuildLogReader.attribute(body: "", at: 1000,
                                         project: "/tmp/proj", usage: usage).isEmpty)
    }

    @Test("trailer and overlap agree on one agent rather than double-crediting")
    func attributionDeduplicates() {
        var usage = AgentUsageSnapshot()
        usage.sessions = [AgentSession(agent: "Claude Code", project: "/tmp/proj",
                                       start: 900, end: 1100, tokens: 500)]
        let agents = BuildLogReader.attribute(
            body: "Co-Authored-By: Claude <noreply@anthropic.com>",
            at: 1000, project: "/tmp/proj", usage: usage)
        #expect(agents == ["Claude Code"])
    }

    // MARK: - End to end, against a real repository

    /// A repo with two commits on different days, one AI-attributed, plus a
    /// lock file large enough to swamp the stats if it were counted.
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-buildlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        func git(_ args: [String], env: [String: String] = [:]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = root
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        func write(_ rel: String, _ body: String) throws {
            try body.write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }

        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.dev"])
        try git(["config", "user.name", "Test"])

        try write("src/login.py", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try write("package-lock.json", (1...5000).map { "  \"dep\($0)\": \"1.0.0\"," }
            .joined(separator: "\n") + "\n")
        try git(["add", "."])
        let day1 = "2026-07-01T10:00:00+0000"
        try git(["commit", "-q", "-m", "Add login"],
                env: ["GIT_AUTHOR_DATE": day1, "GIT_COMMITTER_DATE": day1])

        try write("src/login.py", (1...4).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let day2 = "2026-07-02T10:00:00+0000"
        try git(["commit", "-q", "-am", """
        Fix login crash

        Co-Authored-By: Claude Opus <noreply@anthropic.com>
        """], env: ["GIT_AUTHOR_DATE": day2, "GIT_COMMITTER_DATE": day2])
        return root
    }

    @Test("reads a real repo: day grouping, line counts, and AI attribution")
    func readsRealRepo() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        BuildLogReader.invalidate()

        let since = TimeKeys.epoch(fromISO8601: "2026-06-01T00:00:00Z") ?? 0
        let log = BuildLogReader.log(since: since, snapshot: AgentUsageSnapshot(), repos: [root.path])

        #expect(log.summary.commits == 2)
        // 10 lines of login.py. The 5000-line lock file must not appear.
        #expect(log.summary.added == 10)
        #expect(log.summary.deleted == 6)      // 10 lines down to 4
        #expect(log.summary.aiCommits == 1)
        #expect(log.summary.activeDays == 2)

        // Newest day first, one commit each.
        #expect(log.days.count == 2)
        #expect(log.days[0].day > log.days[1].day)
        #expect(log.days[0].commits.first?.subject == "Fix login crash")
        #expect(log.days[0].commits.first?.agents == ["Claude Code"])
        #expect(log.days[1].commits.first?.subject == "Add login")
        #expect(log.days[1].commits.first?.agents.isEmpty == true)
        #expect(log.days[1].commits.first?.added == 10)
    }

    @Test("uncommitted work shows up on today, and only today")
    func reportsUncommittedWork() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        BuildLogReader.invalidate()

        try "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n"
            .write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)

        let since = TimeKeys.epoch(fromISO8601: "2026-06-01T00:00:00Z") ?? 0
        let log = BuildLogReader.log(since: since, snapshot: AgentUsageSnapshot(), repos: [root.path])

        let today = TimeKeys.localDay(Date().timeIntervalSince1970)
        let entry = try #require(log.days.first { $0.day == today })
        #expect(entry.uncommittedAdded == 2)     // 4 lines up to 6
        #expect(entry.uncommittedDeleted == 0)
        // No other day claims uncommitted work.
        #expect(log.days.filter { $0.uncommittedAdded > 0 }.count == 1)
    }

    @Test("a day of AI work with no commits still appears in the log")
    func tokenOnlyDayAppears() throws {
        // "What did I do today?" is often answered by a day of exploration with
        // nothing committed. Dropping those days would hide real work.
        var usage = AgentUsageSnapshot()
        let today = TimeKeys.localDay(Date().timeIntervalSince1970)
        usage.byDay = [today: 12_345]

        let log = BuildLogReader.log(since: Date().timeIntervalSince1970 - 86_400,
                                     snapshot: usage, repos: [])
        #expect(log.days.count == 1)
        #expect(log.days[0].tokens == 12_345)
        #expect(log.summary.tokens == 12_345)
        #expect(log.summary.commits == 0)
    }

    @Test("tokens from before the window are not counted in the summary")
    func excludesOldTokens() {
        var usage = AgentUsageSnapshot()
        let now = Date().timeIntervalSince1970
        usage.byDay = [
            TimeKeys.localDay(now): 100,
            TimeKeys.localDay(now - 40 * 86_400): 9_999   // well outside a 7-day window
        ]
        let log = BuildLogReader.log(since: now - 7 * 86_400, snapshot: usage, repos: [])
        #expect(log.summary.tokens == 100)
        #expect(log.days.count == 1)
    }

    @Test("a non-repo path yields an empty log instead of failing")
    func toleratesNonRepo() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        BuildLogReader.invalidate()

        let log = BuildLogReader.log(since: 0, snapshot: AgentUsageSnapshot(), repos: [tmp.path])
        #expect(log.days.isEmpty)
        #expect(log.summary.commits == 0)
    }
}
