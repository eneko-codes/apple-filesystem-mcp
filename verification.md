# Manual verification

Everything below runs against **your real files**, which is why no agent may run it (see the
hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-filesystem-mcp
```

## 0 — Before you start

Build a sandbox you can delete afterwards:

```bash
mkdir -p ~/Documents/ZZTest/Scratch ~/Documents/ZZTest/ReadOnly
printf 'the quick brown fox\nsecond line\n' > ~/Documents/ZZTest/ReadOnly/notes.txt
printf 'tide tables for August\n' > ~/Documents/ZZTest/ReadOnly/tides.md
ln -s ~/Library ~/Documents/ZZTest/escape-hatch
```

Configure the extension with:

- **read roots:** `~/Documents/ZZTest`
- **write roots:** `~/Documents/ZZTest/Scratch`

Restart Claude Desktop. Delete the whole `ZZTest` folder when you finish, symlink included.

## 1 — Status and the folder prompts

| Step | Call | Expected |
|---|---|---|
| 1.1 | `filesystem_status` | Both roots listed, each canonicalised, each probed as reachable. |
| 1.2 | First call touching `~/Documents` | macOS asks for Documents access, quoting the usage description. |
| 1.3 | Deny it, then `filesystem_list` | Refused, naming System Settings → Privacy & Security → Files and Folders. |
| 1.4 | Re-grant, restart, `filesystem_status` | Reachable again. |

## 2 — The boundary, which is the whole point

Every one of these must be **refused**. If any succeeds, stop.

| Step | Call | Expected |
|---|---|---|
| 2.1 | `filesystem_read_text` on `~/Documents/ZZTest/../../.ssh/config` | Refused as out of scope, showing the resolved path. |
| 2.2 | `filesystem_read_text` on `~/Library/Preferences/com.apple.finder.plist` | Refused. |
| 2.3 | `filesystem_list` on `~/Documents/ZZTest/escape-hatch` | **Refused** — the symlink resolves to `~/Library`, which is outside the read root. |
| 2.4 | `filesystem_read_text` on `~/Documents/ZZTest-private/anything` | Refused. A shared name prefix is not containment. |
| 2.5 | `filesystem_write` to `~/Documents/ZZTest/ReadOnly/notes.txt` | **Refused** — readable is not writable. |
| 2.6 | `filesystem_trash` on `~/Documents/ZZTest/ReadOnly/tides.md` | Refused, same reason. |

Step 2.3 is the one that would be quietly wrong if canonicalisation happened after
comparison rather than before. Step 2.5 is the read/write asymmetry the server exists for.

## 3 — Reads inside scope

| Step | Call | Expected |
|---|---|---|
| 3.1 | `filesystem_list` on `~/Documents/ZZTest` | Both subfolders; each row carries a size and a content hash. |
| 3.2 | `filesystem_stat` on `notes.txt` | Size, dates, type. |
| 3.3 | `filesystem_tree` with a small depth | Stops at that depth and says so. |
| 3.4 | `filesystem_read_text` on `notes.txt` | Both lines. |
| 3.5 | `filesystem_read_text` with a tiny byte cap | Truncated, and the response says it was. |
| 3.6 | `filesystem_grep` for `brown` | Matches `notes.txt` with a line number. |
| 3.7 | `filesystem_read_text` on a binary file | Fails clearly, not with mojibake. |
| 3.8 | `filesystem_read_text` on a PDF | Refused, pointing at apple-pdf-mcp's `pdf_read`. |

## 4 — Writes, inside the write root only

| Step | Call | Expected |
|---|---|---|
| 4.1 | `filesystem_write` to `~/Documents/ZZTest/Scratch/new.txt` | Created. |
| 4.2 | `filesystem_write` again with append | Appended, not replaced. |
| 4.3 | `filesystem_edit` replacing a string that appears once | Replaced; the count is reported. |
| 4.4 | `filesystem_edit` replacing a string that appears twice, expecting one | Refused rather than replacing both. |
| 4.5 | `filesystem_mkdir` under `Scratch` | Created. |
| 4.6 | `filesystem_copy` from `ReadOnly/notes.txt` into `Scratch` | Works — read from one root, write to the other. |
| 4.7 | `filesystem_move` from `Scratch` to `ReadOnly` | **Refused** — the destination is not writable. |
| 4.8 | `filesystem_tags_set` on a file in `Scratch`, then `filesystem_tags_get` | Tag round-trips; visible in Finder. |
| 4.9 | `filesystem_trash` a file in `Scratch` | Gone from the folder, **present in the Trash**. |

Step 4.9 is the one to confirm visually. Nothing in this server should ever be
unrecoverable.

## 5 — Packaging

| Step | Command | Expected |
|---|---|---|
| 5.1 | `otool -P .build/release/apple-filesystem-mcp \| grep UsageDescription` | Desktop, Documents and Downloads keys present. |
| 5.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 5.3 | `codesign -dv extension/server/apple-filesystem-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 5.4 | Install, restart Claude Desktop | Fourteen switches appear, one per tool. |

## 6 — Clean up

```bash
rm -rf ~/Documents/ZZTest
```

Then set the real scopes deliberately. The read list can be generous; keep the write list
small, and inside the read list — `filesystem_status` will tell you if a write root is
stranded outside it.
