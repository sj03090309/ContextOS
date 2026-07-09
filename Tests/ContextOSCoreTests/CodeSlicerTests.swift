import Foundation
import Testing
@testable import ContextOSCore

@Suite("HeuristicParser ranges")
struct ParserRangeTests {
    let parser = HeuristicParser()

    @Test("computes Swift function block end via braces")
    func swiftRange() {
        let src = """
        struct S {
            func a() {
                print(1)
                print(2)
            }
            func b() { return }
        }
        """
        let syms = parser.parse(source: src, language: .swift).symbols
        let a = syms.first { $0.name == "a" }
        #expect(a?.line == 2)
        #expect(a?.endLine == 5)   // closing brace of a()
    }

    @Test("computes Python def block end via indentation")
    func pythonRange() {
        let src = """
        def login(u):
            x = 1
            return x

        def other():
            pass
        """
        let syms = parser.parse(source: src, language: .python).symbols
        let login = syms.first { $0.name == "login" }
        #expect(login?.line == 1)
        #expect(login?.endLine == 3)   // last line of login body
    }
}

@Suite("CodeSlicer")
struct CodeSlicerTests {
    let slicer = CodeSlicer(minLinesToSlice: 5, maxKeepFraction: 0.9)

    private var sample: String {
        """
        import os

        def login(user):
            token = make_token(user)
            return token

        def signup(user):
            save(user)
            return ok()

        def reset_password(user):
            send_email(user)
            return ok()
        """
    }

    @Test("keeps the matched function body, elides the rest, keeps signatures")
    func slicesToRelevant() {
        let result = slicer.slice(source: sample, language: .python, terms: ["login"])
        #expect(result.sliced)
        // login body kept
        #expect(result.content.contains("token = make_token(user)"))
        // other bodies elided
        #expect(!result.content.contains("send_email(user)"))
        #expect(!result.content.contains("save(user)"))
        // but their signatures remain as a table of contents
        #expect(result.content.contains("def signup(user):"))
        #expect(result.content.contains("def reset_password(user):"))
        // elision marker present
        #expect(result.content.contains("생략"))
        #expect(result.keptLines < result.totalLines)
    }

    @Test("no relevant symbol → whole file returned")
    func noMatchKeepsWholeFile() {
        let result = slicer.slice(source: sample, language: .python, terms: ["billing"])
        #expect(!result.sliced)
        #expect(result.content == sample)
    }
}
