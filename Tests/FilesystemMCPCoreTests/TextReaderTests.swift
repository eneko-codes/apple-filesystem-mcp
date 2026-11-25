import Foundation
import Testing

@testable import FilesystemMCPCore

/// Reading a window of a text that arrives in pieces: the pure code behind
/// `filesystem_read_text`, and the tool itself against invented files.
@Suite("Text reading")
struct TextReaderTests {

    /// Characters of every awkward kind: several bytes each, several scalars each, a
    /// line ending that is one character, flags that pair up, and a byte-order mark that
    /// is not at the start.
    private static let awkward =
        "añ👩‍👩‍👧 e\u{301}x\r\ny🇪🇸🇫🇷z\u{FEFF}日本語\n" + String(repeating: "línea ñ\r\n", count: 40)

    /// `data` cut into chunks of `size` bytes, as a store hands a file over.
    private static func chunks(of data: Data, size: Int) -> TextReader.Chunks {
        { body in
            var start = 0
            while start < data.count {
                let end = min(start + size, data.count)
                guard try body(data.subdata(in: start..<end)) else { return }
                start = end
            }
        }
    }

    private func window(
        of data: Data, chunk: Int, offset: Int, size: Int, wholeFileBytes: Int = ToolCatalog.wholeFileBytes,
        expired: @escaping () -> Bool = { false }
    ) throws -> TextReader.Outcome {
        try TextReader.read(
            characterOffset: offset, maxCharacters: size, wholeFileBytes: wholeFileBytes, expired: expired,
            chunks: Self.chunks(of: data, size: chunk))
    }

    // MARK: The pieces

    @Test("UTF-8 cut at any byte decodes to the same text as the whole")
    func chunkedDecodingMatchesTheWhole() {
        let data = Data(Self.awkward.utf8)
        for size in 1...9 {
            var decoder = UTF8ChunkDecoder()
            var joined = ""
            var start = 0
            while start < data.count {
                let end = min(start + size, data.count)
                joined += decoder.decode(data.subdata(in: start..<end)) ?? "<not UTF-8>"
                start = end
            }
            #expect(decoder.endedOnACharacter, "chunks of \(size)")
            #expect(joined == Self.awkward, "chunks of \(size)")
        }
    }

    @Test("Bytes that are not UTF-8, or that stop in the middle of a character, are not taken for it")
    func invalidUTF8IsRefused() {
        var decoder = UTF8ChunkDecoder()
        #expect(decoder.decode(Data([0x61, 0xFF, 0x62])) == nil)

        var cut = UTF8ChunkDecoder()
        #expect(cut.decode(Data([0x61, 0xC3])) == "a")
        #expect(!cut.endedOnACharacter)
    }

    @Test("A window cut from pieces is the window cut from the whole, wherever the pieces break")
    func pieceWindowMatchesTheWhole() {
        let whole = Self.awkward
        let scalars = Array(whole.unicodeScalars)
        for pieceSize in [1, 2, 3, 5, 8, 13] {
            for (offset, size) in [(0, 5), (3, 4), (7, 30), (0, 10_000), (whole.count - 2, 9), (whole.count + 4, 3)] {
                var window = CharacterWindow(characterOffset: offset, maxCharacters: size)
                var start = 0
                while start < scalars.count {
                    let end = min(start + pieceSize, scalars.count)
                    var piece = String.UnicodeScalarView()
                    piece.append(contentsOf: scalars[start..<end])
                    window.append(String(piece))
                    start = end
                }
                window.finish()
                let expected = ToolStandard.window(of: whole, characterOffset: offset, maxCharacters: size)
                #expect(window.text == expected.text, "pieces of \(pieceSize), window \(offset)+\(size)")
                #expect(window.total == whole.count, "pieces of \(pieceSize)")
            }
        }
    }

    @Test("A file read in chunks of any size gives the same windows and the same count")
    func chunkedReadMatchesTheWhole() throws {
        let data = Data(Self.awkward.utf8)
        for chunk in [1, 2, 3, 4, 7, 64, 1_000_000] {
            var offset = 0
            var joined = ""
            while offset < Self.awkward.count {
                guard case .window(let window) = try window(of: data, chunk: chunk, offset: offset, size: 17) else {
                    Issue.record("chunks of \(chunk): no window")
                    return
                }
                #expect(window.totalCharacters == Self.awkward.count, "chunks of \(chunk)")
                #expect(window.totalBytes == data.count)
                #expect(window.encodingName == "UTF-8")
                guard !window.text.isEmpty else {
                    Issue.record("chunks of \(chunk): an empty window before the end")
                    return
                }
                joined += window.text
                offset += window.text.count
            }
            #expect(joined == Self.awkward, "chunks of \(chunk)")
        }
    }

