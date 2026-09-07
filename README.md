<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-filesystem-mcp icon">
</p>

# apple-filesystem-mcp

A local MCP server, written in Swift, exposing the macOS filesystem to Claude through
`FileManager`. It ships as a Claude extension.

No Finder, no Apple events, no network. Everything is a direct filesystem call, gated by
two separate allow-lists chosen when the extension is installed: a broad list of folders
Claude may **read**, and a narrower list of folders it may **write to**. Nothing outside
either list is reachable, by any tool.

This server is one of a 4-way split of what used to be a combined FileManager +
Spotlight + PDFKit + Vision surface. Its siblings are
[apple-spotlight-mcp](https://github.com/eneko-codes/apple-spotlight-mcp) (search),
[apple-pdf-mcp](https://github.com/eneko-codes/apple-pdf-mcp) (PDF text/outline/metadata)
and [apple-vision-mcp](https://github.com/eneko-codes/apple-vision-mcp) (OCR). If you're
looking for `fs_search`, `fs_read_pdf` or `fs_ocr`, they now live in those three repos as
`spotlight_search`, `pdf_read` and `vision_ocr`.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 26 or later — the `tagNames` setter `filesystem_tags_set` needs does not exist
  earlier
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `filesystem_status` | read | Reports the read and write scopes and whether macOS is actually letting this process reach them. Reads no file contents. |
| `filesystem_list` | read | One row per item directly inside a folder: kind, name, size, modification date and a content hash. Does not recurse. |
| `filesystem_stat` | read | Full metadata for one file or folder, including whether this process can actually read and write it — a different question from whether the scope allows it. |
| `filesystem_tree` | read | A depth-limited, indented tree of a folder's contents. Sizes only, no hashes. |
| `filesystem_read_text` | read | A text file's contents, with the encoding guessed (UTF-8, UTF-16, ISO Latin 1, Mac OS Roman) and the answer saying which one decoded it. |
| `filesystem_grep` | read | Walks a folder and returns every line matching a regular expression, with path and line number. The fallback for what Spotlight has not indexed. |
| `filesystem_tags_get` | read | Lists the Finder tags on one file or folder. |
| `filesystem_write` | **destructive** | Creates, replaces or appends to a text file. Replacing requires `overwrite=true`. |
| `filesystem_edit` | **destructive** | Replaces one exact, literal string in a text file with another. Refuses to write unless the number of matches equals `expected_count`. |
| `filesystem_mkdir` | write | Creates a folder. Missing intermediate folders are created by default. |
| `filesystem_move` | **destructive** | Moves or renames a file or folder. Both ends must be writable. Requires `overwrite=true` to replace an existing destination. |
| `filesystem_copy` | write | Copies a file or folder. The source need only be readable; only the destination must be writable. Requires `overwrite=true` to replace an existing destination. |
| `filesystem_tags_set` | write | Replaces **all** Finder tags on a file or folder with the list given. `[]` removes every tag. |
| `filesystem_trash` | **destructive** | Moves a file or folder to the Trash. Requires `confirm=true`. |

## The rules worth knowing before you use it

**Canonicalise first, then compare — the order is not negotiable.** Every path is
resolved before it is checked: `~` expanded, `..` removed, symlinks followed. Comparing
the raw string first would let `~/Documents/../../../etc` and a symlink pointing out of
the tree both pass a prefix test while landing somewhere else entirely. The configured
roots are canonicalised the same way, because `/tmp` is itself a symlink to
`/private/tmp` — a root compared raw would reject every path that resolved through it.
Containment is checked by path component, not string prefix, so `Documents-private` is
never mistaken for something inside `Documents`.

**Broad read, narrow write is the design, not a suggestion.** A readable path is not
automatically writable — `filesystem_write`, `filesystem_move`, `filesystem_copy`,
`filesystem_tags_set` and `filesystem_trash` all additionally require the target to sit
inside a configured write root. A write root that lies outside every read root governs
nothing; `filesystem_status` reports that stranded condition rather than leaving it to
be discovered from a refusal.

**Nothing here deletes.** `filesystem_trash` moves an item to the Trash, where the
Finder's File → Put Back returns it to exactly where it was. There is no delete tool, and
emptying the Trash is not something this server can do. `filesystem_trash` requires
`confirm=true`; `filesystem_write`, `filesystem_move` and `filesystem_copy` all require
`overwrite=true` before they will replace anything already at the destination.

**There is no duplicate-finding tool, and there will not be one.** No `find_duplicates`,
no `filesystem_disk_usage`, no `filesystem_recent` — no computed tool of any kind.
`filesystem_list` and `filesystem_stat` give you rows with size and a content hash (the
first 16 hex characters of the file's SHA-256) so that comparing them is your job, done
in the open, rather than a heuristic buried in this server.

**Content search, PDF text and OCR moved out.** This server used to do all of that too —
they are now [apple-spotlight-mcp](https://github.com/eneko-codes/apple-spotlight-mcp),
[apple-pdf-mcp](https://github.com/eneko-codes/apple-pdf-mcp) and
[apple-vision-mcp](https://github.com/eneko-codes/apple-vision-mcp), each with its own
read-only folder scope. `filesystem_grep` is what is left here: it walks files itself
and is far slower than a Spotlight search, so scope it to the smallest folder that could
hold the answer.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-filesystem-mcp.mcpb`. It fails loudly rather than shipping a bundle
that would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-filesystem-mcp.mcpb` with Claude. Then **quit Claude Desktop
completely and reopen it** — reinstalling does not replace a server process that is
already running, and the old one keeps answering.

### 3. Configure the read and write scopes

This server is the one deliberate exception to "nothing to configure" in this family of
extensions: `read_roots` and `write_roots` are not a preference with a sensible default,
they are the security boundary itself. In Claude Desktop → Settings → Extensions →
Files, set:

- **Folders Claude may read** — required. Claude can list and read anything inside
  these; nothing outside them is reachable at all.
- **Folders Claude may write to** — optional. Keep this narrower than the read list and
  inside it. Leave it empty for a strictly read-only server.

Both are `multiple: true` directory pickers, passed to the binary as `--read-roots …`
and `--write-roots …`. There is no hardcoded fallback like `~/Documents` — an
unconfigured install reaches nothing, deliberately, rather than reaching folders nobody
chose.

### 4. Grant the permission

The first call that touches a folder raises the macOS consent dialog for it, one dialog
per top-level location, under System Settings → Privacy & Security → Files and Folders
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas). The
embedded `Info.plist` declares separate usage descriptions for Desktop, Documents,
Downloads, removable volumes and network volumes — a read root anywhere else (iCloud
Drive, an external disk, `~/Code`) falls under **Full Disk Access** instead, which has
no per-folder prompt and has to be granted by hand.

A root that is configured but never actually reached will not prompt. `filesystem_status`
probes every configured root and reports what it found, which is the quickest way to
tell "not yet touched" from "denied" from "outside the scope entirely".

If no dialog ever appears:

```bash
otool -P extension/server/apple-filesystem-mcp | grep UsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-filesystem-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires. This
server sends no Apple events and needs no entitlements file to go with it, unlike the
sibling servers that automate another app.

## Tool switches

Every tool can be turned on and off individually in Claude Desktop, because the bundle
declares all fourteen in its manifest — that is where policy lives, not in this code.
Turning off `filesystem_write`, `filesystem_edit`, `filesystem_mkdir`,
`filesystem_move`, `filesystem_copy`, `filesystem_tags_set` and `filesystem_trash`
leaves a strictly read-only server, on top of whatever the write scope itself already
permits or forbids.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Files": {
      "command": "/absolute/path/to/apple-filesystem-mcp/.build/release/apple-filesystem-mcp",
      "args": ["--read-roots", "/Users/you/Documents", "--write-roots", "/Users/you/Documents/Scratch"]
    }
  }
}
```

You lose the per-tool switches, and the read/write scopes must be passed as arguments by
hand since there is no `user_config` to fill them in for you. Do not do both at once:
two registrations under the same display name collide, and `filesystem_status` reports
the binary in use so you can tell which one answered.

## Known limits

- **No duplicate-finding, disk-usage or "recent files" tool**, by design — see
  [above](#the-rules-worth-knowing-before-you-use-it). `filesystem_list` and
  `filesystem_stat` give you the rows; the comparison is yours.
- **`filesystem_grep` reads every file itself**, so it is far slower than a Spotlight
  search and should be scoped to the smallest folder that could hold the answer.
- **No content search, PDF reading or OCR here.**
  [apple-spotlight-mcp](https://github.com/eneko-codes/apple-spotlight-mcp),
  [apple-pdf-mcp](https://github.com/eneko-codes/apple-pdf-mcp) and
  [apple-vision-mcp](https://github.com/eneko-codes/apple-vision-mcp) are separate
  extensions with their own scopes.
- **Files above a configured hash ceiling are listed without a hash** in
  `filesystem_list`, to avoid reading a whole folder of large files just to produce a
  listing.

## Development

```bash
swift build
swift test
```

18 tests across two suites — `PathScopeTests` and `CatalogueTests` — all against a
modelled filesystem that throws from every method except `canonicalise`, so a scope test
that accidentally reached the real disk fails loudly rather than quietly passing. See
`CLAUDE.md`, whose first section is the hard rule that makes that non-negotiable: no
agent working in this repository may touch a file outside it.

Manual verification against real folders is the owner's job, by hand, with MCP
Inspector.

## Licence

MIT.
