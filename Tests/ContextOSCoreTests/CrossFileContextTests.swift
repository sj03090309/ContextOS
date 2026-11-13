import Foundation
import Testing
@testable import ContextOSCore

@Suite("Budgeted implementation dependencies")
struct CrossFileContextTests {
    private let service = ContextService(useGitSignals: false)
    private func project(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-dependencies-\(UUID())")
        for (path, body) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target, atomically: true, encoding: .utf8)
        }
        return root
    }
    private var tsNoise: String { (0..<70).map { "\nfunction unused\($0)() { return 'UNRELATED_NOISE'; }\n" }.joined() }
    private var pyNoise: String { (0..<70).map { "\ndef unused\($0)():\n    return 'UNRELATED_NOISE'\n" }.joined() }
    private var swiftNoise: String { (0..<70).map { "\nfunc unused\($0)() { print(\"UNRELATED_NOISE\") }\n" }.joined() }

    @Test("Small budgets preserve the target, aliased helper and transitive helper before outlines")
    func typescriptTransitive() throws {
        let root = try project([
            "src/login.ts": "import { verifySignature as check } from './crypto';\nexport const login = (token: string) => check(token);\n" + tsNoise,
            "src/crypto.ts": "import { normalize } from './normalize';\nexport const verifySignature = (token: string) => normalize(token) + 'REQUIRED_VERIFY';\n" + tsNoise,
            "src/normalize.ts": "export const normalize = (token: string) => token.trim() + 'REQUIRED_NORMALIZE';\n" + tsNoise,
            "other/crypto.ts": "export const verifySignature = () => 'WRONG_DIRECTORY';\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("=> check(token)"))
        #expect(result.bundle.contains("REQUIRED_VERIFY"))
        #expect(result.bundle.contains("REQUIRED_NORMALIZE"))
        #expect(!result.bundle.contains("WRONG_DIRECTORY"))
        #expect(!result.bundle.contains("UNRELATED_NOISE"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
        let plan = try service.relevantContext(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(plan.included.map(\.path) == result.selection.included.map(\.path))
        #expect(plan.estimatedTokens == result.deliveredTokens)
    }

    @Test("Namespace imports and .js specifiers resolve the actual TypeScript source")
    func namespaceImport() throws {
        let root = try project([
            "src/login.ts": "import * as crypto from './crypto.js';\nexport const login = (token: string) => crypto.verify(token);\n" + tsNoise,
            "src/crypto.ts": "export const verify = (token: string) => 'REQUIRED_NAMESPACE_CHECK';\n" + tsNoise,
            "unrelated/crypto.ts": "export const verify = () => 'WRONG_NAMESPACE';\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 200)
        #expect(result.bundle.contains("REQUIRED_NAMESPACE_CHECK"))
        #expect(!result.bundle.contains("WRONG_NAMESPACE"))
        #expect(result.deliveredTokens <= 200)
    }

    @Test("Python relative imports, aliases and imported constants keep their complete implementations")
    func pythonImports() throws {
        let root = try project([
            "pkg/login.py": "from .crypto import verify as check\nfrom .unused import fake\ndef login(token):\n    return check(token)\n" + pyNoise,
            "pkg/crypto.py": "from .policy import KEYS\ndef verify(token):\n    return token in KEYS and 'REQUIRED_PYTHON_CHECK'\n" + pyNoise,
            "pkg/policy.py": "KEYS = {\n    'active': 'REQUIRED_KEY'\n}\n" + pyNoise,
            "pkg/unused.py": "def fake():\n    return 'WRONG_UNUSED_IMPORT'\n",
            "other/crypto.py": "def verify(token):\n    return 'WRONG_DIRECTORY'\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_PYTHON_CHECK"))
        #expect(result.bundle.contains("REQUIRED_KEY"))
        #expect(!result.bundle.contains("WRONG_UNUSED_IMPORT"))
        #expect(!result.bundle.contains("WRONG_DIRECTORY"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Swift free functions and explicit type methods resolve across files")
    func swiftHelpers() throws {
        let root = try project([
            "Login.swift": "func login(_ token: String) -> Bool { verifySignature(token) && Rules.allowed(token) }\n" + swiftNoise,
            "Signature.swift": "func verifySignature(_ token: String) -> Bool { token == \"REQUIRED_SWIFT_CHECK\" }\n" + swiftNoise,
            "Rules.swift": "enum Rules {\n    static func allowed(_ token: String) -> Bool { token == \"REQUIRED_SWIFT_RULE\" }\n}\n" + swiftNoise,
            "Tests/SignatureTests.swift": "func verifySignature(_ token: String) -> Bool { false /* WRONG_TEST_HELPER */ }\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_SWIFT_CHECK"))
        #expect(result.bundle.contains("REQUIRED_SWIFT_RULE"))
        #expect(!result.bundle.contains("WRONG_TEST_HELPER"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Swift instance bindings preserve the initializer and the correct owner's method")
    func swiftInstanceHelper() throws {
        let root = try project([
            "Login.swift": "func login(_ token: String) -> Bool {\n    let checker = Checker()\n    return checker.allows(token)\n}\n" + swiftNoise,
            "Checker.swift": "struct Checker {\n    let key: String\n    init() { key = \"REQUIRED_INIT\" }\n    func allows(_ token: String) -> Bool { token == key + \"REQUIRED_INSTANCE_HELPER\" }\n}\nstruct Unrelated {\n    func allows(_ token: String) -> Bool { token == \"WRONG_OWNER\" }\n}\n" + swiftNoise
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_INIT"))
        #expect(result.bundle.contains("REQUIRED_INSTANCE_HELPER"))
        #expect(!result.bundle.contains("WRONG_OWNER"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Re-exported aliases and import cycles terminate and merge one section per file")
    func reexportCycle() throws {
        let root = try project([
            "login.ts": "import { verify } from './barrel';\nexport const login = (token: string) => verify(token);\nexport const normalize = (token: string) => token.trim() + 'REQUIRED_CYCLE';\n" + tsNoise,
            "barrel.ts": "export { check as verify } from './crypto';\n",
            "crypto.ts": "import { normalize } from './login';\nexport const check = (token: string) => normalize(token) + 'REQUIRED_CYCLE_CHECK';\n" + tsNoise
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_CYCLE"))
        #expect(result.bundle.contains("REQUIRED_CYCLE_CHECK"))
        #expect(result.bundle.components(separatedBy: "// ===== FILE: login.ts").count == 2)
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Changed helpers are sent even if the caller was already delivered")
    func memoryAndChangedHelper() throws {
        let root = try project([
            "login.ts": "import { verify } from './crypto';\nexport const login = (token: string) => {\n  return verify(token);\n};\n" + tsNoise,
            "crypto.ts": "export const verify = (token: string) => 'REQUIRED_FIRST_VERSION';\n" + tsNoise
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = SessionMemory()
        _ = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250, memory: memory)
        try ("export const verify = (token: string) => 'REQUIRED_CHANGED_VERSION_LONGER';\n" + tsNoise)
            .write(to: root.appendingPathComponent("crypto.ts"), atomically: true, encoding: .utf8)
        let changed = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250, memory: memory)
        #expect(changed.bundle.contains("REQUIRED_CHANGED_VERSION_LONGER"))
        #expect(changed.skippedUnchanged > 0)
        #expect(changed.deliveredTokens <= 250)
    }

    @Test("Required bodies that exceed the budget are named, never silently replaced by unrelated code")
    func insufficientBudget() throws {
        let root = try project([
            "login.ts": "import { verify } from './crypto';\nexport const login = (token: string) => verify(token);\n",
            "crypto.ts": "export const verify = (token: string) => '" + String(repeating: "REQUIRED_LARGE_BODY", count: 200) + "';\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 100)
        #expect(small.bundle.contains("예산 부족"))
        #expect(small.bundle.contains("crypto.ts"))
        #expect(!small.selection.omissions.isEmpty)
        #expect(small.deliveredFullTokens == 0)
        #expect(small.deliveredTokens <= 100)
        let larger = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 4000)
        #expect(larger.bundle.contains("REQUIRED_LARGE_BODY"))
        #expect(larger.selection.omissions.isEmpty)
    }

    @Test("Missing, ignored or outside-root imports never fall back to an unrelated same-stem file")
    func projectBoundary() throws {
        let root = try project([
            ".gitignore": "private/\n",
            "login.ts": "import { verify } from './private/crypto';\nexport const login = (token: string) => verify(token);\n",
            "private/crypto.ts": "export const verify = () => 'DUMMY_PRIVATE_VALUE';\n",
            "other/crypto.ts": "export const verify = () => 'WRONG_FALLBACK';\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(!result.bundle.contains("DUMMY_PRIVATE_VALUE"))
        #expect(!result.bundle.contains("WRONG_FALLBACK"))
        #expect(!result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Default plus named imports retain both the implementation and a separately used constant")
    func mixedImports() throws {
        let root = try project([
            "login.ts": "import check, { KEYS as keys } from './crypto';\nexport const login = (token: string) => check(token) && keys.includes(token);\n" + tsNoise,
            "crypto.ts": "export default function validate(token: string) { return token === 'REQUIRED_DEFAULT'; }\nexport const KEYS = ['REQUIRED_NAMED_CONSTANT'];\n" + tsNoise
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_DEFAULT"))
        #expect(result.bundle.contains("REQUIRED_NAMED_CONSTANT"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("An oversized same-file dependency keeps the actual requested body and reports the omitted helper")
    func oversizedLocalHelper() throws {
        let root = try project(["login.py": "def login(token):\n    return verify(token) + 'REQUIRED_CALLER'\ndef verify(token):\n    return '" + String(repeating: "LARGE_HELPER", count: 200) + "'\n" + pyNoise])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 120)
        #expect(result.bundle.contains("REQUIRED_CALLER"))
        #expect(!result.selection.omissions.isEmpty)
        #expect(result.selection.omissions.joined().contains("verify"))
        #expect(result.bundle.contains("예산 부족"))
        #expect(!result.bundle.contains("LARGE_HELPER"))
        #expect(result.deliveredTokens <= 120)
    }

    @Test("Swift helpers stay in their source module and SDK extension mentions do not pull unrelated bodies")
    func swiftModuleAndSDKExtension() throws {
        let root = try project([
            "Package.swift": "// Swift package module layout\n",
            "Sources/App/Login.swift": "func login(_ token: String) -> Bool { verifySignature(token) && String(token).isEmpty }\n" + swiftNoise,
            "Sources/App/Verify.swift": "func verifySignature(_ token: String) -> Bool { token == \"REQUIRED_MODULE\" }\n" + swiftNoise,
            "Sources/Other/Verify.swift": "func verifySignature(_ token: String) -> Bool { token == \"WRONG_MODULE\" }\n",
            "Sources/App/StringExtensions.swift": "extension String {\nfunc unrelatedExtension() { print(\"WRONG_SDK_EXTENSION\") }\n}\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_MODULE"))
        #expect(!result.bundle.contains("WRONG_MODULE"))
        #expect(!result.bundle.contains("WRONG_SDK_EXTENSION"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }

    @Test("Multiple explicitly requested files share one required budget group")
    func multipleRequestedFiles() throws {
        let root = try project([
            "login.py": "def login():\n    return 'REQUIRED_FIRST'\n",
            "policy.py": "def policy():\n    return '" + String(repeating: "REQUIRED_SECOND", count: 120) + "'\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login.py policy.py", projectRoot: root, tokenBudget: 100)
        #expect(!result.selection.omissions.isEmpty)
        #expect(result.bundle.contains("예산 부족"))
        #expect(result.selection.omissions.joined().contains("policy.py"))
        #expect(result.deliveredTokens <= 100)
    }

    @Test("Short files do not turn an unused import or unrelated function into a required dependency")
    func shortCaller() throws {
        let root = try project([
            "login.ts": "import { verify } from './crypto';\nimport { unused } from './junk';\nexport const login = (token: string) => verify(token);\nfunction unrelated() { return unused(); }\n",
            "crypto.ts": "export const verify = (token: string) => 'REQUIRED_SHORT_HELPER';\n",
            "junk.ts": "export const unused = () => 'WRONG_UNUSED_HELPER';\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("REQUIRED_SHORT_HELPER"))
        #expect(!result.bundle.contains("WRONG_UNUSED_HELPER"))
        #expect(result.selection.omissions.isEmpty)
        #expect(result.deliveredTokens <= 250)
    }
}
