import Foundation

/// Streams a file's complete lines without ever holding more than one chunk.
///
/// Session transcripts are the biggest thing ContextOS touches — a single Claude
/// Code log on a long-running project reaches 60MB+, and there can be a hundred
/// megabytes of them. Reading one with `readToEnd()` costs its size in `Data`,
/// then its size again converting to `String`; across a few files that peaked the
/// menu-bar app at ~295MB, which on an 8GB machine is the difference between
/// "background app" and "the reason your Mac is swapping".
///
/// Nothing here needs random access: every parser reads forward, line by line. So
/// this walks the file a chunk at a time and hands out lines as it goes, and the
/// high-water mark is the chunk size regardless of how large the file is.
struct LineReader {

    /// Bytes read per syscall. Big enough that the reads are cheap, small enough
    /// that the footprint stays flat.
    static let chunkSize = 256 * 1024

    /// Feed every **complete** line from `offset` to `handler`, and report how
    /// many bytes of complete lines were consumed.
    ///
    /// A trailing partial line — an agent mid-write — is left unread so the next
    /// pass picks it up once it's finished, which is what makes incremental
    /// re-reads safe.
    ///
    /// - Returns: bytes consumed past `offset`, or nil if the file couldn't be read.
    static func forEachLine(of file: URL, from offset: Int,
                            _ handler: (String) -> Void) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        }

        // A plain byte array, not `Data`: a `Data` slice shares its parent's
        // storage, so rebuilding the tail as `Data(pending[start...])` keeps the
        // chunk it came from alive — and since each tail then holds the previous
        // one, a whole 63MB file stays resident. `removeFirst` on an array
        // compacts in place and lets the consumed bytes actually go.
        var pending: [UInt8] = []
        pending.reserveCapacity(chunkSize * 2)
        var consumed = 0
        let newlineByte = UInt8(ascii: "\n")

        var done = false
        while !done {
            // The pool has to wrap the *read* as well as the parsing.
            // `FileHandle.read` hands back an autoreleased `Data`, so with the
            // read outside the pool every 256KB chunk stayed alive until the
            // whole function returned — which is precisely why the footprint
            // used to track the file's size, 1:1, all the way to 63MB.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    done = true
                    return
                }
                pending.append(contentsOf: chunk)

                var lineStart = 0
                var scan = 0
                while scan < pending.count {
                    guard pending[scan] == newlineByte else { scan += 1; continue }
                    if scan > lineStart,
                       let text = String(bytes: pending[lineStart..<scan], encoding: .utf8) {
                        handler(text)
                    }
                    scan += 1
                    consumed += scan - lineStart
                    lineStart = scan
                }
                // Keep only the trailing partial line for the next chunk.
                if lineStart > 0 { pending.removeFirst(lineStart) }
            }
        }
        return consumed
    }
}
