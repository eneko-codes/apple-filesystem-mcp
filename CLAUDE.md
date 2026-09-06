# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S FILES ARE NOT YOURS TO CHANGE

**It is FORBIDDEN to create, modify, move, trash or tag any file outside this repository.**
This rule outranks every other instruction in this file. It applies to every agent and every
session, with no "just this once" and no putting-it-back-afterwards.

This server exists to bound what a program may touch. An agent that reaches around it —
writing with `FileManager` directly, shelling out to `mv`, or "just checking" something in
the home directory — has defeated the only thing the repository is for.

Never:

- write, edit, move, copy, trash, `mkdir` or re-tag anything outside this repository, by any
  route, including plain shell commands;
- read a real document to "see what the shape is" — the fixtures show the shape;
- run a tool against a real path to test it: `PathScopeTests` covers every case with a
  modelled filesystem;
- widen `readRoots` or `writeRoots` in a committed default;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary directory the agent created
itself — under `$TMPDIR`, never under `~` — may be written to and read from freely, provided
it is deleted in the same session.

**Fixtures first, always.** The store double in `PathScopeTests` **throws from every method
except `canonicalise`**. That is deliberate: a scope test that accidentally reached the real
filesystem must fail loudly rather than quietly pass. Keep it that way.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests model the filesystem; they never touch it |
| `initialize`, `tools/list` over stdio | Protocol only; no path is resolved |
| `ls`, `stat` inside this repository | Read-only, in scope |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real folders remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) for the filesystem: directory listing,
text reading, writing and editing, `grep`, and Finder tags, all through `FileManager`.
No Finder, no Apple events, no network.

This repository used to also cover Spotlight search, PDF reading and OCR
(`NSMetadataQuery`, `PDFKit`, `Vision`). Those moved out to their own repositories —
`apple-spotlight-mcp`, `apple-pdf-mcp`, `apple-vision-mcp` — per
`apple-filesystem-split-plan.md` (an external, unversioned planning document that lives
in `~/Code/`, alongside this repository rather than inside it). If a change here seems
to want one of those frameworks back, it almost certainly belongs in one of those
repositories instead.

**This package requires macOS 26** (`platforms: [.macOS("26.0")]`). The `tagNames`
setter `filesystem_tags_set` needs is not available earlier. Note that `.v26` does not
exist as a `PackageDescription` case in this toolchain; the string form is required.

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

`Sources/FilesystemMCPCore` holds everything; `Sources/apple-filesystem-mcp/main.swift` is a
launcher that exists only because a Swift executable target cannot be imported by a test
target.

**`PathScope` is the point of the repository.** One small file with one exported operation:
turn a string the model wrote into a `ScopedPath`, or refuse.

**`ScopedPath`'s initialiser is `fileprivate` to `PathScope.swift`.** No other code in the
module can mint one, so a store method that takes a path can only ever be handed a path that
came through the allow-list. Forgetting the check is a **compile error**, not an escape —
and the tests cannot skip past the guard either. Do not relax that access level, and do not
add a second way to construct one.

## Invariants worth protecting

- **Canonicalise first, then compare. The order is not negotiable.** Comparing the raw
  string would let `~/Documents/../../../etc` and a symlink pointing out of the tree both
  pass a prefix test while landing somewhere else entirely.
- **The roots are canonicalised too.** `/tmp` is a symlink to `/private/tmp`, so a root
  compared raw would reject every path that resolved through it.
- **Containment is by path component, not by string prefix.** `Documents-private` is not
  inside `Documents`.
- **A write must clear both lists, and read is checked first**, so the error names the outer
  boundary that was crossed rather than the inner one.
- **Broad read, narrow write is the design, not a suggestion.** A readable path is not
  automatically writable, and a test asserts exactly that.
- **A write root outside every read root governs nothing.** `strandedWriteRoots` reports
  it in `filesystem_status` rather than letting the person discover it from a refusal
  naming a folder they deliberately configured.
- **Nothing here deletes.** `filesystem_trash` calls `FileManager.trashItem`, which is
  recoverable. No tool may be named `delete` or `remove`, and a test enforces that.
- **No computed tools.** No `find_duplicates`, no `filesystem_disk_usage`, no
  `filesystem_recent`. Rows carry size and a content hash so the model can work those out
  where it can be watched. A test rejects tool names containing `stats`, `summary`,
  `duplicate`, `recent`, `usage`, `insight` or `triage`.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## `read_roots` / `write_roots` are the one settings exception in this family

Every sibling server (WhatsApp, Messages, Mail, Calendar, Notes, …) had its `user_config`
settings removed in favour of plug-and-play: constants in code, with only the per-tool
allow/ask/prohibit switch left as a control. This server is the deliberate exception,
decided by the owner rather than overlooked. `read_roots` and `write_roots` are not a
preference to default away — they are the security boundary itself. A hardcoded default
(`~/Documents`, `~/Desktop`, `~/Downloads`) was considered and rejected: it would make an
unconfigured install reach folders nobody chose, in a server whose entire purpose is that
choice. Do not remove these two settings to make this server "consistent" with the others;
that inconsistency is intentional.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce
`dist/apple-filesystem-mcp.mcpb`. The manifest's `tools` array creates the per-tool switches
in Claude Desktop and is read before the server has ever run.

`read_roots` and `write_roots` are `multiple: true` directory settings, passed as
`--read-roots …` and `--write-roots …`. `collectList` stops at the next `--`-prefixed token,
which is why both lists can share one argument vector with no separator. There is **no**
`--` separator here, unlike the sibling servers — a flag the parser does not read fails
silently, leaving the scope on its default.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` declares the folder usage
descriptions — Desktop, Documents, Downloads, removable and network volumes — without which
macOS denies access **without ever prompting**.

Those prompts are per-folder and appear the first time a path inside one is touched. A root
that is configured but never reached will not prompt, which is why `filesystem_status`
probes every root and reports what it found.

**A linker-signed binary gets no TCC prompt at all.** `pack.sh` re-signs and prints the
designated requirement; an empty line there means the build is broken in a way nothing else
will show.
