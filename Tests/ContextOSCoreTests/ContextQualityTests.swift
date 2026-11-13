import Foundation
import Testing
@testable import ContextOSCore

@Suite("Context implementation retention")
struct ContextQualityTests {
    private let slicer = CodeSlicer(minLinesToSlice: 5, maxKeepFraction: 0.9)
    private var pythonNoise: String { "\ndef unrelated():\n" + String(repeating: "    print('UNRELATED_BODY')\n", count: 100) }
    private var swiftNoise: String { "\nfunc unrelated() {\n" + String(repeating: "    print(0)\n", count: 100) + "}\n" }
    private var tsNoise: String { "\nfunction unrelated() {\n" + String(repeating: "  console.log(0);\n", count: 100) + "}\n" }

    @Test("Same-file helpers, transitive helpers and their global bindings survive")
    func pythonDependencies() {
        let source = """
        import hashlib
        SIGNING_KEYS = {
            'active': 'REQUIRED_GLOBAL_KEY'
        }
        def login(token):
            return verify_signature(token)
        def verify_signature(token):
            return normalize(token) in SIGNING_KEYS
        def normalize(token):
            return token.strip() + 'REQUIRED_NORMALIZATION'
        """ + pythonNoise
        let result = slicer.slice(source: source, language: .python, terms: ["login"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_GLOBAL_KEY"))
        #expect(result.content.contains("REQUIRED_NORMALIZATION"))
        #expect(result.content.contains("return normalize(token) in SIGNING_KEYS"))
        #expect(!result.content.contains("UNRELATED_BODY"))
    }

    @Test("Dependency cycles terminate and literal/comment mentions do not pull unrelated bodies")
    func cyclesAndFalseReferences() {
        let source = """
        def login(token):
            # fake_helper(token)
            label = 'fake_helper should not be called'
            return verify(token)
        def verify(token):
            return normalize(token) + 'VERIFY_BODY'
        def normalize(token):
            return verify(token)
        def fake_helper(token):
            return 'WRONG_BODY'
        """ + pythonNoise
        let result = slicer.slice(source: source, language: .python, terms: ["login"])
        #expect(result.content.contains("VERIFY_BODY"))
        #expect(!result.content.contains("WRONG_BODY"))
    }

    @Test("A requested Swift method keeps its own helper and property, not another type's same-named helper")
    func scopedSwiftHelpers() {
        let source = """
        struct Account {
            private let allowed = "REQUIRED_PROPERTY"
            func login(_ token: String) -> Bool {
                return verify(token) == allowed
            }
            func verify(_ token: String) -> String {
                return token + "REQUIRED_HELPER"
            }
        }
        struct Unrelated {
            func verify(_ token: String) -> String {
                return "WRONG_TYPE_BODY"
            }
        }
        """ + swiftNoise
        let result = slicer.slice(source: source, language: .swift, terms: ["login"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_PROPERTY"))
        #expect(result.content.contains("REQUIRED_HELPER"))
        #expect(!result.content.contains("WRONG_TYPE_BODY"))
    }

    @Test("A type name plus a specific method does not retain the whole enclosing type")
    func enclosingTypeDoesNotSwallowBudget() {
        let source = "struct AccountService {\n    func login() { print(\"REQUIRED_LOGIN\") }\n    func exportRecords() {\n"
            + String(repeating: "        print(\"UNRELATED_EXPORT\")\n", count: 100) + "    }\n}\n"
        let result = slicer.slice(source: source, language: .swift, terms: ["account", "service", "login"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_LOGIN"))
        #expect(!result.content.contains("UNRELATED_EXPORT"))
    }

    @Test("An explicitly requested type keeps real implementation while dropping filler comments")
    func explicitType() {
        let source = "struct AccountService {\n    func login() { print(\"REQUIRED_LOGIN\") }\n"
            + String(repeating: "    // filler comment\n", count: 600) + "}\n"
        let result = slicer.slice(source: source, language: .swift, terms: ["account", "service"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_LOGIN"))
        #expect(TokenEstimator().estimate(text: result.content) < 250)
    }

    @Test("Interpolation helpers survive while literal braces do not truncate ranges")
    func interpolation() {
        let swift = #"func login(_ token: String) -> String { return "value \(verify(token)) }" }"#
            + "\nfunc verify(_ token: String) -> String { return \"REQUIRED_SWIFT_HELPER\" }\n" + swiftNoise
        #expect(slicer.slice(source: swift, language: .swift, terms: ["login"]).content.contains("REQUIRED_SWIFT_HELPER"))
        let ts = "const login = (token: string) => `value ${verify(token)} }`;\n"
            + "const verify = (token: string) => 'REQUIRED_TS_HELPER';\n" + tsNoise
        #expect(slicer.slice(source: ts, language: .typescript, terms: ["login"]).content.contains("REQUIRED_TS_HELPER"))
    }

    @Test("Python floor division retains its right-hand helper")
    func floorDivision() {
        let source = "def login(x):\n    return x // divisor()\ndef divisor():\n    return 2 + REQUIRED_DIVISOR\n" + pythonNoise
        #expect(slicer.slice(source: source, language: .python, terms: ["login"]).content.contains("2 + REQUIRED_DIVISOR"))
    }

    @Test("Python multiline signatures and f-string dependencies retain helper bodies")
    func pythonSignaturesAndInterpolation() {
        let source = "def login(\n    token: str,\n) -> str:\n    return f'accepted: {verify(token)}'\n"
            + "def verify(token):\n    return 'REQUIRED_FSTRING_HELPER'\n" + pythonNoise
        let result = slicer.slice(source: source, language: .python, terms: ["login"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_FSTRING_HELPER"))
        #expect(!result.content.contains("UNRELATED_BODY"))
        let docstring = "def login():\n    \"\"\"REQUIRED_DOCSTRING\n    continuation\n    \"\"\"\n" + pythonNoise
        #expect(slicer.slice(source: docstring, language: .python, terms: ["login"]).content.contains("continuation\n    \"\"\""))
    }

    @Test("Object return types and regex arrow expressions do not end a type or helper early")
    func typedHelperAndRegex() {
        let source = """
        class Access {
          pattern = () => /}/;
          authorize(user: User) { return this.verify(user); }
          verify(user: User): { allowed: boolean } {
            return { allowed: REQUIRED_TYPED_HELPER };
          }
        }
        """ + tsNoise
        let result = slicer.slice(source: source, language: .typescript, terms: ["authorize"])
        #expect(result.content.contains("REQUIRED_TYPED_HELPER"))
        #expect(!result.content.contains("console.log(0)"))
    }

    @Test("Parser recognizes arrow, async, generic, expression and function-expression bindings", arguments: [
        "export const authorize = (user: User) => {\n  return REQUIRED_CHECK;\n};",
        "export const authorize = async <T>(user: T): Promise<boolean> => {\n  return REQUIRED_CHECK;\n};",
        "export const authorize = (\n  user: User\n) =>\n  verify(user) && REQUIRED_CHECK;",
        "const authorize = user => ({ allowed: REQUIRED_CHECK });",
        "export const authorize = function(user: User) {\n  return REQUIRED_CHECK;\n};",
        "const authorize = (user: User) =>\n  /}/.test(user.role) && REQUIRED_CHECK;"
    ])
    func arrows(_ declaration: String) {
        let source = declaration + tsNoise
        let parsed = HeuristicParser().parse(source: source, language: .typescript)
        let sym = parsed.symbols.first { $0.name == "authorize" }
        #expect(sym?.kind == .function)
        #expect(sym?.endLine == declaration.components(separatedBy: "\n").count)
        let result = slicer.slice(source: source, language: .typescript, terms: ["authorize"])
        #expect(result.sliced)
        #expect(result.content.contains("REQUIRED_CHECK"))
        #expect(!result.content.contains("console.log(0)"))
    }

    @Test("Class arrow fields and methods retain their helpers")
    func classArrow() {
        let source = """
        class Access {
          private authorize = (user: User) => this.verify(user);
          verify(user: User) { return 'REQUIRED_CLASS_HELPER'; }
          unrelated() {
        """ + "\n" + String(repeating: "    console.log('WRONG_CLASS_BODY');\n", count: 100) + "  }\n}\n"
        let result = slicer.slice(source: source, language: .typescript, terms: ["authorize"])
        #expect(result.content.contains("REQUIRED_CLASS_HELPER"))
        #expect(!result.content.contains("WRONG_CLASS_BODY"))
    }

    @Test("String or commented declarations are not indexed as implementations")
    func noPhantomDeclarations() {
        let source = """
        const text = "const fakeArrow = () => 1";
        // function fakeComment() { }
        /*
        export const fakeBlock = () => 2;
        */
        const authorize = (user: User) => true;
        """
        let names = HeuristicParser().parse(source: source, language: .typescript).symbols.map(\.name)
        #expect(names == ["authorize"])
    }

    @Test("A multiline literal used by a helper remains complete")
    func multilineLiteral() {
        let source = "const POLICY = `first\n// required literal line\nlast`;\n"
            + "const authorize = (user: User) => POLICY.includes(user.role);\n" + tsNoise
        let result = slicer.slice(source: source, language: .typescript, terms: ["authorize"])
        #expect(result.content.contains("// required literal line\nlast`"))
    }

    @Test("Unterminated lexical input returns the source rather than a confidently truncated slice")
    func uncertainLexing() {
        let source = "func login() { print(\"unterminated) }\n" + swiftNoise
        let result = slicer.slice(source: source, language: .swift, terms: ["login"])
        #expect(!result.sliced)
        #expect(result.content == source)
    }
}

@Suite("Implementation retrieval and index upgrade")
struct ImplementationRetrievalTests {
    private func project(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-quality-\(UUID())")
        for (path, body) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Named implementations outrank word-rich tests; explicit test requests still find tests")
    func namedImplementation() throws {
        let root = try project([
            "src/access.swift": "struct AccessController {\nfunc authorize() {}\n}\n",
            "Tests/AccessTests.swift": "func testAccessControllerAuthorizePermissionRoleChecks() {}\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        #expect(try service.relevantContext(query: "AccessController authorize permission role", projectRoot: root, tokenBudget: 8000).included.first?.path == "src/access.swift")
        #expect(try service.relevantContext(query: "testAccessControllerAuthorizePermissionRoleChecks", projectRoot: root, tokenBudget: 8000).included.first?.path == "Tests/AccessTests.swift")
        #expect(try service.relevantContext(query: "Tests/AccessTests.swift", projectRoot: root, tokenBudget: 8000).included.first?.path == "Tests/AccessTests.swift")
    }

    @Test("An existing unchanged index automatically picks up the new arrow parser exactly once")
    func parserUpgrade() throws {
        let source = "export const authorize = (user: User) => true;\n"
        let root = try project(["access.ts": source])
        defer { try? FileManager.default.removeItem(at: root) }
        try Indexer().index(projectRoot: root)
        let store = try Indexer.openStore(forProjectRoot: root)
        let original = try #require(store.allFiles().first)
        try store.deleteFile(id: #require(original.id))
        let id = try store.insertFile(IndexedFile(relativePath: original.relativePath, language: original.language,
            byteSize: original.byteSize, lineCount: original.lineCount, contentHash: original.contentHash, modifiedAt: original.modifiedAt))
        try store.insertSymbol(Symbol(name: "legacy_only", kind: .function, line: 1), fileID: id)
        try store.setParserRevision("before-arrow-support")
        let result = try ContextService(useGitSignals: false).relevantContext(query: "authorize", projectRoot: root, tokenBudget: 8000)
        #expect(result.included.map(\.path) == ["access.ts"])
        let names = try Indexer.openStore(forProjectRoot: root).symbolNames()
        #expect(names.contains("authorize"))
        #expect(!names.contains("legacy_only"))
        #expect(try Indexer().index(projectRoot: root).symbolsIndexed == 0)
    }
}
