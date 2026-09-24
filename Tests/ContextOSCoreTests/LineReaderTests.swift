import Foundation
import Testing
@testable import ContextOSCore

@Suite("LineReader")
struct LineReaderTests {

    private func tempFile(_ body: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-lines-\(UUID().uuidString).jsonl")
        try body.write(to: url)
        return url
    }

    private func lines(of url: URL, from offset: Int = 0,
                       needles: [String] = []) -> (lines: [String], consumed: Int?) {
        var out: [String] = []
        let consumed = LineReader.forEachLine(of: url, from: offset, containingAny: needles) { bytes in
            out.append(String(decoding: bytes, as: UTF8.self))
        }
        return (out, consumed)
    }

    @Test("only lines holding a needle are handed out, across chunk boundaries")
    func filtersAcrossChunks() throws {
        // Lines far longer than a chunk, so matches and newlines land on every
        // side of a chunk boundary.
        let filler = String(repeating: "x", count: LineReader.chunkSize + 123)
        var body = ""
        var expected: [String] = []
        for index in 0..<6 {
            let line = index % 2 == 0
                ? "{\"n\":\(index),\"pad\":\"\(filler)\",\"usage\":{}}"
                : "{\"n\":\(index),\"pad\":\"\(filler)\"}"
            if index % 2 == 0 { expected.append(line) }
            body += line + "\n"
        }
        body += "{\"usage\":\"half-written"     // no newline yet
        let url = try tempFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = lines(of: url, needles: ["\"usage\""])
        #expect(result.lines == expected)
        // The partial last line is not consumed, so the next pass re-reads it.
        #expect(result.consumed == body.utf8.count - "{\"usage\":\"half-written".utf8.count)
    }

    @Test("any of several needles matches, and a line with two is handed out once")
    func severalNeedles() throws {
        let body = """
        {"type":"session_meta","payload":{"cwd":"/a"}}
        {"type":"other"}
        {"cwd":"/b","token_count":1}
        {"type":"event_msg","payload":{"type":"token_count"}}

        """
        let url = try tempFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = lines(of: url, needles: ["\"cwd\"", "token_count"])
        #expect(result.lines == [
            #"{"type":"session_meta","payload":{"cwd":"/a"}}"#,
            #"{"cwd":"/b","token_count":1}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        ])
        #expect(result.consumed == body.utf8.count)
    }

    @Test("no needles hands out every non-empty line; an offset resumes mid-file")
    func everyLineFromOffset() throws {
        let body = "one\n\ntwo\nthree\n"
        let url = try tempFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(lines(of: url).lines == ["one", "two", "three"])
        let resumed = lines(of: url, from: 5)          // after "one\n\n"
        #expect(resumed.lines == ["two", "three"])
        #expect(resumed.consumed == body.utf8.count - 5)
    }

    @Test("an escaped quote inside a string does not count as the key")
    func escapedNeedleDoesNotMatch() throws {
        // A tool result quoting source code carries `\"usage\"`, which is not a
        // `"usage"` key — the byte search must not treat it as one.
        let body = #"{"content":"obj[\"usage\"] = 1"}"# + "\n" + #"{"usage":{}}"# + "\n"
        let url = try tempFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(lines(of: url, needles: ["\"usage\""]).lines == [#"{"usage":{}}"#])
    }

    @Test("byte-level contains")
    func contains() {
        let bytes = Array(#"{"type":"tool_use","id":"toolu_1"}"#.utf8)
        bytes.withUnsafeBytes { buffer in
            #expect(LineReader.contains(buffer, "tool_use"))
            #expect(!LineReader.contains(buffer, "call_id"))
            #expect(!LineReader.contains(buffer, String(repeating: "x", count: 200)))
        }
    }
}
