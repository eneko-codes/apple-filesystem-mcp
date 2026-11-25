import Foundation

/// Telling text from bytes, and decoding a file that is held whole in memory.
enum TextDecoding {

    /// A NUL byte in the first few kilobytes is how every text tool has told binary from
    /// text for fifty years, and it is right often enough to be the rule here too.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8_000).contains(0)
    }

    static func startsWithUTF16Mark(_ data: Data) -> Bool {
        let mark = Array(data.prefix(2))
        return mark == [0xFF, 0xFE] || mark == [0xFE, 0xFF]
    }

    /// UTF-16 by its byte-order mark, then UTF-8, then whatever `NSString` guesses, then
    /// Latin-1 as the encoding that can decode any byte sequence at all.
    ///
    /// The mark is looked for before the NUL test: UTF-16 text in a Latin script has a NUL
    /// in every other byte, and would otherwise always be taken for a binary file.
    static func decode(_ data: Data) -> (text: String, encodingName: String)? {
        if startsWithUTF16Mark(data) {
            return String(data: data, encoding: .utf16).map { ($0, "UTF-16") }
        }
        guard !looksBinary(data) else { return nil }

        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }

        var converted: NSString?
        let guessed = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted,
            usedLossyConversion: nil)
        if guessed != 0, let converted {
            return (converted as String, String.localizedName(of: String.Encoding(rawValue: guessed)))
        }

        if let text = String(data: data, encoding: .isoLatin1) { return (text, "ISO Latin 1") }
        if let text = String(data: data, encoding: .macOSRoman) { return (text, "Mac OS Roman") }
        return nil
    }
}

/// Decodes UTF-8 that arrives in chunks cut at arbitrary bytes.
///
/// A chunk can end in the middle of a character's bytes. Those last bytes are held back and
/// decoded with the next chunk, so the pieces returned join into exactly the text the whole
/// file would decode to.
struct UTF8ChunkDecoder {
    private var heldBack = Data()

    /// The text of `chunk`, or `nil` when the bytes are not UTF-8.
    mutating func decode(_ chunk: Data) -> String? {
        var bytes = heldBack + chunk
        let unfinished = Self.unfinishedSuffixLength(bytes)
        heldBack = Data(bytes.suffix(unfinished))
        bytes.removeLast(unfinished)
        return String(validating: bytes, as: UTF8.self)
    }

    /// False when the input ended in the middle of a character: not UTF-8 after all.
    var endedOnACharacter: Bool { heldBack.isEmpty }

    /// How many bytes at the end begin a character whose remaining bytes have not arrived.
    /// A UTF-8 character is at most four bytes, so only the last three can be unfinished.
    static func unfinishedSuffixLength(_ bytes: Data) -> Int {
        for back in 1...3 where back <= bytes.count {
            let byte = bytes[bytes.endIndex - back]
            // 10xxxxxx continues a character: its first byte is further back.
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? back : 0
        }
        return 0
    }
}

/// Cuts a window of characters out of a text that arrives in pieces, and counts the whole,
/// without ever holding more than one piece and the window.
///
/// Characters are Swift's, the same ones `ToolStandard.window` counts. A character can be
/// split across two pieces (an emoji sequence, a letter and its accent, "\r\n"), so the last
/// character of each piece waits for the next piece before it is counted: text that follows
/// can extend the last character but never one before it.
struct CharacterWindow {
    let characterOffset: Int
    let maxCharacters: Int

    private(set) var text = ""
    /// Characters counted so far; the whole text's count once `finish` has run.
    private(set) var total = 0
    private var taken = 0
    private var unfinished = ""

    init(characterOffset: Int, maxCharacters: Int) {
        self.characterOffset = characterOffset
        self.maxCharacters = maxCharacters
    }

    mutating func append(_ piece: String) {
        let joined = unfinished + piece
        guard !joined.isEmpty else { return }
        let last = joined.index(before: joined.endIndex)
        count(joined[..<last])
        unfinished = String(joined[last...])
    }

    mutating func finish() {
        count(Substring(unfinished))
        unfinished = ""
    }

