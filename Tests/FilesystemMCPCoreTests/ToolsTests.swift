import Foundation
import Testing

@testable import FilesystemMCPCore

/// The tools driven end to end against an invented tree: what each one leaves out, how it
/// says so, and what a scan does when it stops early. No file here exists anywhere.
@Suite("Tools")
struct ToolsTests {

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    // MARK: List

    private static let folder = InMemoryStore { tree in
        tree.folder("/invented/docs/archive")
        tree.file("/invented/docs/alpha.txt", "alpha")
        tree.file("/invented/docs/beta.txt", "beta!")
        tree.file("/invented/docs/huge.bin", statedSize: 64_000_000)
        tree.file("/invented/docs/.secret", "hidden", hidden: true)
        tree.folder("/invented/docs/.cache", hidden: true)
    }

    @Test("Hidden items are left out, counted before the data, and listed on request")
    func listHidesAndCounts() async {
        let result = await call(ToolCatalog.listName, ["path": "/invented/docs"], store: Self.folder)
        #expect(
            result.text.hasPrefix(
                """
                2 hidden items are not shown. Pass include_hidden=true to include them.

                Contents of /invented/docs: 4 items, folders first, then by name.
                Columns: kind, name, size, modified, sha256 (first 16 hex characters).

                  dir   archive
                """))
        #expect(!result.text.contains(".secret"))
        #expect(result.text.contains("(too large to hash)"))

