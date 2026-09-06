# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move, or delete existing files outside this repository. Test files may be created but must be clearly named `TESTING: ...` and cleaned up when done.

## What this is

A local MCP server (Swift 6, stdio transport) for the filesystem: directory listing, text reading, writing and editing, `grep`, and Finder tags, all through `FileManager`. No Finder, no Apple events, no network.

Access is bounded by `read_roots` / `write_roots`, configured per install.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-filesystem-mcp | grep UsageDescription
```
