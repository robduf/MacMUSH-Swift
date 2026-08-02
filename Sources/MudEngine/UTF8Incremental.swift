// Incremental UTF-8 decoder: bytes arrive from the socket in arbitrary chunks,
// and a multi-byte character can be split across two reads. This buffers any
// incomplete trailing sequence and only emits complete characters.

import Foundation

// Public so the test executable can exercise it directly. It's a self-contained
// utility with no ties to the rest of the engine, so publishing it costs
// nothing; the alternative was `@testable import`, which only works in debug
// builds and would break `swift build -c release` outright.
public struct UTF8Incremental {
    private var pending: [UInt8] = []

    public init() {}

    /// Feed raw bytes; returns the decoded text for every complete UTF-8
    /// sequence so far. Incomplete trailing bytes are held for next time.
    public mutating func decode(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let split = UTF8Incremental.completePrefixLength(pending)
        if split == 0 { return "" }
        let complete = Array(pending[0..<split])
        pending.removeFirst(split)
        return String(decoding: complete, as: UTF8.self)
    }

    /// Number of leading bytes that form only complete UTF-8 sequences.
    static func completePrefixLength(_ b: [UInt8]) -> Int {
        if b.isEmpty { return 0 }
        var i = b.count - 1
        var continuations = 0
        // Walk back over continuation bytes (10xxxxxx).
        while i >= 0 && (b[i] & 0xC0) == 0x80 {
            continuations += 1
            i -= 1
        }
        if i < 0 { return 0 } // nothing but continuations — hold it all
        let lead = b[i]
        let needed: Int
        if lead & 0x80 == 0 { needed = 1 }
        else if lead & 0xE0 == 0xC0 { needed = 2 }
        else if lead & 0xF0 == 0xE0 { needed = 3 }
        else if lead & 0xF8 == 0xF0 { needed = 4 }
        else { needed = 1 } // invalid lead byte; let String(decoding:) substitute
        let sequenceLength = continuations + 1
        // If the final sequence is complete, everything is complete; otherwise
        // hold back from the incomplete lead byte.
        return sequenceLength >= needed ? b.count : i
    }
}