        let all = await call(
            ToolCatalog.listName, ["path": "/invented/docs", "include_hidden": true], store: Self.folder)
        #expect(all.text.hasPrefix("Contents of /invented/docs: 6 items"))
        #expect(all.text.contains(".secret") && all.text.contains(".cache"))
    }

    @Test("Only the files on the page are hashed, and none when hashes are off")
    func listHashesThePageOnly() async {
        let store = InMemoryStore { tree in
            for index in 0..<120 { tree.file("/invented/many/file-\(Self.padded(index)).txt", "x") }
        }
        _ = await call(ToolCatalog.listName, ["path": "/invented/many", "limit": 10, "offset": 40], store: store)
        #expect(store.hashed.value == 10)

        let plain = InMemoryStore { tree in
            for index in 0..<120 { tree.file("/invented/many/file-\(Self.padded(index)).txt", "x") }
        }
        let result = await call(ToolCatalog.listName, ["path": "/invented/many", "hashes": false], store: plain)
        #expect(plain.hashed.value == 0)
        #expect(result.text.hasPrefix("Showing 1–\(ToolCatalog.defaultListLimit) of 120 items."))
    }

    @Test("A page whose hashing runs out of time ends early, says so, and the next call resumes there")
    func listStopsHashingInTime() async {
        let store = InMemoryStore { tree in
            for index in 0..<30 { tree.file("/invented/many/file-\(Self.padded(index)).txt", "x") }
        }
        let result = await call(
            ToolCatalog.listName, ["path": "/invented/many"], store: store, scanClock: expiring(after: 6))
        #expect(
            result.text.hasPrefix(
                """
                Partial: the time limit was reached after 7 items. Narrow by a smaller limit or hashes=false.
                Showing 1–7 of 30 items. Pass offset=7 for the next page.

                Contents of /invented/many: 30 items
                """))
        #expect(result.text.contains("file-0006.txt") && !result.text.contains("file-0007.txt"))

        // With no time at all a page still holds its first row, so paging always advances.
        let none = await call(
            ToolCatalog.listName, ["path": "/invented/many", "offset": 7], store: store,
            scanClock: expiring(after: 0))
        #expect(none.text.contains("Showing 8–8 of 30 items. Pass offset=8 for the next page."))
    }

    @Test("A file where a folder is needed is refused")
    func listNeedsAFolder() async {
        let result = await call(ToolCatalog.listName, ["path": "/invented/docs/alpha.txt"], store: Self.folder)
        #expect(result.isError && result.text == "'/invented/docs/alpha.txt' is a file, and this tool needs a folder.")
    }

    // MARK: Tree

    private static let nested = InMemoryStore { tree in
        tree.file("/invented/project/readme.txt", "read me")
        tree.file("/invented/project/src/main.txt", "main")
        tree.file("/invented/project/src/deep/deeper/deepest.txt", "deep")
        tree.file("/invented/project/.hidden/inside.txt", "inside")
        tree.folder("/invented/project/.hidden", hidden: true)
    }

    @Test("A tree shows each folder followed by what it holds, to the depth asked")
    func treeShape() async {
        let result = await call(ToolCatalog.treeName, ["path": "/invented/project"], store: Self.nested)
        #expect(
            result.text == """
                1 hidden items in the folders walked are not shown. Pass include_hidden=true to include them.

                Tree of /invented/project, 3 levels deep: 5 entries. Each folder's items are in name order, and a folder is followed by what it holds.

                  readme.txt  7 B
                  src/
                    deep/
                      deeper/
                    main.txt  4 B
                """)

        let shallow = await call(
            ToolCatalog.treeName, ["path": "/invented/project", "depth": 1, "include_hidden": true],
            store: Self.nested)
        #expect(shallow.text.hasPrefix("Tree of /invented/project, 1 level deep: 3 entries."))
        #expect(shallow.text.contains(".hidden/") && !shallow.text.contains("main.txt"))
    }

    @Test("A tree too large to count says that more exist, and a page deep into it is still reached")
    func treeLargerThanTheCount() async {
        let ceiling = ToolCatalog.treeCountCeiling
        let store = InMemoryStore { tree in
            for index in 0..<(ceiling + 50) { tree.file("/invented/big/entry-\(String(format: "%05d", index))") }
        }
        let first = await call(ToolCatalog.treeName, ["path": "/invented/big"], store: store)
        let limit = ToolCatalog.defaultTreeLimit
        #expect(
            first.text.hasPrefix(
                "Showing 1–\(limit) entries; more exist. Pass offset=\(limit) for the next page.\n\nTree of /invented/big, 3 levels deep: more than \(ceiling) entries."))

        let deep = await call(ToolCatalog.treeName, ["path": "/invented/big", "offset": .int(ceiling + 20)], store: store)
        #expect(deep.text.hasPrefix("Showing \(ceiling + 21)–\(ceiling + 50) of \(ceiling + 50) entries. That is all.\n\n"))
        #expect(deep.text.contains("entry-\(ceiling + 49)") && !deep.text.contains("entry-\(ceiling + 19)\n"))

        let counted = InMemoryStore { tree in
            for index in 0..<ceiling { tree.file("/invented/big/entry-\(String(format: "%05d", index))") }
        }
        let exact = await call(ToolCatalog.treeName, ["path": "/invented/big"], store: counted)
        #expect(exact.text.hasPrefix("Showing 1–\(limit) of \(ceiling) entries. Pass offset=\(limit) for the next page.\n\n"))
    }

    @Test("A walk that runs out of time returns what it reached and says it is partial")
    func treeStopsInTime() async {
        let store = InMemoryStore { tree in
            for folder in 0..<10 {
                for file in 0..<5 { tree.file("/invented/slow/folder-\(folder)/file-\(file).txt") }
            }
        }
        // The clock is asked once for each folder the walk opens.
        let result = await call(
            ToolCatalog.treeName, ["path": "/invented/slow"], store: store, scanClock: expiring(after: 3))
        #expect(
            result.text.hasPrefix(
                """
                Partial: the time limit was reached after 18 entries. Narrow by path or a lower depth.

                Tree of /invented/slow, 3 levels deep: at least 18 entries.
                """))
        #expect(!result.text.contains("Showing"))
        #expect(result.text.contains("folder-1/") && result.text.contains("folder-2/") && !result.text.contains("folder-3/"))

        let nothingYet = await call(
            ToolCatalog.treeName, ["path": "/invented/slow", "offset": 40], store: store,
            scanClock: expiring(after: 3))
        #expect(nothingYet.text.hasPrefix("Partial: the time limit was reached after 18 entries."))
        #expect(nothingYet.text.contains("(nothing at this offset)"))
    }

    // MARK: Grep

    private static let sources = InMemoryStore { tree in
        tree.file("/invented/code/a.txt", "first needle\nnothing\nNEEDLE again\n")
        tree.file("/invented/code/b.md", "a needle in markdown\n")
        tree.file("/invented/code/sub/c.txt", "deep needle\n")
        tree.file("/invented/code/windows.txt", "one\r\ntwo needle\r\nthree\r\n")
        tree.file("/invented/code/.env", "needle hidden\n", hidden: true)
        tree.folder("/invented/code/.git", hidden: true)
        tree.file("/invented/code/.git/config", "needle in a hidden folder\n")
        tree.folder("/invented/code/Tool.app", package: true)
        tree.file("/invented/code/Tool.app/strings.txt", "needle in a package\n")
        tree.folder("/invented/code/linked", symbolicLink: true)
        tree.file("/invented/code/linked/far.txt", "needle behind a link\n")
        tree.file("/invented/code/alias.txt", "needle through a link\n", symbolicLink: true)
        tree.file("/invented/code/picture.png", data: Data([0x89, 0x50, 0x00, 0x01]))
        tree.file("/invented/code/dump.log", "needle\n", statedSize: ToolCatalog.grepFileBytes + 1)
    }

    @Test("A search returns each matching line with its path and number, and says what it passed over")
    func grepFindsLines() async {
        let result = await call(
            ToolCatalog.grepName, ["path": "/invented/code", "pattern": "needle"], store: Self.sources)
        #expect(
            result.text == """
                2 files were not searched: 1 larger than 4.0 MB, 1 binary or not text. Read a large text file with filesystem_read_text.

                /needle/ in /invented/code: 5 matches in 4 files. Files are searched in the order filesystem_tree walks them.

                  /invented/code/a.txt:1
                      first needle
                  /invented/code/a.txt:3
                      NEEDLE again
                  /invented/code/b.md:1
                      a needle in markdown
                  /invented/code/sub/c.txt:1
                      deep needle
                  /invented/code/windows.txt:2
                      two needle
                """)
    }

    @Test("Case and file name narrow a search")
    func grepNarrows() async {
        let exact = await call(
            ToolCatalog.grepName, ["path": "/invented/code", "pattern": "needle", "ignore_case": false],
            store: Self.sources)
        #expect(exact.text.contains("4 matches in 4 files") && !exact.text.contains("NEEDLE again"))

        let named = await call(
            ToolCatalog.grepName, ["path": "/invented/code", "pattern": "needle", "name_pattern": "\\.MD$"],
            store: Self.sources)
        #expect(named.text.hasPrefix("/needle/ in /invented/code: 1 match in 1 file."))

        let none = await call(
            ToolCatalog.grepName, ["path": "/invented/code", "pattern": "haystack", "name_pattern": "\\.md$"],
            store: Self.sources)
        #expect(none.text.hasSuffix("(no matches)") && none.text.contains("0 matches in 1 file."))
    }

    @Test("A long line is clipped to the stated width, and the result names the tool that reads the file")
    func grepClipsLines() async {
        let width = ToolCatalog.grepLineWidth
        let store = InMemoryStore { tree in
            tree.file("/invented/long/a.txt", "   needle " + String(repeating: "w", count: 5000) + "\nneedle short\n")
        }
        let result = await call(ToolCatalog.grepName, ["path": "/invented/long", "pattern": "needle"], store: store)
        #expect(
            result.text.hasPrefix(
                "Line is clipped to \(width) characters in each row. Read one in full with filesystem_read_text.\n\n/needle/"))
        #expect(result.text.contains("\n      needle " + String(repeating: "w", count: width - 7) + "…\n"))
        #expect(!result.text.contains(String(repeating: "w", count: width)))

        let second = await call(
            ToolCatalog.grepName, ["path": "/invented/long", "pattern": "needle", "offset": 1], store: store)
        #expect(second.text.hasPrefix("Showing 2–2 of 2 matching lines. That is all.\n\n"))
        #expect(!second.text.contains("is clipped"))
        #expect(second.text.contains("Matches 2–2 follow."))
    }

    @Test("A scan that reaches the ceiling on files says so, and offers no offset that would stop at the same place")
    func grepStopsAtTheFileCeiling() async {
        let ceiling = ToolCatalog.grepFileCeiling
        let store = InMemoryStore { tree in
            for index in 0...ceiling {
                tree.file("/invented/wide/file-\(String(format: "%05d", index)).txt", index % 1000 == 0 ? "needle\n" : "hay\n")
            }
        }
        let result = await call(ToolCatalog.grepName, ["path": "/invented/wide", "pattern": "needle"], store: store)
        #expect(
            result.text.hasPrefix(
                """
                The scan stopped after \(ceiling) files; more may exist. Narrow by path or name_pattern.

                /needle/ in /invented/wide: 5 matches in the \(ceiling) files searched before the scan stopped.
                """))
        #expect(!result.text.contains("Showing"))

        let narrowed = await call(
            ToolCatalog.grepName, ["path": "/invented/wide", "pattern": "needle", "name_pattern": "file-0400"],
            store: store)
        #expect(narrowed.text.hasPrefix("/needle/ in /invented/wide: 1 match in 10 files."))
    }

    @Test("A scan that runs out of time returns what it found and says it is partial")
    func grepStopsInTime() async {
        let store = InMemoryStore { tree in
            for index in 0..<20 { tree.file("/invented/slow/file-\(Self.padded(index)).txt", "needle \(index)\n") }
        }
        // The clock is asked once for each item the walk meets.
        let result = await call(
            ToolCatalog.grepName, ["path": "/invented/slow", "pattern": "needle"], store: store,
            scanClock: expiring(after: 4))
        #expect(
            result.text.hasPrefix(
                """
                Partial: the time limit was reached after 4 files. Narrow by path or name_pattern.

                /needle/ in /invented/slow: 4 matches in the 4 files searched before the scan stopped.
                """))
        #expect(!result.text.contains("Showing"))
    }

    @Test("A folder is needed, and a pattern that does not compile is named")
    func grepRefusals() async {
        let file = await call(
            ToolCatalog.grepName, ["path": "/invented/code/a.txt", "pattern": "x"], store: Self.sources)
        #expect(file.isError && file.text.contains("is a file, and this tool needs a folder"))
        let pattern = await call(
            ToolCatalog.grepName, ["path": "/invented/code", "pattern": "(unclosed"], store: Self.sources)
        #expect(pattern.isError && pattern.text.hasPrefix("'pattern' is not a valid regular expression: /(unclosed/"))
    }

    // MARK: Tags, stat and status

    @Test("A long list of tags is clipped where it is one field, and the result names the tool that lists them")
    func tagsFieldIsClipped() async {
        let width = ToolCatalog.tagsFieldWidth
        let many = (0..<200).map { "tag-\(Self.padded($0))" }
        let store = InMemoryStore { tree in
            tree.file("/invented/scratch/tagged.txt", "x", tags: many)
            tree.file("/invented/scratch/plain.txt", "x", tags: ["red", "work"])
        }
        let notice = "Tags is clipped to \(width) characters in each row. Read one in full with filesystem_tags_get.\n\n"

        let stat = await call(ToolCatalog.statName, ["path": "/invented/scratch/tagged.txt"], store: store)
        #expect(stat.text.hasPrefix(notice + "  path"))
        #expect(stat.text.contains("tag-0000, tag-0001") && !stat.text.contains("tag-0199"))

        let plain = await call(ToolCatalog.statName, ["path": "/invented/scratch/plain.txt"], store: store)
        #expect(plain.text.hasPrefix("  path") && plain.text.contains("red, work"))

        let set = await call(
            ToolCatalog.tagsSetName,
            ["path": "/invented/scratch/plain.txt", "tags": .array(many.map { .string($0) })], store: store)
        #expect(set.text.hasPrefix(notice + "Tags set on /invented/scratch/plain.txt"))
        #expect(!set.text.contains("tag-0199"))

        let cleared = await call(
            ToolCatalog.tagsSetName, ["path": "/invented/scratch/plain.txt", "tags": []], store: store)
        #expect(cleared.text.contains("(none — all tags removed)"))
    }

    @Test("Status lists each configured folder with its state, and marks a write root that governs nothing")
    func statusRows() async {
        let store = InMemoryStore { tree in
            tree.folder("/invented/docs")
            tree.folder("/invented/docs/scratch")
        }
        let result = await call(
            ToolCatalog.statusName, store: store, readRoots: ["/invented/docs", "/invented/gone"],
            writeRoots: ["/invented/docs/scratch", "/elsewhere/out"])
        #expect(result.text.hasPrefix("Filesystem scope: 2 read root(s), 2 write root(s)."))
        #expect(
            result.text.contains(
                """
                Configured folders: 4, the readable ones first and then the writable ones, each list in the order it was configured.
                  read   /invented/docs — reachable
                  read   /invented/gone — missing
                  write  /invented/docs/scratch — reachable
                  write  /elsewhere/out — missing — STRANDED: outside every readable folder
                """))
        #expect(result.text.contains("WARNING — 1 write root lies outside every read root and so governs nothing"))

        let nothing = await call(ToolCatalog.statusName, store: store, readRoots: [], writeRoots: [])
        #expect(nothing.text.hasPrefix("Filesystem scope: NOTHING configured"))
        #expect(nothing.text.contains("(no readable folder configured — nothing is reachable)"))
    }

    @Test("Write tools keep their guards")
    func writeGuards() async {
        let store = InMemoryStore { tree in
            tree.file("/invented/scratch/b.txt", "text")
            tree.file("/invented/a.txt", "text")
        }
        let trash = await call(ToolCatalog.trashName, ["path": "/invented/scratch/b.txt"], store: store)
        #expect(trash.isError && trash.text.contains("requires confirm=true"))
        let confirmed = await call(
            ToolCatalog.trashName, ["path": "/invented/scratch/b.txt", "confirm": true], store: store)
        #expect(confirmed.text.hasPrefix("Moved to the Trash — NOT deleted."))

        let clobber = await call(
            ToolCatalog.writeName, ["path": "/invented/scratch/b.txt", "content": "new"], store: store)
        #expect(clobber.isError && clobber.text.contains("Something already exists at"))

        let outside = await call(
            ToolCatalog.writeName, ["path": "/invented/a.txt", "content": "new", "overwrite": true], store: store)
        #expect(outside.isError && outside.text.contains("is outside the write scope"))

        let copied = await call(
            ToolCatalog.copyName, ["from": "/invented/a.txt", "to": "/invented/scratch/a.txt"], store: store)
        #expect(copied.text.hasPrefix("Copied:"))
    }
}
