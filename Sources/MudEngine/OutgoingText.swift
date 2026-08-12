// Tidying what you type on its way to the world.
//
// MUSH-family servers are byte-oriented and old. Shangrila is Rhost; PennMUSH,
// TinyMUX and the rest are the same shape. They take one line per command and
// they do not speak UTF-8 — a multi-byte character arrives as a run of bytes
// they mangle or drop, which is how a pasted em dash comes back on screen as a
// replacement glyph.
//
// None of that is a problem when you type into the client, because the command
// box has macOS's smart substitutions switched off. It is entirely a problem
// when you *paste*: text composed in Notes, Pages, a browser or a chat window
// arrives full of curly quotes, em dashes and ellipses, and a multi-line pose
// arrives with real line breaks in it that would otherwise be sent as separate
// commands — the second and third lines landing on the game as bare input.
//
// So this is a paste-shaped problem with a typing-shaped fix. Foundation only,
// no AppKit, so it can be tested without a window server.

import Foundation

public enum OutgoingText {

    /// Rewrite typed text into something a MUSH will take intact.
    ///
    /// Three jobs, in one pass:
    ///
    ///  - line breaks become `%r` and tabs become `%t`, the codes the server
    ///    substitutes back into real whitespace, so the whole block goes as a
    ///    single command instead of one command per line;
    ///  - typographic punctuation becomes its ASCII ancestor — curly quotes
    ///    straighten, an em dash becomes `--`, an ellipsis becomes three stops;
    ///  - anything still outside ASCII is folded down if it has an obvious plain
    ///    form (`café` → `cafe`) and dropped if it doesn't.
    ///
    /// `%` itself is deliberately left alone. Escaping it to `%%` would be the
    /// cautious thing to do — a stray "50% chance" really does get eaten by the
    /// server's substitution pass — but people type `%r`, `%t` and `%b` into
    /// MUSH clients on purpose all day long, and breaking that to save the
    /// occasional percent sign would be a much worse trade. The line breaks this
    /// function inserts are the same syntax the user would have typed by hand.
    ///
    /// Dropping unmappable characters is silent by design, but for ordinary
    /// lines it isn't invisible: the caller runs this *before* echoing, so with
    /// echo on you see the text as it went out rather than as you typed it.
    /// What survives the fold is what the server could ever have rendered.
    ///
    /// The exception is why the caller must not hand credentials to this
    /// function. A password is either not echoed at all (telnet ECHO off) or
    /// echoed as asterisks (`SessionFormat.redactLogin`), so a character quietly
    /// folded out of one produces a login that fails with nothing on screen to
    /// explain it. `SessionFormat.containsLogin` is there to keep them away.
    public static func tidy(_ text: String) -> String {
        // Shared with `SessionFormat.containsLogin`, and it matters that they
        // agree: that function decides whether text reaches this one, and a
        // block the two of them split into different lines is a block one of
        // them can be wrong about.
        let unified = SessionFormat.unifyingLineEndings(text)

        // A pasted block usually ends in a newline, and a trailing `%r` puts a
        // blank line on the end of every pose. Only from the end: a leading
        // break is rare enough to be deliberate when it happens.
        var body = Substring(unified)
        while body.last == "\n" { body = body.dropLast() }

        var out = ""
        out.reserveCapacity(body.count)

        for ch in body {
            if let replacement = substitutions[ch] {
                out += replacement
                continue
            }
            if let ascii = ch.asciiValue {
                // Control characters, minus the two the table above already
                // turned into codes. An ESC pasted in from a terminal would
                // otherwise go out as the start of an ANSI sequence, and DEL and
                // NUL are no better received. Nothing legible is lost.
                if ascii >= 0x20 && ascii != 0x7F { out.append(ch) }
                continue
            }
            // Accented Latin has a plain form worth keeping. Everything else —
            // emoji, CJK, symbols — has none, and a server that cannot render it
            // is better handed nothing than handed a broken byte sequence.
            out += String(ch)
                .folding(options: [.diacriticInsensitive], locale: nil)
                .filter { $0.isASCII }
        }
        return out
    }

    /// What each character becomes. Anything not in here is either passed
    /// through (plain ASCII), folded (accented Latin), or dropped.
    ///
    /// The two whitespace codes live in the same table as the punctuation so
    /// that the whole rewrite is one lookup per character and there is exactly
    /// one place to look when something comes out wrong.
    private static let substitutions: [Character: String] = [
        "\n": "%r",         // the line break that would otherwise split the command
        "\t": "%t",

        // Quotes. macOS makes the curly ones, and so does every word processor
        // and web page anyone might paste from.
        "\u{2018}": "'",    // ' left single
        "\u{2019}": "'",    // ' right single — also the apostrophe in "he's"
        "\u{201A}": "'",    // ‚ single low
        "\u{201B}": "'",    // ‛ single high reversed
        "\u{201C}": "\"",   // " left double
        "\u{201D}": "\"",   // " right double
        "\u{201E}": "\"",   // „ double low
        "\u{201F}": "\"",   // ‟ double high reversed
        "\u{00AB}": "\"",   // « guillemet
        "\u{00BB}": "\"",   // »
        "\u{2032}": "'",    // ′ prime
        "\u{2033}": "\"",   // ″ double prime

        // Dashes. The em dash gets two hyphens because that is what it was
        // before autocorrect got to it, and one hyphen reads as a hyphen.
        "\u{2010}": "-",    // ‐ hyphen
        "\u{2011}": "-",    // ‑ non-breaking hyphen
        "\u{2012}": "-",    // ‒ figure dash
        "\u{2013}": "-",    // – en dash
        "\u{2014}": "--",   // — em dash
        "\u{2015}": "--",   // ― horizontal bar

        // Spaces that aren't the space character. A non-breaking space is the
        // one that actually turns up, courtesy of copying out of a web page.
        "\u{00A0}": " ",    // no-break space
        "\u{2002}": " ",    // en space
        "\u{2003}": " ",    // em space
        "\u{2007}": " ",    // figure space
        "\u{2009}": " ",    // thin space
        "\u{200A}": " ",    // hair space
        "\u{202F}": " ",    // narrow no-break space
        "\u{205F}": " ",    // medium mathematical space
        "\u{3000}": " ",    // ideographic space
        // Zero-width characters have no ASCII form and no width to lose. They
        // ride along invisibly in text copied off the web and would otherwise be
        // dropped by the fold below anyway; naming them here says so on purpose.
        "\u{200B}": "",     // zero-width space
        "\u{200C}": "",     // zero-width non-joiner
        "\u{200D}": "",     // zero-width joiner
        "\u{FEFF}": "",     // byte-order mark

        // The rest of what a word processor puts in.
        "\u{2026}": "...",  // … ellipsis
        "\u{2022}": "*",    // • bullet
        "\u{00B7}": "*",    // · middle dot
        "\u{2122}": "(tm)", // ™
        "\u{00A9}": "(c)",  // ©
        "\u{00AE}": "(r)",  // ®
        "\u{00BD}": "1/2",  // ½
        "\u{00BC}": "1/4",  // ¼
        "\u{00BE}": "3/4",  // ¾
    ]
}
