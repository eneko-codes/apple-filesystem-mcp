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
| `filesystem_status` | read | Reports the read and write scopes, a page of configured folders at a time, and whether macOS is actually letting this process reach them. Reads no file contents. |
| `filesystem_list` | read | One row per item directly inside a folder, a page at a time, folders first: kind, name, size, modification date and a content hash. Does not recurse. |
| `filesystem_stat` | read | Full metadata for one file or folder, including whether this process can actually read and write it — a different question from whether the scope allows it. |
| `filesystem_tree` | read | A depth-limited, indented tree of a folder's contents, a page of entries at a time. Sizes only, no hashes. |
| `filesystem_read_text` | read | A text file's contents, a window of characters at a time, with the encoding guessed (UTF-8, UTF-16 by its byte-order mark, else whatever Foundation infers, ISO Latin 1, Mac OS Roman) and the answer saying which one decoded it. |
| `filesystem_grep` | read | Walks a folder and returns the lines matching a regular expression, a page at a time, with path and line number. The fallback for what Spotlight has not indexed. |
| `filesystem_tags_get` | read | Lists the Finder tags on one file or folder, a page at a time. |
| `filesystem_write` | **destructive** | Creates, replaces or appends to a text file. Replacing requires `overwrite=true`. |
| `filesystem_edit` | **destructive** | Replaces one exact, literal string in a text file with another. Refuses to write unless the number of matches equals `expected_count`. |
| `filesystem_mkdir` | write | Creates a folder. Missing intermediate folders are created by default. |
| `filesystem_move` | **destructive** | Moves or renames a file or folder. Both ends must be writable. Requires `overwrite=true` to replace an existing destination. |
| `filesystem_copy` | write | Copies a file or folder. The source need only be readable; only the destination must be writable. Requires `overwrite=true` to replace an existing destination. |
| `filesystem_tags_set` | write | Replaces **all** Finder tags on a file or folder with the list given. `[]` removes every tag. |
| `filesystem_trash` | **destructive** | Moves a file or folder to the Trash. Requires `confirm=true`. |

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| Foundation `FileManager` — `contentsOfDirectory`, `attributesOfItem`, `enumerator`, `createDirectory`, `moveItem`, `copyItem`, `trashItem` | Every listing, walk and write | [FileManager](https://developer.apple.com/documentation/foundation/filemanager) |
| `URLResourceValues` — `.contentTypeKey`, `.tagNamesKey`, `.creationDateKey`, `.fileSizeKey`, `.isSymbolicLinkKey` | Type, tags, dates, size, symlink detection | [URLResourceValues](https://developer.apple.com/documentation/foundation/urlresourcevalues) |
| UniformTypeIdentifiers — `UTType`, reached through `contentType` | Naming a file's type | [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers) |
| CryptoKit — `SHA256` | The short content hash on listings | [CryptoKit](https://developer.apple.com/documentation/cryptokit) |
| `NSRegularExpression` | `filesystem_grep` | [NSRegularExpression](https://developer.apple.com/documentation/foundation/nsregularexpression) |

`FileManager.removeItem` is deliberately never called: `trashItem` is the only removal route,
which is what makes Finder's Put Back work. No Spotlight query API, no PDFKit, no Vision, and
no Apple events — this server drives no app.

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

**This server reads files, not the meaning of their contents.** There is no content index,
no PDF text extraction and no OCR. `filesystem_grep` walks the files itself, which is slow,
so scope it to the smallest folder that could hold the answer — and note it stops at a cap
on files searched, bytes per file and time rather than running forever.

**Every result is bounded, and says what it left out.** A folder's items, a tree's
entries, a search's matching lines, a file's tags and the configured folders come one page
at a time, in an order the result states; a file's text comes one window of characters at
a time. When a result does not hold everything, its first lines say how much there is and
the exact arguments that return the rest: `limit` and `offset` for rows,
`character_offset` and `max_characters` for text. A number outside its range (`limit`,
`offset`, `depth`, a window) is moved to the nearest allowed value and the first lines say
which one was used; `expected_count` is refused instead, because the nearest value would
assert something else, and so is a value of the wrong type. The sizes are constants in
`ToolCatalog.swift`, which the schemas and descriptions quote. No result is longer than
`ToolStandard.longestResult`: each tool keeps to that itself, and the protocol layer cuts,
with a notice, any result that did not.

**A window is in characters; the bytes behind it are streamed.** `filesystem_read_text`
counts characters, and a character's position is only known by decoding everything before
it, so every call reads the file from its first byte. What is bounded is memory, not
reach: a UTF-8 file goes by one chunk at a time and only the window is kept, so a file of
any size can be read to its end, more slowly the larger it is. Any other encoding has to
be decoded from the whole file at once, so such a file is read only up to 16 MB.

**Every call is bounded in time.** A scan (hashing a page of a listing, walking a tree, a
grep, counting a file's characters) that takes more than 100 seconds returns what it has
and says it is partial, or says how to ask for less. A call still running after 180
seconds is abandoned and answered with an error. A read changes nothing; a write that
slow, such as a copy to another volume, is not stopped and may still finish, so look at
the destination before repeating it.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-filesystem-mcp.mcpb`. It fails loudly rather than shipping a bundle
that would silently refuse to work.

### 2. Install it

Open `dist/apple-filesystem-mcp.mcpb` with Claude. Then **quit Claude Desktop
completely and reopen it** — reinstalling does not replace a server process that is
already running, and the old one keeps answering.

### 3. Configure the read and write scopes

This server is the one deliberate exception to "nothing to configure": `read_roots` and
`write_roots` are not a preference with a sensible default,
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
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires. This
server sends no Apple events, so it needs no entitlements file to go with it.

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
- **No content index, PDF text extraction or OCR here.** `filesystem_grep` is the only
  content-matching tool, and it reads the bytes itself.
- **`filesystem_grep` stops early by design**, at 5,000 files searched or 100 seconds, and
  passes over files larger than 4.0 MB, binary files, hidden items, the insides of packages
  and anything behind a symbolic link. Its first lines say when it stopped and how many
  files it passed over. A search that stopped is not an empty one.
- **A page deep into a large tree or search costs as much as everything before it.** Each
  call walks from the start, so narrowing the folder is cheaper than a large `offset`.
  `filesystem_tree` states a total only for a tree of at most 10,000 entries.
- **Each page is a new reading.** A folder that changes between two calls can move a row
  from one page to the next.
- **A long copy outlives its answer.** `filesystem_copy`, and `filesystem_move` across
  volumes, are answered with an error after 180 seconds while the operation carries on;
  there is no call that reports on it afterwards.
- **Files above a configured hash ceiling are listed without a hash** in
  `filesystem_list`, to avoid reading a whole folder of large files just to produce a
  listing.

## Development

```bash
swift build
swift test
```

The tests never touch the disk. `PathScopeTests` runs against a modelled filesystem whose
methods throw (bar `canonicalise` and `probe`, which return values), so a scope test that
accidentally reached the real disk fails loudly rather than quietly passing. The tools
are driven against `InMemoryStore`, an invented tree held in memory; the walks, the paging
and the windows it exercises are the same pure code (`FolderScan`, `TextReader`) the real
store runs. See `CLAUDE.md`, whose first section is the hard rule that makes that
non-negotiable: no agent working in this repository may touch a file outside it.

Manual verification against real folders is the owner's job, by hand, with MCP
Inspector.

## Licence

MIT.
