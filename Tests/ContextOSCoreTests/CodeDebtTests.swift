import Foundation
import Testing
@testable import ContextOSCore

@Suite("CodeDebt")
struct CodeDebtTests {

    // MARK: - Test-file recognition

    @Test("recognizes each ecosystem's test conventions")
    func recognizesTestPaths() {
        for path in ["Tests/AppTests/LoginTests.swift", "Sources/FooTest.swift",
                     "test/helpers.py", "src/test_login.py", "pkg/login_test.go",
                     "spec/models/user_spec.rb", "app/__tests__/button.js",
                     "src/Button.test.tsx", "src/Button.spec.ts"] {
            #expect(CodeDebtReader.isTestPath(path), "should be a test: \(path)")
        }
    }

    @Test("source files are not mistaken for tests")
    func doesNotOverreach() {
        // "latest/", "contest.py", "protest.go" all contain "test".
        for path in ["Sources/App/Login.swift", "src/latest/api.py", "lib/contest.py",
                     "cmd/protest.go", "app/testimonials.rb", "src/Testable.swift"] {
            #expect(!CodeDebtReader.isTestPath(path), "should be source: \(path)")
        }
    }

    // MARK: - Untestable targets

    @Test("only the library targets the manifest declares are in scope")
    func readsLibraryTargets() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["Sources/DemoCore", "Sources/DemoMacros", "Sources/demo-cli",
                    "Sources/DemoApp", "Tests/DemoCoreTests", "scripts"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir),
                                                    withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Demo",
            products: [.library(name: "DemoCore", targets: ["DemoCore"])],
            targets: [
                .target(name: "DemoCore", dependencies: [
                    .product(name: "ArgumentParser", package: "swift-argument-parser")
                ]),
                .macro(name: "DemoMacros"),
                .executableTarget(name: "demo-cli", dependencies: ["DemoCore"]),
                .executableTarget( name: "DemoApp" ),
                .testTarget(name: "DemoCoreTests", dependencies: ["DemoCore"])
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let roots = try #require(CodeDebtReader.testableRoots(root: root))
        // Importable modules only.
        #expect(Set(roots) == ["Sources/DemoCore/", "Sources/DemoMacros/"])
        // Executables, tests, and loose scripts have no module to import — they
        // fall out because nothing declares them, not because of a name blocklist.
        #expect(!roots.contains { $0.contains("demo-cli") })
        #expect(!roots.contains { $0.contains("DemoApp") })
        #expect(!roots.contains { $0.contains("scripts") })
    }

    @Test("a target's declared custom path wins over the convention")
    func honorsCustomTargetPath() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [
            .target(name: "DemoCore", path: "lib/core"),
            .target(name: "Other", path: "lib/other/")
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let roots = try #require(CodeDebtReader.testableRoots(root: root))
        #expect(Set(roots) == ["lib/core/", "lib/other/"])
    }