    @Test("A byte-order mark at the start is left out, whatever the first chunk holds of it")
    func byteOrderMarkIsNotText() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("marked".utf8)
        for chunk in [1, 2, 3, 4, 100] {
            #expect(
                try window(of: data, chunk: chunk, offset: 0, size: 100)
                    == .window(TextWindow(text: "marked", totalCharacters: 6, encodingName: "UTF-8", totalBytes: 9)),
                "chunks of \(chunk)")
        }
    }

    @Test("An empty file is an empty text")
    func emptyFile() throws {
        #expect(
            try window(of: Data(), chunk: 10, offset: 0, size: 10)
                == .window(TextWindow(text: "", totalCharacters: 0, encodingName: "UTF-8", totalBytes: 0)))
    }

    // MARK: Other encodings

    @Test("UTF-16 is recognised by its mark, though half its bytes are NUL")
    func utf16ByItsMark() throws {
        let text = "Invented UTF-16 text, línea dos"
        let data = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        guard case .window(let window) = try window(of: data, chunk: 7, offset: 9, size: 6) else {
            Issue.record("no window")
            return
        }
        #expect(window.text == "UTF-16")
        #expect(window.encodingName == "UTF-16")
        #expect(window.totalCharacters == text.count)
        #expect(window.totalBytes == data.count)
    }

    @Test("Text that is not UTF-8 is decoded whole in another encoding, and the result names it")
    func legacyEncoding() throws {
        let text = "Invented café, señal y más"
        let data = try #require(text.data(using: .isoLatin1))
        guard case .window(let window) = try window(of: data, chunk: 5, offset: 0, size: 100) else {
            Issue.record("no window")
            return
        }
        #expect(window.encodingName != "UTF-8")
        #expect(window.totalCharacters == text.count)
        #expect(window.totalBytes == data.count)
    }

    @Test("A file that is not UTF-8 is read whole only up to the stated size")
    func legacyEncodingHasACeiling() throws {
        let data = try #require(String(repeating: "señal ", count: 100).data(using: .isoLatin1))
        #expect(try window(of: data, chunk: 64, offset: 0, size: 10, wholeFileBytes: data.count - 1) == .tooLargeToDecode)
        guard case .window = try window(of: data, chunk: 64, offset: 0, size: 10, wholeFileBytes: data.count) else {
            Issue.record("a file of exactly the size allowed was refused")
            return
        }
    }

    @Test("A binary file is not text")
    func binaryIsRefused() throws {
        #expect(try window(of: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01]), chunk: 64, offset: 0, size: 10) == .notText)
    }

    @Test("A read that runs out of time after the window was cut returns it, and says the length is unknown")
    func timeLimitAfterTheWindow() throws {
        let data = Data(String(repeating: "x", count: 1000).utf8)
        let asked = InMemoryStore.Counter()
        let outcome = try window(of: data, chunk: 100, offset: 0, size: 10) { asked.next() > 3 }
        guard case .window(let window) = outcome else {
            Issue.record("expected the window that was cut")
            return
        }
        #expect(window.text == "xxxxxxxxxx")
        #expect(!window.isWholeFile)
        #expect(window.totalBytes == 300)
        #expect(window.totalCharacters <= 300)
    }

    @Test("A read that runs out of time before the window is reached says how far it got")
    func timeLimitBeforeTheWindow() throws {
        let data = Data(String(repeating: "x", count: 1000).utf8)
        let asked = InMemoryStore.Counter()
        let outcome = try window(of: data, chunk: 100, offset: 500, size: 10) { asked.next() > 3 }
        guard case .timeLimit(let bytesRead, _) = outcome else {
            Issue.record("expected a time limit")
            return
        }
        #expect(bytesRead == 300)
    }

    // MARK: The tool

    /// 400 numbered lines of 40 characters, some of them wider than one byte.
    private static let lines = (0..<400).map { index -> String in
        let start = String(format: "line %04d ñ ", index)
        return start + String(repeating: "x", count: 39 - start.count) + "\n"
    }.joined()

    private static let store = InMemoryStore { tree in
        tree.file("/invented/notes.txt", lines)
        tree.file("/invented/short.txt", "one line\n")
        tree.file("/invented/empty.txt", "")
        tree.file("/invented/wide.txt", String(repeating: "👩‍👩‍👧", count: 20_000))
        // Three chunks long, so the tool is seen to carry a window across chunks.
        tree.file("/invented/large.txt", String(repeating: "línea ancha número ñ\n", count: 120_000))
        tree.file("/invented/image.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01]))
        tree.file(
            "/invented/latin.txt",
            data: String(repeating: "señal ", count: 3_000_000).data(using: .isoLatin1) ?? Data())
        tree.folder("/invented/folder")
    }

    private func read(_ file: String, _ extra: [String: Value] = [:], scanClock: FilesystemTools.ScanClock? = nil) async -> ToolOutput {
        await call(
            ToolCatalog.readTextName, ["path": .string("/invented/\(file)")].merging(extra) { _, new in new },
            store: Self.store, scanClock: scanClock)
    }

    private func body(_ text: String) throws -> String {
        let heading = try #require(text.range(of: " characters\n\n"))
        return String(text[heading.upperBound...])
    }

    @Test("A long file comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let whole = Self.lines
        let size = ToolCatalog.defaultMaxCharacters
        #expect(whole.count == 16_000)
        let result = await read("notes.txt")
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Characters 1–\(size) of 16000. Pass character_offset=\(size) for the rest.\n\n/invented/notes.txt\n  UTF-8 · "))
        #expect(result.text.contains(" · 16000 characters\n\n"))
        #expect(try body(result.text) == String(whole.prefix(size)))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole file")
    func windowsChain() async throws {
        let whole = Self.lines
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await read("notes.txt", ["character_offset": .int(offset), "max_characters": .int(7000)])
            let window = try body(result.text)
            let last = offset + window.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            try #require(window.count == min(7000, whole.count - offset))
            joined += window
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A file that fits one window carries no notice, and an empty one says so")
    func shortFileHasNoNotice() async throws {
        let result = await read("short.txt")
        #expect(result.text.hasPrefix("/invented/short.txt\n  UTF-8 · 9 B · 9 characters\n\n"))
        #expect(try body(result.text) == "one line\n")
        let empty = await read("empty.txt")
        #expect(empty.text == "/invented/empty.txt\n  UTF-8 · 0 B · 0 characters\n\n  (empty file)")
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        let atMaximum = await read("large.txt", ["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try body(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await read("large.txt", ["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nCharacters 1–\(maximum) of "))
        #expect(try body(over.text).count == maximum)

        let under = await read("notes.txt", ["max_characters": .int(0)])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nCharacters 1–1 of 16000. "))
        #expect(try body(under.text) == "l")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let past = await read("notes.txt", ["character_offset": .int(16_050)])
        #expect(past.text.hasPrefix("Characters 0 of 16000: character_offset=16050 is past the end. That is all.\n\n"))
        #expect(try body(past.text).isEmpty)

        let lastCharacter = await read("notes.txt", ["character_offset": .int(15_999)])
        #expect(lastCharacter.text.hasPrefix("Characters 16000–16000 of 16000. That is all.\n\n"))

        let negative = await read("notes.txt", ["character_offset": .int(-3)])
        let range = ToolCatalog.characterOffsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nCharacters 1–"))
    }

    @Test("A window deep in a file larger than one chunk is the same text the whole file holds there")
    func windowAcrossChunks() async throws {
        let line = "línea ancha número ñ\n"
        #expect(line.utf8.count * 120_000 > 2 * ToolCatalog.readChunkBytes)
        let total = line.count * 120_000
        let offset = line.count * 100_000 + 3
        let result = await read("large.txt", ["character_offset": .int(offset), "max_characters": .int(50)])
        #expect(result.text.hasPrefix("Characters \(offset + 1)–\(offset + 50) of \(total). Pass character_offset=\(offset + 50) for the rest.\n\n"))
        let expected = String(String(repeating: line, count: 4).dropFirst(3).prefix(50))
        #expect(try body(result.text) == expected)
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be six results long.
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < 20_000 {
            let result = await read("wide.txt", ["character_offset": .int(offset), "max_characters": .int(maximum)])
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let window = try body(result.text)
            try #require(!window.isEmpty && window.count < maximum)
            let last = offset + window.count
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of 20000. "))
            joined += window
            offset = last
        }
        #expect(joined == String(repeating: "👩‍👩‍👧", count: 20_000))
    }

    @Test("What is not text, or cannot be read, is refused with what to do instead")
    func refusals() async {
        let binary = await read("image.png")
        #expect(binary.isError && binary.text.contains("is not text in any encoding this server recognises"))

        let folder = await read("folder")
        #expect(folder.isError && folder.text == "'/invented/folder' is a folder, and this tool needs a file.")

        let large = await read("latin.txt")
        #expect(large.isError)
        #expect(
            large.text.hasPrefix(
                "'/invented/latin.txt' is \(Format.bytes(18_000_000)) and not UTF-8, and filesystem_read_text reads a file in any other encoding only up to \(Format.bytes(ToolCatalog.wholeFileBytes))."))

        let slow = await read("large.txt", ["character_offset": .int(2_000_000)], scanClock: expiring(after: 2))
        #expect(slow.isError)
        #expect(
            slow.text.hasPrefix(
                "Reading '/invented/large.txt' did not finish within \(FilesystemTools.defaultScanBudget.components.seconds) seconds: \(Format.bytes(2 * ToolCatalog.readChunkBytes)) had been read."))
    }

    @Test("A read that runs out of time after its window returns the window with a partial notice and no false total")
    func partialWindow() async throws {
        let result = await read("large.txt", scanClock: expiring(after: 2))
        #expect(!result.isError)
        let size = ToolCatalog.defaultMaxCharacters
        #expect(
            result.text.hasPrefix(
                "Partial: the time limit was reached after "))
        #expect(result.text.contains(" characters counted. Narrow by character_offset=\(size) to read on.\n\n/invented/large.txt\n  UTF-8 · read as far as "))
        #expect(result.text.contains(" · at least "))
        #expect(try body(result.text).count == size)
    }
}
