import Foundation
import Testing
@testable import ContextOSCore

@Suite("PromptLinter")
struct PromptLinterTests {
    let linter = PromptLinter()

    @Test("flags vague verb-only prompts as having no target")
    func vagueNoTarget() {
        let findings = linter.lint("고쳐줘")
        #expect(findings.contains { $0.rule == "no-target" })
    }

    @Test("flags over-broad scope")
    func broadScope() {
        let findings = linter.lint("analyze the entire project")
        #expect(findings.contains { $0.rule == "too-broad" })
    }

    @Test("flags too-short prompts")
    func tooShort() {
        let findings = linter.lint("go")
        #expect(findings.contains { $0.rule == "too-short" })
    }

    @Test("a specific prompt passes clean")
    func specificPasses() {
        let findings = linter.lint("fix the login token expiry in auth")
        #expect(findings.isEmpty)
    }

    @Test("English vague prompt is flagged, targeted one is not")
    func englishVague() {
        #expect(linter.lint("please fix it").contains { $0.rule == "no-target" })
        #expect(!linter.lint("refactor the PaymentService retry logic").contains { $0.rule == "no-target" })
    }
}