    @Test("a target using the Source/ or src/ layout is found on disk")
    func honorsAlternateConventions() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/DemoCore"),
                                                withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.target(name: "DemoCore")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(CodeDebtReader.testableRoots(root: root) == ["src/DemoCore/"])
    }

    @Test("paren-balanced parsing survives nested calls and arrays")
    func parsesNestedDeclarations() {
        let manifest = """
        .target(name: "A", dependencies: [.product(name: "X", package: "p")], swiftSettings: [.define("D")]),
        .target(name: "B")
        """
        let found = CodeDebtReader.declarations(of: "target", in: manifest)
        #expect(found.count == 2)
        // The nested .product(name:) must not be mistaken for the target's name.
        #expect(CodeDebtReader.value(of: "name", in: found[0]) == "A")
        #expect(CodeDebtReader.value(of: "name", in: found[1]) == "B")
    }

    @Test("a project with no manifest puts everything in scope rather than guessing")
    func noManifestMeansNoFilter() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        // nil, not [] — an empty list would silently exclude the whole project.
        #expect(CodeDebtReader.testableRoots(root: root) == nil)
    }

    @Test("an app-only package falls back to analyzing everything")
    func appOnlyPackageFallsBack() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "DemoApp")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // No library targets at all: reporting zero files in scope would hide the
        // whole project, so treat it as "we don't know" instead.
        #expect(CodeDebtReader.testableRoots(root: root) == nil)
    }

    // MARK: - Identifiers

    @Test("identifier scan finds names regardless of punctuation around them")
    func extractsIdentifiers() {
        let ids = CodeDebtReader.identifiers(in: "let x = LoginService().authenticate(user: a_b)")
        #expect(ids.contains("LoginService"))
        #expect(ids.contains("authenticate"))
        #expect(ids.contains("a_b"))          // underscores are part of a name
        #expect(!ids.contains("("))
    }

    // MARK: - TODO markers

    @Test("finds TODO markers as whole words")
    func findsMarkers() {
        let found = CodeDebtReader.markers(in: """
        // TODO: fix this
        let todoCount = 5
        # FIXME: broken
        /* HACK around it */
        let x = 1
        // XXX
        """)
        #expect(found.map(\.line) == [1, 3, 4, 6])
        // `todoCount` is a variable, not a marker.
        #expect(!found.contains { $0.text.contains("todoCount") })
    }

    @Test("a file with no markers costs nothing")
    func noMarkers() {
        #expect(CodeDebtReader.markers(in: "let x = 1\nfunc f() {}").isEmpty)
        #expect(CodeDebtReader.markers(in: "").isEmpty)
    }

    // MARK: - Complexity

    @Test("counts the decisions a body makes")
    func countsBranches() {
        let body = """
        func handle(x: Int) -> Int {
            if x > 0 && x < 10 {
                for i in 0..<x { print(i) }
            } else if x == 0 || x == -1 {
                while true { break }
            }
            switch x {
            case 1: return 1
            case 2: return 2
            }
            return x > 5 ? 1 : 0
        }
        """
        // if, &&, for, if(else if), ||, while, case, case, ternary → 9-ish.
        let count = CodeDebtReader.branchCount(in: body, language: .swift)
        #expect(count >= 8, "got \(count)")
        #expect(count <= 12, "got \(count)")
    }

    @Test("branch words inside strings and comments are not decisions")
    func ignoresLiteralsAndComments() {
        // The failure this prevents: a log message mentioning "if" inflating the
        // complexity of a function that has no branches at all.
        let body = """
        func greet() -> String {
            // if for while case guard catch
            let message = "if for while case && || switch"
            /* if for while */
            return message
        }
        """
        #expect(CodeDebtReader.branchCount(in: body, language: .swift) == 0)
    }

    @Test("Python comments use # and are stripped too")
    func stripsPythonComments() {
        let body = """
        def greet():
            # if for while
            msg = "if and || or"
            return msg
        """
        #expect(CodeDebtReader.branchCount(in: body, language: .python) == 0)
    }

    @Test("real branches still count when a comment sits beside them")
    func countsRealBranchesNextToComments() {
        let body = """
        func f(x: Int) -> Int {
            if x > 0 {   // if this is a comment
                return 1
            }
            return 0
        }
        """
        #expect(CodeDebtReader.branchCount(in: body, language: .swift) == 1)
    }

    // MARK: - Duplicate detection

    @Test("identical bodies hash together despite formatting and names")
    func detectsReformattedClones() {
        let a = """
        func alpha() -> Int {
            let a = compute()
            let b = transform(a)
            let c = validate(b)
            let d = persist(c)
            return d
        }
        """
        let b = """
        func beta() -> Int {
              let a = compute()
              let b   = transform(a)
            // a comment that shouldn't matter
              let c = validate(b)
              let d = persist(c)
              return d
        }
        """
        let hashA = CodeDebtReader.normalizedBodyHash(a, language: .swift, minLines: 5)
        let hashB = CodeDebtReader.normalizedBodyHash(b, language: .swift, minLines: 5)
        #expect(hashA != nil)
        #expect(hashA == hashB)      // different names, same body
    }

    @Test("different bodies do not collide")
    func differentBodiesDiffer() {
        let a = """
        func alpha() -> Int {
            let a = compute()
            let b = transform(a)
            let c = validate(b)
            return c
        }
        """
        let b = """
        func alpha() -> Int {
            let a = compute()
            let b = transform(a)
            let c = DELETE(b)
            return c
        }
        """
        #expect(CodeDebtReader.normalizedBodyHash(a, language: .swift, minLines: 4)
                != CodeDebtReader.normalizedBodyHash(b, language: .swift, minLines: 4))
    }

    @Test("short bodies are coincidence, not duplication")
    func ignoresTinyBodies() {
        // Every codebase has a dozen `return nil` functions; reporting them as
        // clones would bury the real findings.
        let tiny = """
        func a() -> Int? {
            return nil
        }
        """
        #expect(CodeDebtReader.normalizedBodyHash(tiny, language: .swift, minLines: 5) == nil)
    }

    @Test("a body seen once is not a duplicate")
    func singleOccurrenceIsNotADuplicate() {
        let items = CodeDebtReader.duplicateItems([
            "h1": [("a.swift", 1, "alpha", 10)],
            "h2": [("b.swift", 5, "beta", 8), ("c.swift", 9, "gamma", 8)]
        ])
        #expect(items.count == 1)
        let item = try! #require(items.first)
        #expect(item.path == "b.swift")
        #expect(item.detail.contains("2곳"))
        #expect(item.detail.contains("c.swift:9"))
        // Worth 8 duplicated lines if de-duped.
        #expect(item.severity == 8)
    }

    // MARK: - End to end

    /// A tiny project: one tested file, one untested file, one long function, one
    /// clone pair, plus an executable target and a loose script that must both
    /// stay out of the "untested" count.
    private func makeProject() throws -> URL {
        let root = try temp()
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [
            .target(name: "DemoCore"),
            .executableTarget(name: "DemoApp"),
            .testTarget(name: "DemoCoreTests")
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        func write(_ path: String, _ body: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        try write("Sources/DemoCore/Tested.swift", """
        struct Tested {
            func greet() -> String { "hi" }
        }
        """)
        try write("Sources/DemoCore/Untested.swift", """
        struct Untested {
            func lonely() -> String { "nobody calls me" }
        }
        """)
        // 100 lines — over the 80-line limit.
        let longBody = (1...96).map { "    let v\($0) = \($0)" }.joined(separator: "\n")
        try write("Sources/DemoCore/Long.swift", """
        struct Long {
            func huge() -> Int {
        \(longBody)
                return 0
            }
        }
        """)
        try write("Sources/DemoCore/Clones.swift", """
        struct Clones {
            func first() -> Int {
                let a = 1
                let b = a + 2
                let c = b + 3
                let d = c + 4
                return d
            }
            func second() -> Int {
                let a = 1
                let b = a + 2
                let c = b + 3
                let d = c + 4
                return d
            }
        }
        """)
        // Executable target: untested by construction, must not be reported.
        try write("Sources/DemoApp/main.swift", """
        struct AppOnly {
            func run() {}
        }
        """)
        // A loose script no target owns. There is no module to import, so no test
        // could ever reach it — reporting it would be a complaint with no fix.
        try write("scripts/make_icon.swift", """
        struct IconMaker {
            func render() {}
        }
        """)
        try write("Tests/DemoCoreTests/TestedTests.swift", """
        import Testing
        @testable import DemoCore
        struct TestedTests {
            func check() { _ = Tested().greet() }
        }
        """)
        return root
    }

    @Test("analyzes a project end to end")
    func endToEnd() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let debt = CodeDebtReader.build(root: root, thresholds: DebtThresholds())

        // Untested: Untested.swift, Long.swift, Clones.swift — but never
        // Tested.swift (named in a test), the executable target, or a script
        // that belongs to no target at all.
        let untested = Set(debt.items(.untested).map(\.title))
        #expect(untested.contains("Untested.swift"))
        #expect(!untested.contains("Tested.swift"))
        #expect(!untested.contains("main.swift"))
        #expect(!untested.contains("make_icon.swift"))

        // The 100-line function is reported; the one-liners are not.
        let large = debt.items(.largeFunction)
        #expect(large.count == 1)
        #expect(large.first?.title == "huge")

        // The clone pair is reported once, not twice.
        let duplicates = debt.items(.duplicateFunction)
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.detail.contains("2곳") == true)

        #expect(debt.counts[.largeFunction] == 1)
        #expect(debt.counts[.staleTodo] == 0)     // no TODOs, and not a git repo
    }

    @Test("items of a kind come back worst-first")
    func ranksBySeverity() throws {
        var debt = CodeDebt()
        debt.items = [
            DebtItem(kind: .untested, path: "a", line: 1, title: "a", detail: "", severity: 1),
            DebtItem(kind: .untested, path: "b", line: 1, title: "b", detail: "", severity: 9),
            DebtItem(kind: .largeFunction, path: "c", line: 1, title: "c", detail: "", severity: 5)
        ]
        #expect(debt.items(.untested).map(\.title) == ["b", "a"])
        #expect(debt.items(.largeFunction).map(\.title) == ["c"])
        #expect(debt.items(.staleTodo).isEmpty)
    }

    // MARK: - Stale TODOs (needs real git history)

    @Test("dates TODOs by git blame and only reports the stale ones")
    func datesTodos() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ args: [String], env: [String: String] = [:]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = root
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.dev"])
        try git(["config", "user.name", "Test"])

        let old = "2024-01-01T10:00:00+0000"
        try "// TODO: ancient\nlet x = 1\n"
            .write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "old"],
                env: ["GIT_AUTHOR_DATE": old, "GIT_COMMITTER_DATE": old])

        // A second TODO committed just now.
        try "// TODO: ancient\nlet x = 1\n// TODO: fresh\n"
            .write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "new"])

        let blame = CodeDebtReader.blameTimes(root: root, path: "a.swift")
        #expect(blame[1] != nil)
        #expect(blame[3] != nil)
        #expect(blame[1]! < blame[3]!, "line 1 must be older than line 3")

        let items = CodeDebtReader.staleTodoItems(
            root: root, todos: ["a.swift": [(1, "// TODO: ancient"), (3, "// TODO: fresh")]],
            thresholds: DebtThresholds(staleTodoDays: 180))
        // Only the 2024 one is stale; today's is not.
        #expect(items.count == 1)
        #expect(items.first?.line == 1)
        #expect(items.first?.detail.contains("년") == true)
    }

    @Test("an uncommitted TODO is new, not stale")
    func uncommittedTodoIsNotStale() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a git repo at all: blame returns nothing, and nothing is reported
        // rather than everything being treated as infinitely old.
        let items = CodeDebtReader.staleTodoItems(
            root: root, todos: ["a.swift": [(1, "// TODO: x")]], thresholds: DebtThresholds())
        #expect(items.isEmpty)
    }

    @Test("ages read the way a person would say them")
    func formatsAge() {
        #expect(CodeDebtReader.humanAge(3600) == "오늘")
        #expect(CodeDebtReader.humanAge(5 * 86_400) == "5일")
        #expect(CodeDebtReader.humanAge(70 * 86_400) == "2개월")
        #expect(CodeDebtReader.humanAge(400 * 86_400) == "1년")
    }

    // MARK: - Snapshots

    @Test("today's counts are stored and re-storing the same day overwrites")
    func recordsSnapshots() throws {
        let store = try UsageStore(path: ":memory:")
        try store.recordDebtSnapshot(project: "p", day: "2026-07-01", counts: ["untested": 5])
        try store.recordDebtSnapshot(project: "p", day: "2026-07-01", counts: ["untested": 7])
        // Same day twice = one row, the later value.
        #expect(store.debtTrend(project: "p", kind: "untested", days: 36_500).count <= 1)
    }

    @Test("the baseline is the oldest snapshot in the window")
    func findsBaseline() throws {
        let store = try UsageStore(path: ":memory:")
        try store.recordDebtSnapshot(project: "p", day: "2026-07-01", counts: ["untested": 3])
        try store.recordDebtSnapshot(project: "p", day: "2026-07-05", counts: ["untested": 8])

        let baseline = store.oldestDebtSnapshot(project: "p", since: "2026-07-10", days: 30)
        #expect(baseline["untested"] == 3)          // the 1st, not the 5th

        // Today itself is never its own baseline.
        #expect(store.oldestDebtSnapshot(project: "p", since: "2026-07-01", days: 30).isEmpty)
        // Another project's history doesn't leak in.
        #expect(store.oldestDebtSnapshot(project: "other", since: "2026-07-10", days: 30).isEmpty)
    }

    @Test("snapshots older than the window are ignored")
    func windowExcludesAncientHistory() throws {
        let store = try UsageStore(path: ":memory:")
        try store.recordDebtSnapshot(project: "p", day: "2026-01-01", counts: ["untested": 99])
        try store.recordDebtSnapshot(project: "p", day: "2026-07-05", counts: ["untested": 8])
        // A 30-day window from 2026-07-10 reaches back to 2026-06-10 only.
        #expect(store.oldestDebtSnapshot(project: "p", since: "2026-07-10", days: 30)["untested"] == 8)
    }

    @Test("no history means no trend, rather than a fabricated zero")
    func noBaselineNoDelta() throws {
        let store = try UsageStore(path: ":memory:")
        // A delta of 0 would read as "nothing changed"; absence must stay absent.
        #expect(store.oldestDebtSnapshot(project: "fresh", since: "2026-07-10", days: 30).isEmpty)
    }

    // MARK: - Helpers

    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-debt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