    private mutating func count(_ settled: Substring) {
        let count = settled.count
        defer { total += count }
        let room = maxCharacters - taken
        guard room > 0, total + count > characterOffset else { return }
        let start = settled.index(settled.startIndex, offsetBy: Swift.max(characterOffset - total, 0))
        let end = settled.index(start, offsetBy: room, limitedBy: settled.endIndex) ?? settled.endIndex
        text += settled[start..<end]
        taken += settled.distance(from: start, to: end)
    }
}

/// Reads a window of a text file of any size.
///
/// The window is in characters, and a character's position is only known by decoding
/// everything before it, so every call reads the file from its first byte. What is bounded
/// is memory, not reach: the file goes by one chunk at a time, and only the window is kept.
/// That works for UTF-8, which can be decoded piece by piece. Any other encoding has to be
/// guessed from, and decoded as, the whole file, so such a file is read into memory and
/// only up to `wholeFileBytes`.
enum TextReader {

    /// Hands the file's bytes to its argument one chunk at a time, in order, until the file
    /// ends or the argument returns `false`. It can be run more than once.
    typealias Chunks = ((Data) throws -> Bool) throws -> Void

    enum Outcome: Equatable {
        case window(TextWindow)
        case notText
        /// Not UTF-8, and larger than can be decoded whole.
        case tooLargeToDecode
        /// The time ran out before the window was reached. `charactersCounted` is how far
        /// the count got, when the file was being counted at all.
        case timeLimit(bytesRead: Int, charactersCounted: Int?)
    }

    static func read(
        characterOffset: Int, maxCharacters: Int, wholeFileBytes: Int,
        expired: @escaping FolderScan.Expired, chunks: Chunks
    ) throws -> Outcome {
        var window = CharacterWindow(characterOffset: characterOffset, maxCharacters: maxCharacters)
        var decoder = UTF8ChunkDecoder()
        var bytesRead = 0
        var atTheStart = true
        var isUTF8 = true
        var ranOutOfTime = false
        var verdict: Outcome?

        try chunks { chunk in
            if expired() {
                ranOutOfTime = true
                return false
            }
            if bytesRead == 0, TextDecoding.startsWithUTF16Mark(chunk) {
                isUTF8 = false
                return false
            }
            if bytesRead == 0, TextDecoding.looksBinary(chunk) {
                verdict = .notText
                return false
            }
            bytesRead += chunk.count
            guard var text = decoder.decode(chunk) else {
                isUTF8 = false
                return false
            }
            // A byte-order mark is not part of the text. It is looked for until the first
            // character has arrived, which a very small chunk may not yet hold.
            if atTheStart, !text.isEmpty {
                if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
                atTheStart = false
            }
            window.append(text)
            return true
        }
        if let verdict { return verdict }
        if ranOutOfTime {
            // Whatever of the window was cut before the time ran out is still the text at
            // that place. Only the length of the file stays unknown.
            guard !window.text.isEmpty else {
                return .timeLimit(bytesRead: bytesRead, charactersCounted: window.total)
            }
            return .window(
                TextWindow(
                    text: window.text, totalCharacters: window.total, encodingName: "UTF-8",
                    totalBytes: bytesRead, isWholeFile: false))
        }
        if isUTF8, decoder.endedOnACharacter {
            window.finish()
            return .window(
                TextWindow(
                    text: window.text, totalCharacters: window.total, encodingName: "UTF-8",
                    totalBytes: bytesRead))
        }

        var whole = Data()
        try chunks { chunk in
            if expired() {
                verdict = .timeLimit(bytesRead: whole.count, charactersCounted: nil)
                return false
            }
            guard whole.count + chunk.count <= wholeFileBytes else {
                verdict = .tooLargeToDecode
                return false
            }
            whole.append(chunk)
            return true
        }
        if let verdict { return verdict }
        guard let decoded = TextDecoding.decode(whole) else { return .notText }
        let part = ToolStandard.window(
            of: decoded.text, characterOffset: characterOffset, maxCharacters: maxCharacters)
        return .window(
            TextWindow(
                text: part.text, totalCharacters: decoded.text.count,
                encodingName: decoded.encodingName, totalBytes: whole.count))
    }
}
