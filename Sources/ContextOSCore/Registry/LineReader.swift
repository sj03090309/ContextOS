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

    /// Feed every **complete** line from `offset` that contains at least one of
    /// `needles` to `handler`, as raw bytes, and report how many bytes of
    /// complete lines were consumed. With no needles, every non-empty line is fed.
    ///
    /// The needles are matched on the raw bytes, before anything is decoded. A
    /// transcript is mostly tool output — file contents, command logs — and the
    /// parsers only want the few lines that carry a usage figure. Decoding every
    /// line into a `String` first and then searching it with Foundation's
    /// character-level `contains` is what used to cost a full core for seconds at
    /// a time; `memmem` over the bytes skips a non-matching line without looking
    /// at it twice.
    ///
    /// A trailing partial line — an agent mid-write — is left unread so the next
    /// pass picks it up once it's finished, which is what makes incremental
    /// re-reads safe.
    ///
    /// - Parameter handler: called with the line's bytes, excluding the newline.
    ///   The buffer is only valid for the duration of the call.
    /// - Returns: bytes consumed past `offset`, or nil if the file couldn't be read.
    static func forEachLine(of file: URL, from offset: Int, containingAny needles: [String] = [],
                            _ handler: (UnsafeRawBufferPointer) -> Void) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        }
        let patterns = needles.map { Array($0.utf8) }.filter { !$0.isEmpty }

        // A plain byte array, not `Data`: a `Data` slice shares its parent's
        // storage, so rebuilding the tail as `Data(pending[start...])` keeps the
        // chunk it came from alive — and since each tail then holds the previous
        // one, a whole 63MB file stays resident. `removeFirst` on an array
        // compacts in place and lets the consumed bytes actually go.
        var pending: [UInt8] = []
        pending.reserveCapacity(chunkSize * 2)
        var consumed = 0

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
                let previous = pending.count
                pending.append(contentsOf: chunk)

                let complete = pending.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    // Everything before `previous` is a partial line with no
                    // newline in it, so the last newline, if any, is in the part
                    // just read. Searching only that keeps one enormous line —
                    // a tool result can be megabytes — from being rescanned on
                    // every chunk it spans.
                    guard let last = lastNewline(in: base, from: previous, to: buffer.count)
                    else { return 0 }
                    let end = last + 1
                    let lines = UnsafeRawBufferPointer(start: base, count: end)
                    if patterns.isEmpty {
                        emitAll(lines, handler)
                    } else {
                        emitMatching(lines, patterns, handler)
                    }
                    return end
                }
                consumed += complete
                // Keep only the trailing partial line for the next chunk.
                if complete > 0 { pending.removeFirst(complete) }
            }
        }
        return consumed
    }

    /// Every non-empty line in `lines`, which ends with a newline.
    private static func emitAll(_ lines: UnsafeRawBufferPointer,
                                _ handler: (UnsafeRawBufferPointer) -> Void) {
        guard let base = lines.baseAddress else { return }
        var start = 0
        while start < lines.count, let newline = memchr(base + start, 0x0A, lines.count - start) {
            let end = base.distance(to: UnsafeRawPointer(newline))
            if end > start { handler(UnsafeRawBufferPointer(start: base + start, count: end - start)) }
            start = end + 1
        }
    }

    /// Only the lines in `lines` (which ends with a newline) that contain one of
    /// `patterns`. It jumps from match to match rather than walking line by line,
    /// so the lines in between are never visited at all.
    private static func emitMatching(_ lines: UnsafeRawBufferPointer, _ patterns: [[UInt8]],
                                     _ handler: (UnsafeRawBufferPointer) -> Void) {
        guard let base = lines.baseAddress else { return }
        let count = lines.count
        // Next known match per pattern. A pattern is only searched again once the
        // cursor has moved past its last match, and one with no match left is
        // never searched again — so every byte is scanned at most once per pattern.
        var next = [Int](repeating: -1, count: patterns.count)
        var cursor = 0
        while cursor < count {
            var hit = Int.max
            for (index, pattern) in patterns.enumerated() {
                if next[index] != Int.max, next[index] < cursor {
                    next[index] = pattern.withUnsafeBytes { needle -> Int in
                        guard let found = memmem(base + cursor, count - cursor,
                                                 needle.baseAddress, needle.count)
                        else { return Int.max }
                        return base.distance(to: UnsafeRawPointer(found))
                    }
                }
                hit = min(hit, next[index])
            }
            guard hit != Int.max else { return }

            // The line around the match. A needle never contains a newline, so a
            // match can't straddle two lines.
            let start = lastNewline(in: base, from: cursor, to: hit).map { $0 + 1 } ?? cursor
            // `lines` ends with a newline, so there is always one after a match.
            guard let after = memchr(base + hit, 0x0A, count - hit) else { return }
            let end = base.distance(to: UnsafeRawPointer(after))
            handler(UnsafeRawBufferPointer(start: base + start, count: end - start))
            cursor = end + 1
        }
    }

    /// Offset of the last newline in `base[from..<to]`, scanning backwards.
    ///
    /// Darwin has no `memrchr`. Walking back is bounded by one line's length —
    /// the match's own line, or the partial line at the end of a chunk — which
    /// is work the caller is about to do on that line anyway.
    private static func lastNewline(in base: UnsafeRawPointer, from: Int, to: Int) -> Int? {
        var index = to - 1
        while index >= from {
            if base.load(fromByteOffset: index, as: UInt8.self) == 0x0A { return index }
            index -= 1
        }
        return nil
    }

    /// Whether `bytes` contains `needle` — a byte-level substring test for code
    /// that has a line in hand but has not decoded it.
    static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: String) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        var pattern = needle
        return pattern.withUTF8 { utf8 in
            guard utf8.count <= bytes.count, let start = utf8.baseAddress else { return false }
            return memmem(base, bytes.count, start, utf8.count) != nil
        }
    }
}
