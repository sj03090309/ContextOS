import XCTest
@testable import ContextOSCore

final class GitignoreMatcherTests: XCTestCase {

    func testBasicNameMatchesAtAnyDepth() {
        let m = GitignoreMatcher(patterns: ["secret.txt"])
        XCTAssertTrue(m.isIgnored("secret.txt", isDirectory: false))
        XCTAssertTrue(m.isIgnored("a/b/secret.txt", isDirectory: false))
        XCTAssertFalse(m.isIgnored("secret.txt.bak", isDirectory: false))
    }

    func testStarGlobDoesNotCrossSlashes() {
        let m = GitignoreMatcher(patterns: ["*.log"])
        XCTAssertTrue(m.isIgnored("app.log", isDirectory: false))
        XCTAssertTrue(m.isIgnored("logs/app.log", isDirectory: false))
        XCTAssertFalse(m.isIgnored("app.log/keep.txt", isDirectory: false))
    }

    func testAnchoredPattern() {
        let m = GitignoreMatcher(patterns: ["/generated"])
        XCTAssertTrue(m.isIgnored("generated", isDirectory: true))
        XCTAssertFalse(m.isIgnored("src/generated", isDirectory: true))
    }

    func testMidSlashAnchorsToRoot() {
        let m = GitignoreMatcher(patterns: ["docs/tmp"])
        XCTAssertTrue(m.isIgnored("docs/tmp", isDirectory: true))
        XCTAssertFalse(m.isIgnored("x/docs/tmp", isDirectory: true))
    }

    func testDirectoryOnlyPattern() {
        let m = GitignoreMatcher(patterns: ["cache/"])
        XCTAssertTrue(m.isIgnored("cache", isDirectory: true))
        XCTAssertFalse(m.isIgnored("cache", isDirectory: false))
    }

    func testNegationLastMatchWins() {
        let m = GitignoreMatcher(patterns: ["*.env", "!example.env"])
        XCTAssertTrue(m.isIgnored("prod.env", isDirectory: false))
        XCTAssertFalse(m.isIgnored("example.env", isDirectory: false))
    }

    func testDoubleStarSpansDirectories() {
        let m = GitignoreMatcher(patterns: ["a/**/b"])
        XCTAssertTrue(m.isIgnored("a/b", isDirectory: true))
        XCTAssertTrue(m.isIgnored("a/x/y/b", isDirectory: true))
        XCTAssertFalse(m.isIgnored("a/bc", isDirectory: true))
    }

    func testCommentsAndBlanksSkipped() {
        let m = GitignoreMatcher(patterns: ["# comment", "", "real.txt"])
        XCTAssertTrue(m.isIgnored("real.txt", isDirectory: false))
        XCTAssertFalse(m.isIgnored("# comment", isDirectory: false))
    }

    func testScannerHonorsGitignore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-gitignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("gen"), withIntermediateDirectories: true)
        try "kept".write(to: root.appendingPathComponent("keep.swift"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("skip.swift"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("gen/deep.swift"), atomically: true, encoding: .utf8)
        try "skip.swift\ngen/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try ProjectScanner().scan(root: root).map(\.relativePath)
        XCTAssertTrue(paths.contains("keep.swift"))
        XCTAssertFalse(paths.contains("skip.swift"))
        XCTAssertFalse(paths.contains("gen/deep.swift"))
    }
}

final class NewLanguageParserTests: XCTestCase {

    private let parser = HeuristicParser()

    func testSupportsNewLanguages() {
        for lang in [Language.c, .cpp, .ruby, .objectiveC] {
            XCTAssertTrue(parser.supports(lang), "\(lang) should be supported")
        }
        XCTAssertFalse(parser.supports(.unknown))
    }

    func testCSymbols() {
        let src = """
        #include <stdio.h>
        struct point {
            int x, y;
        };
        int add(int a, int b) {
            return a + b;
        }
        if (x) {
        }
        """
        let parsed = parser.parse(source: src, language: .c)
        XCTAssertEqual(parsed.imports.map(\.module), ["stdio.h"])
        XCTAssertTrue(parsed.symbols.contains { $0.name == "point" && $0.kind == .type })
        XCTAssertTrue(parsed.symbols.contains { $0.name == "add" && $0.kind == .function })
        XCTAssertFalse(parsed.symbols.contains { $0.name == "x" })
    }

    func testCppSymbols() {
        let src = """
        #include "engine.h"
        namespace core {
        class Renderer {
        public:
            void draw();
        };
        }
        """
        let parsed = parser.parse(source: src, language: .cpp)
        XCTAssertEqual(parsed.imports.map(\.module), ["engine.h"])
        XCTAssertTrue(parsed.symbols.contains { $0.name == "core" && $0.kind == .type })
        XCTAssertTrue(parsed.symbols.contains { $0.name == "Renderer" && $0.kind == .type })
    }

    func testRubySymbols() {
        let src = """
        require 'json'
        require_relative 'helper'
        class Parser
          def parse!(input)
            input
          end
          def self.default
            new
          end
        end
        """
        let parsed = parser.parse(source: src, language: .ruby)
        XCTAssertEqual(parsed.imports.map(\.module), ["json", "helper"])
        XCTAssertTrue(parsed.symbols.contains { $0.name == "Parser" && $0.kind == .type })
        XCTAssertTrue(parsed.symbols.contains { $0.name == "parse!" && $0.kind == .function })
        XCTAssertTrue(parsed.symbols.contains { $0.name == "default" && $0.kind == .function })
    }

    func testObjectiveCSymbols() {
        let src = """
        #import <Foundation/Foundation.h>
        @interface Downloader : NSObject
        - (void)startWithURL:(NSURL *)url;
        @end
        @implementation Downloader
        - (void)startWithURL:(NSURL *)url {
        }
        @end
        """
        let parsed = parser.parse(source: src, language: .objectiveC)
        XCTAssertEqual(parsed.imports.map(\.module), ["Foundation/Foundation.h"])
        XCTAssertTrue(parsed.symbols.contains { $0.name == "Downloader" && $0.kind == .type })
        XCTAssertTrue(parsed.symbols.contains { $0.name == "startWithURL" && $0.kind == .function })
    }
}

final class SessionToolsTests: XCTestCase {

    func testProjectRulesReadsCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".contextos"), withIntermediateDirectories: true)
        try "- 항상 한국어로 커밋".write(
            to: root.appendingPathComponent(".contextos/rules.md"), atomically: true, encoding: .utf8)
        try "# 프로젝트 규칙".write(
            to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let rules = ContextService().projectRules(projectRoot: root)
        XCTAssertNotNil(rules)
        XCTAssertTrue(rules!.contains(".contextos/rules.md"))
        XCTAssertTrue(rules!.contains("항상 한국어로 커밋"))
        XCTAssertTrue(rules!.contains("CLAUDE.md"))
    }

    func testProjectRulesNilWhenAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-norules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(ContextService().projectRules(projectRoot: root))
    }

    func testSessionSnapshotOutsideRepo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = ContextService().sessionSnapshot(projectRoot: root)
        XCTAssertTrue(snapshot.contains("Session snapshot"))
        XCTAssertTrue(snapshot.contains("Not a git repository"))
    }
}
