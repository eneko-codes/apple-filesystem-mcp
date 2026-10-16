# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move or delete an existing file outside this repository.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real files, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own file and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you create goes under `$TMPDIR`, in a directory you made yourself — never under `~`, never beside the owner's own files — named `TESTING: ...` and deleted in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) for the filesystem: directory listing, text reading, writing and editing, `grep`, and Finder tags, all through `FileManager`. No Finder, no Apple events, no network.

Access is bounded by `read_roots` / `write_roots`, configured per install.

## Apple frameworks

[FileManager](https://developer.apple.com/documentation/foundation/filemanager) for every listing, walk and write; [`URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues) for type, tags, dates, size and symlink detection; [UniformTypeIdentifiers](https://developer.apple.com/documentation/uniformtypeidentifiers) `UTType` through `contentType`; [CryptoKit](https://developer.apple.com/documentation/cryptokit) `SHA256` for the short content hash; [`NSRegularExpression`](https://developer.apple.com/documentation/foundation/nsregularexpression) for `filesystem_grep`.

## Native surface not used

- `FileManager.removeItem`. `trashItem` is the only removal route, which is what makes Finder's Put Back work. Do not add a hard delete.
- Any content index, PDF text extraction or text recognition. `filesystem_grep` reads bytes itself, and stops at a cap on matches, files scanned and bytes per file.
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

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
