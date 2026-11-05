import Foundation
import Testing
@testable import ContextOSCore

@Suite("Efficient context invariants")
struct EfficiencyRegressionTests {
    @Test("Identifier optimization preserves acronyms, digits, separators and Unicode")
    func identifierBoundaries() {
        let cases: [(String, [String])] = [
            ("MCPServer HTTPClient projectID", ["mcp", "server", "http", "client", "project", "id"]),
            ("auth/jwt_helper.py", ["auth", "jwt", "helper", "py"]),
            ("a1B2 HTTP2Client XML_HTTP42", ["a1b2", "http2client", "xml", "http42"]),
            ("aBC D_/ABCd", ["a", "bc", "d", "ab", "cd"]),
            ("login\r\n\tService", ["login", "service"]),
            ("로그인Service 사용자ID", ["로그인service", "사용자id"]),
            ("caféClient ÜberHTTP", ["café", "client", "über", "http"]),
            ("👩🏽‍💻LoginService a\u{301}Token", ["login", "service", "a\u{301}", "token"]),
            ("", [])
        ]
        for (input, expected) in cases { #expect(TextTokens.subwords(of: input) == expected) }
    }

    @Test("Long-lived MCP memory evicts old entries and safely resends evicted bodies")
    func boundedDeduplication() {
        let memory = SessionMemory(ttl: 60, maximumEntries: 3)
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<100 {
            memory.markServed(project: "/p", path: "\(i).swift", bodyHash: "hash", now: start.addingTimeInterval(Double(i) / 10))
            #expect(memory.count <= 3)
        }
        #expect(!memory.isUnchanged(project: "/p", path: "0.swift", bodyHash: "hash", now: start.addingTimeInterval(10)))
        #expect(memory.isUnchanged(project: "/p", path: "99.swift", bodyHash: "hash", now: start.addingTimeInterval(10)))
        memory.markServed(project: "/other", path: "new.swift", bodyHash: "new", now: start.addingTimeInterval(100))
        #expect(memory.count == 1)
        #expect(!memory.isUnchanged(project: "/other", path: "new.swift", bodyHash: "new", now: start.addingTimeInterval(161)))
        #expect(memory.count == 0)
    }
}
