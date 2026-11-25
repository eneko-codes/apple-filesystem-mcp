import Foundation
import Testing

@testable import FilesystemMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every folder, file, tag and line in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented trees with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// A name exactly `length` characters long that starts with `stem` and the row's number.
    private static func name(_ stem: String, _ index: Int, length: Int, suffix: String = "") -> String {
        let start = "\(stem)-\(padded(index))-"
        return start + String(repeating: "x", count: length - start.count - suffix.count) + suffix
    }

    /// One listing tool, and a tree that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        /// False for a scan that stops at the first row past the page, so that a page
        /// which is not the last knows only that more exist.
        var countsTheRest = true
        var readRoots: @Sendable (Int) -> [String] = { _ in ["/invented"] }
        var writeRoots = ["/invented/scratch"]
        var store: @Sendable (Int) -> InMemoryStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolOutput {
            await FilesystemMCPCoreTests.call(
                tool, arguments.merging(extra) { _, new in new }, store: store(count),
                readRoots: readRoots(count), writeRoots: writeRoots)
        }

        /// The rows of a tree with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }

        /// The sentence that places rows `offset + 1` to `last` of `total`.
        func notice(_ offset: Int, _ last: Int, of total: Int) -> String {
            if last == total { return "Showing \(offset + 1)–\(last) of \(total) \(things). That is all." }
            return countsTheRest
                ? "Showing \(offset + 1)–\(last) of \(total) \(things). Pass offset=\(last) for the next page."
                : "Showing \(offset + 1)–\(last) \(things); more exist. Pass offset=\(last) for the next page."
        }
    }

    /// File names 60 characters long: the width a listing pads its name column to.
    private static let list = Listing(
        tool: ToolCatalog.listName, things: "items", limits: ToolCatalog.listLimitRange,
        defaultLimit: ToolCatalog.defaultListLimit, arguments: ["path": "/invented/many"],
        store: { count in
            InMemoryStore { tree in
                tree.folder("/invented/many")
                for index in 0..<count {
                    tree.file(
                        "/invented/many/" + name("item", index, length: 60, suffix: ".txt"),
                        statedSize: 1_047_552)
                }
            }
        },
        row: { "item-\(padded($0))-" })

    private static let tree = Listing(
        tool: ToolCatalog.treeName, things: "entries", limits: ToolCatalog.treeLimitRange,
        defaultLimit: ToolCatalog.defaultTreeLimit, arguments: ["path": "/invented/many"],
        store: { count in
            InMemoryStore { tree in
                tree.folder("/invented/many")
                for index in 0..<count {
                    tree.file(
                        "/invented/many/" + name("entry", index, length: 60, suffix: ".txt"),
                        statedSize: 1_047_552)
                }
            }
        },
        row: { "entry-\(padded($0))-" })

    /// One file whose path is 100 characters, with `count` matching lines exactly as wide
    /// as a row shows a line.
    private static let grep = Listing(
        tool: ToolCatalog.grepName, things: "matching lines", limits: ToolCatalog.grepLimitRange,
        defaultLimit: ToolCatalog.defaultGrepLimit,
        arguments: ["path": "/invented/search", "pattern": "needle"], countsTheRest: false,
        store: { count in
            InMemoryStore { tree in
                tree.folder("/invented/search")
                let lines = (0..<count).map { name("needle", $0, length: ToolCatalog.grepLineWidth) }
                tree.file(
                    "/invented/search/" + name("notes", 0, length: 100 - "/invented/search/".count, suffix: ".txt"),
                    lines.joined(separator: "\n"))
            }
        },
        row: { "needle-\(padded($0))-" })

    private static let tags = Listing(
        tool: ToolCatalog.tagsGetName, things: "tags", limits: ToolCatalog.tagLimitRange,
        defaultLimit: ToolCatalog.defaultTagLimit, arguments: ["path": "/invented/tagged.txt"],
        store: { count in
            InMemoryStore { tree in
                tree.file("/invented/tagged.txt", tags: (0..<count).map { name("tag", $0, length: 30) })
            }
        },
        row: { "tag-\(padded($0))-" })

    private static func root(_ index: Int) -> String {
        "/invented/" + name("root", index, length: 80)
    }

    private static let status = Listing(
        tool: ToolCatalog.statusName, things: "configured folders", limits: ToolCatalog.rootLimitRange,
        defaultLimit: ToolCatalog.defaultRootLimit,
        readRoots: { count in (0..<count).map(root) }, writeRoots: [],
        store: { count in
            InMemoryStore { tree in
                for index in 0..<count { tree.folder(root(index)) }
            }
        },
        row: { "root-\(padded($0))-" })

    private static let listings = [list, tree, grep, tags, status]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(result.text.hasPrefix(listing.notice(0, listing.defaultLimit, of: total) + "\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix(listing.notice(0, maximum, of: total) + "\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"
                    + listing.notice(0, maximum, of: total) + "\n\n"))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(
            under.text.hasPrefix(
                "limit=0 is outside 1–\(maximum); 1 was used.\n" + listing.notice(0, 1, of: total) + "\n\n"))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix(listing.notice(0, 3, of: 7) + "\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix(listing.notice(3, 6, of: 7) + "\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A listing with nothing in it says so, and not that an offset skipped it", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.list.call(1).text.contains("folders first, then by name"))
        #expect(await Self.tree.call(1).text.contains("Each folder's items are in name order, and a folder is followed by what it holds."))
        #expect(await Self.grep.call(1).text.contains("Files are searched in the order filesystem_tree walks them."))
        #expect(await Self.tags.call(1).text.contains("in the order Finder keeps them"))
        #expect(await Self.status.call(1).text.contains("the readable ones first and then the writable ones, each list in the order it was configured"))
    }

    @Test("Names are ordered as the Finder orders them, folders first in a listing")
    func namesOrderNumerically() async {
        let store = InMemoryStore { tree in
            tree.file("/invented/mixed/file10.txt")
            tree.file("/invented/mixed/file2.txt")
            tree.folder("/invented/mixed/zeta")
            tree.file("/invented/mixed/zeta/inside.txt")
        }
        func order(_ text: String) -> [String] {
            ["file2.txt", "file10.txt", "zeta", "inside.txt"]
                .compactMap { name in text.range(of: name).map { (name, $0.lowerBound) } }
                .sorted { $0.1 < $1.1 }.map(\.0)
        }
        let listed = await call(ToolCatalog.listName, ["path": "/invented/mixed"], store: store)
        #expect(order(listed.text) == ["zeta", "file2.txt", "file10.txt"])
        let walked = await call(ToolCatalog.treeName, ["path": "/invented/mixed"], store: store)
        #expect(order(walked.text) == ["file2.txt", "file10.txt", "zeta", "inside.txt"])
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // 250 characters: about the longest name a volume allows.
        let store = InMemoryStore { tree in
            for index in 0..<200 {
                tree.file("/invented/wide/" + Self.name("row", index, length: 250))
            }
        }
        var offset = 0
        var seen: [Int] = []
        while offset < 200 {
            let result = await call(
                ToolCatalog.listName, ["path": "/invented/wide", "limit": .int(200), "offset": .int(offset)],
                store: store)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<200).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 200)
            let next = last + 1 < 200 ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of 200 items. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<200))
    }

    @Test("A page of wide rows cut at the source still says that more exist")
    func wideSourcePageShrinks() async {
        let store = InMemoryStore { tree in
            for index in 0..<300 {
                tree.file("/invented/wide/" + Self.name("row", index, length: 250))
            }
        }
        let result = await call(
            ToolCatalog.treeName, ["path": "/invented/wide", "limit": .int(300)], store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.hasPrefix("Showing 1–150 of 300 entries. Pass offset=150 for the next page.\n\n"))
    }

    // MARK: Numbers moved, values refused

    @Test("depth outside its range is moved, and the result says which value was used")
    func depthIsReported() async {
        let range = ToolCatalog.depthRange
        let result = await Self.tree.call(1, ["depth": .int(range.upperBound + 1)])
        #expect(
            result.text.hasPrefix(
                "depth=\(range.upperBound + 1) is outside \(range.lowerBound)–\(range.upperBound); \(range.upperBound) was used.\n\nTree of /invented/many, \(range.upperBound) levels deep"))
        let inside = await Self.tree.call(1, ["depth": .int(range.upperBound)])
        #expect(inside.text.hasPrefix("Tree of"))
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let store = InMemoryStore { tree in
            tree.file("/invented/a.txt", "text")
            tree.file("/invented/scratch/b.txt", "text")
        }
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.listName, ["path": "/invented", "limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.listName, ["path": "/invented", "limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.listName, ["path": "/invented", "offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.listName, ["path": "/invented", "include_hidden": "yes"], "Argument 'include_hidden' is not valid: true or false was expected"),
            (ToolCatalog.listName, ["path": "/invented", "hashes": 0], "Argument 'hashes' is not valid: true or false was expected"),
            (ToolCatalog.listName, ["path": 5], "Argument 'path' is not valid: text was expected"),
            (ToolCatalog.treeName, ["path": "/invented", "depth": "deep"], "Argument 'depth' is not valid: a whole number was expected"),
            (ToolCatalog.readTextName, ["path": "/invented/a.txt", "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.readTextName, ["path": "/invented/a.txt", "character_offset": [1]], "Argument 'character_offset' is not valid"),
            (ToolCatalog.grepName, ["path": "/invented", "pattern": "a", "name_pattern": 7], "Argument 'name_pattern' is not valid: text was expected"),
            (ToolCatalog.grepName, ["path": "/invented", "pattern": "a", "ignore_case": "no"], "true or false was expected"),
            (ToolCatalog.statusName, ["limit": [1]], "Argument 'limit' is not valid"),
            (ToolCatalog.editName, ["path": "/invented/scratch/b.txt", "find": "t", "replace": 4], "Argument 'replace' is not valid: text was expected"),
            (ToolCatalog.tagsSetName, ["path": "/invented/scratch/b.txt", "tags": "red"], "Argument 'tags' is not valid: a list of texts was expected"),
            (ToolCatalog.tagsSetName, ["path": "/invented/scratch/b.txt", "tags": ["red", 3]], "Argument 'tags' is not valid: a list of texts was expected"),
            (ToolCatalog.trashName, ["path": "/invented/scratch/b.txt", "confirm": "true"], "Argument 'confirm' is not valid: true or false was expected"),
            (ToolCatalog.writeName, ["path": "/invented/scratch/c.txt", "content": "x", "overwrite": 1], "Argument 'overwrite' is not valid"),
        ]
        for (tool, arguments, expected) in cases {
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
        }
    }

    @Test("An argument the schema does not list is refused with the names that are allowed, and nothing runs")
    func unknownArgumentsAreRefused() async {
        let store = InMemoryStore { tree in tree.file("/invented/a.txt", "text") }
        // Names this server used before they were renamed, and a misspelling.
        let cases: [(tool: String, arguments: [String: Value], allowed: String)] = [
            (ToolCatalog.readTextName, ["path": "/invented/a.txt", "max_bytes": 100], "character_offset, max_characters, path"),
            (ToolCatalog.listName, ["path": "/invented", "limt": 5], "hashes, include_hidden, limit, offset, path"),
            (ToolCatalog.statusName, ["offest": 1], "limit, offset"),
            (ToolCatalog.trashName, ["path": "/invented/a.txt", "confirm": true, "force": true], "confirm, path"),
        ]
        for (tool, arguments, allowed) in cases {
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool)")
            #expect(result.text.hasPrefix("\(tool) has no argument '"), "\(result.text)")
            #expect(result.text.contains("It takes: \(allowed). Nothing was run."), "\(result.text)")
        }
        let long = String(repeating: "q", count: 500)
        let echoed = await call(ToolCatalog.statusName, [long: 1], store: store)
        #expect(echoed.text.contains(String(repeating: "q", count: ToolStandard.echoWidth) + "…'"))
        #expect(!echoed.text.contains(String(repeating: "q", count: ToolStandard.echoWidth + 1)))
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.list.call(30, ["limit": 20.0, "offset": .null, "include_hidden": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 items."))
        let missing = await call(ToolCatalog.listName, ["path": .null], store: InMemoryStore())
        #expect(missing.isError && missing.text == "Missing required argument 'path'.")
    }

    @Test("expected_count states something exact, so outside its range it is refused, never moved")
    func exactNumbersAreRefused() async {
        let store = InMemoryStore { $0.file("/invented/scratch/b.txt", "text") }
        let range = ToolCatalog.expectedCountRange
        for count in [range.lowerBound - 1, range.upperBound + 1] {
            let result = await call(
                ToolCatalog.editName,
                ["path": "/invented/scratch/b.txt", "find": "t", "replace": "d", "expected_count": .int(count)],
                store: store)
            #expect(result.isError, "\(count)")
            #expect(
                result.text.contains(
                    "Argument 'expected_count' is not valid: a whole number from \(range.lowerBound) to \(range.upperBound) was expected"),
                "\(count)")
        }
        for count in [range.lowerBound, range.upperBound] {
            let result = await call(
                ToolCatalog.editName,
                ["path": "/invented/scratch/b.txt", "find": "t", "replace": "d", "expected_count": .int(count)],
                store: store)
            #expect(!result.isError, "\(count)")
        }
    }

    @Test("A path longer than the system accepts is refused before it is resolved")
    func longPathsAreRefused() async {
        let limit = ToolCatalog.longestPathBytes
        let long = "/invented/" + String(repeating: "p", count: limit)
        let result = await call(ToolCatalog.statName, ["path": .string(long)], store: InMemoryStore())
        #expect(result.isError)
        #expect(result.text.contains("Argument 'path' is not valid: it is \(long.utf8.count) bytes long"))
        #expect(result.text.contains("A path is at most \(limit) bytes"))
        #expect(result.text.count < 300)

        let atLimit = "/invented/" + String(repeating: "p", count: limit - "/invented/".count)
        let allowed = await call(ToolCatalog.statName, ["path": .string(atLimit)], store: InMemoryStore())
        #expect(allowed.text.hasPrefix("Nothing exists at"))
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let name = String(repeating: "n", count: 5000)
        let unknown = await call(name, store: InMemoryStore())
        #expect(unknown.isError)
        #expect(unknown.text == "'" + String(repeating: "n", count: ToolStandard.echoWidth) + "…' is not a tool of this server.")

        let store = InMemoryStore { $0.folder("/invented/search") }
        let pattern = "(" + String(repeating: "p", count: 5000)
        for arguments: [String: Value] in [
            ["path": "/invented/search", "pattern": .string(pattern)],
            ["path": "/invented/search", "pattern": "fine", "name_pattern": .string(pattern)],
        ] {
            let result = await call(ToolCatalog.grepName, arguments, store: store)
            #expect(result.isError)
            let argument = arguments["name_pattern"] == nil ? "pattern" : "name_pattern"
            #expect(result.text.hasPrefix("'\(argument)' is not a valid regular expression: /(ppp"))
            #expect(!result.text.contains(String(repeating: "p", count: ToolStandard.echoWidth + 1)))
        }

        let find = String(repeating: "f", count: 5000)
        for error in [
            ToolError.editTextNotFound(path: "/invented/a.txt", find: find),
            ToolError.editTextAmbiguous(path: "/invented/a.txt", find: find, found: 3),
        ] {
            #expect(!error.message.contains(String(repeating: "f", count: ToolStandard.echoWidth + 1)))
            #expect(error.message.contains(String(repeating: "f", count: ToolStandard.echoWidth) + "…"))
        }
    }

    @Test("An error names a few of the configured folders and counts the others")
    func errorsListAFewFolders() async {
        let roots = (0..<40).map(Self.root)
        let result = await call(
            ToolCatalog.statName, ["path": "/elsewhere/file.txt"], store: InMemoryStore(), readRoots: roots)
        #expect(result.isError)
        #expect(result.text.contains("is outside the read scope"))
        let named = roots.filter { result.text.contains($0) }
        #expect(named == Array(roots.prefix(ToolError.rootsShown)))
        #expect(result.text.contains("and \(40 - ToolError.rootsShown) more (filesystem_status lists them all)"))

        let few = await call(
            ToolCatalog.statName, ["path": "/elsewhere/file.txt"], store: InMemoryStore(),
            readRoots: Array(roots.prefix(ToolError.rootsShown)))
        #expect(!few.text.contains("more (filesystem_status"))
    }

    @Test("Every error this server words is inside the longest error, whatever it was handed")
    func errorsAreShort() {
        let path = "/" + String(repeating: "p", count: ToolCatalog.longestPathBytes - 1)
        let long = String(repeating: "d", count: 50_000)
        let roots = Array(repeating: path, count: 500)
        let errors: [ToolError] = [
            .noReadRootsConfigured, .noWriteRootsConfigured,
            .pathOutOfScope(requested: path, resolved: path + "/resolved", access: .write, readRoots: roots, writeRoots: roots),
            .missingArgument("path"), .badArgument(name: "limit", reason: "a whole number was expected"),
            .unknownTool(long), .badRegex(argument: "pattern", pattern: long), .notFound(path: path),
            .alreadyExists(path: path), .notADirectory(path: path), .notAFile(path: path),
            .permissionDenied(path: path, detail: long),
            .tooLargeToDecode(path: path, bytes: 5_000_000_000, maximum: ToolCatalog.wholeFileBytes),
            .readTimeLimit(path: path, bytesRead: 5_000_000_000, seconds: 100), .undecodableText(path: path),
            .editTextNotFound(path: path, find: long), .editTextAmbiguous(path: path, find: long, found: 9),
            .destinationInsideSource(from: path, to: path + "/inside"),
            .confirmationRequired(action: "Moving something to the Trash"), .storeFailure(long),
            .timedOut(tool: ToolCatalog.listName, seconds: 180), .timedOut(tool: ToolCatalog.copyName, seconds: 180),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError, "\(Diagnostics.kind(of: error))")
        }
    }

    @Test("The deadline of a call, and the time a scan may take inside it, are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(FilesystemTools.defaultTimeout <= ToolStandard.timeLimit)
        #expect(FilesystemTools.defaultScanBudget < FilesystemTools.defaultTimeout)
    }

    @Test("A read that does not finish in time is abandoned and says nothing was changed")
    func stuckReadIsAbandoned() async {
        var store = InMemoryStore { $0.folder("/invented/slow") }
        store.delay = 0.5
        let result = await call(
            ToolCatalog.listName, ["path": "/invented/slow"], store: store, timeout: .milliseconds(50))
        #expect(result.isError)
        #expect(result.text.hasPrefix("The call did not finish within 0 seconds and was abandoned. It only reads, so nothing was changed."))
    }

    @Test("A write that does not finish in time says it was not stopped")
    func stuckWriteIsNotStopped() async {
        var store = InMemoryStore { $0.file("/invented/a.txt", "text") }
        store.delay = 0.5
        let result = await call(
            ToolCatalog.copyName, ["from": "/invented/a.txt", "to": "/invented/scratch/a.txt"], store: store,
            timeout: .milliseconds(50))
        #expect(result.isError)
        #expect(result.text.contains("The operation itself was NOT stopped"))
        #expect(result.text.contains("filesystem_stat"))
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: FilesystemMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
        #expect(!FilesystemMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.readTextName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)
        #expect(ToolCatalog.maxCharactersRange.upperBound < ToolStandard.longestResult)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(offset["maximum"]?.intValue == ToolCatalog.characterOffsetRange.upperBound)
        #expect(tool.description?.contains("max_characters (up to \(ToolCatalog.maxCharactersRange.upperBound))") == true)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page and window a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters"]
        let lookalikes: Set = [
            "max", "count", "max_results", "max_matches", "max_bytes", "page", "page_size", "skip",
            "start", "max_chars", "max_length", "char_offset", "byte_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    @Test("The texts state the bounds the code enforces")
    func textsStateTheBounds() throws {
        let scan = FilesystemTools.defaultScanBudget.components.seconds
        let timeout = FilesystemTools.defaultTimeout.components.seconds
        let instructions = FilesystemMCPServer.instructions
        #expect(instructions.contains("more than \(scan) seconds"))
        #expect(instructions.contains("after \(timeout) seconds"))

        func description(_ name: String) throws -> String {
            try #require(ToolCatalog.all().first { $0.name == name }?.description)
        }
        let grep = try description(ToolCatalog.grepName)
        #expect(grep.contains("after \(ToolCatalog.grepFileCeiling) files or \(scan) seconds"))
        #expect(grep.contains("files larger than \(Format.bytes(ToolCatalog.grepFileBytes))"))
        #expect(grep.contains("up to \(ToolCatalog.grepLineWidth) characters"))
        let tree = try description(ToolCatalog.treeName)
        #expect(tree.contains("at most \(ToolCatalog.treeCountCeiling)"))
        #expect(tree.contains("\(ToolCatalog.defaultDepth) levels deep"))
        let read = try description(ToolCatalog.readTextName)
        #expect(read.contains("first \(ToolCatalog.defaultMaxCharacters) characters"))
        #expect(read.contains("only up to \(Format.bytes(ToolCatalog.wholeFileBytes))"))
        #expect(try description(ToolCatalog.copyName).contains("more than \(timeout) seconds"))
        #expect(try description(ToolCatalog.statName).contains("longer than \(ToolCatalog.tagsFieldWidth) characters"))
    }
}
