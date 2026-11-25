# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move or delete an existing file outside this repository.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real files, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own file and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you create goes under `$TMPDIR`, in a directory you made yourself — never under `~`, never beside the owner's own files — named `TESTING: ...` and deleted in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) for the filesystem: directory listing, text reading, writing and editing, `grep`, and Finder tags, all through `FileManager`. No Finder, no Apple events, no network, **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

Access is bounded by `read_roots` / `write_roots`, configured per install.

## Apple frameworks

[FileManager](https://developer.apple.com/documentation/foundation/filemanager) for every listing, walk and write; [`URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues) for type, tags, dates, size and symlink detection; [UniformTypeIdentifiers](https://developer.apple.com/documentation/uniformtypeidentifiers) `UTType` through `contentType`; [CryptoKit](https://developer.apple.com/documentation/cryptokit) `SHA256` for the short content hash; [`NSRegularExpression`](https://developer.apple.com/documentation/foundation/nsregularexpression) for `filesystem_grep`.

## Native surface not used

- `FileManager.removeItem`. `trashItem` is the only removal route, which is what makes Finder's Put Back work. Do not add a hard delete.
- Any content index, PDF text extraction or text recognition. `filesystem_grep` reads bytes itself, a page of matches at a time, and stops at a cap on files searched, bytes per file and time.
- Apple events entirely — this server drives no app, which is why it ships no entitlements file.
- File-presenter and coordinated-read APIs (`NSFileCoordinator`, `NSFilePresenter`).

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-filesystem-mcp | grep UsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

`FilesystemStore` is the only door to the disk. `SystemFilesystemStore` implements it over `FileManager`; the tests implement it with `InMemoryStore`, an invented tree. The walks themselves (the order of rows, the page cut out of them, every reason a walk stops early) are pure code in `FolderScan`, and reading a window of a file is pure code in `TextReader`: both stores hand them closures that list a folder and yield a file's bytes, so the tests run the same walk the real disk gets.

**How a tool keeps to the tool standard here.** Sizes are constants in `ToolCatalog`, and the schemas, the descriptions and the instructions quote them by interpolation, never as literals. `Arguments.int` moves a quantity (`limit`, `offset`, `depth`, a window) into its range and collects the sentence that says so in `notices`; `Arguments.exactInt` refuses `expected_count` outside its range, because the nearest value would assert something the caller never said; a wrong type is refused with the form expected, and so is an argument the schema does not list (`FilesystemTools.refuseUnknownArguments`), with the names allowed, so a call that still uses a renamed argument fails instead of running without it. Rows that are all in hand (tags, configured folders) go through `ToolStandard.page`. Rows that are not (a folder whose page has to be hashed, a tree, a grep) are paged at the source by `FolderScan`, in an order the result states, and the tool builds the position with `Notice.page`, with no total when the scan stopped at the first row past the page. A scan that stops for another reason says so with `Notice.scanStopped` or `Notice.partial` and offers no offset. `filesystem_read_text` windows a file in characters with `character_offset` and `max_characters`: `TextReader` streams UTF-8 a chunk at a time, so memory is bounded and reach is not (there is no byte budget behind the window: the time limit is what bounds a huge file, and a window read before it ran out is returned with `Notice.partial` and no false total), and decodes any other encoding whole, up to `ToolCatalog.wholeFileBytes`. Every result renders through `ToolStandard.fitting`, which halves a page or a window whose text would still be longer than a result may be, so a tool never leans on the guard. `Deadline` abandons a call at `FilesystemTools.defaultTimeout`; a scan returns what it has at `defaultScanBudget`. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

## Release checklist

- **Three files carry the version and must agree**: `extension/manifest.json`, `FilesystemMCPServer.version` in `Server.swift`, and `CFBundleShortVersionString` in `Resources/Info.plist`. `VersionTests` checks it.
- **The text the model reads is code.** Update the server `instructions`, tool and argument descriptions and the manifest `tools` and `long_description` in the same commit as the behaviour.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
