import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func padLeft(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? String(repeating: " ", count: shortfall) + text : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Binary units, because that is what the Finder's Get Info shows for a file and a
    /// mismatch between the two is the kind of thing that costs half an hour.
    public static func bytes(_ count: Int) -> String {
        guard count >= 1024 else { return "\(count) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(count) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// A one-line stand-in for a passage of text, for error messages that have to quote
    /// what the caller asked for without pasting a whole file back at them.
    public static func excerpt(_ text: String) -> String {
        ToolStandard.echo(text.replacingOccurrences(of: "\n", with: "⏎"))
    }

    /// What an empty page says: nothing is there, or the offset skipped everything.
    static func nothing(_ none: String, total: Int) -> String {
        "\n\n  " + (total == 0 ? none : "(nothing at this offset)")
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// A list of tags as one field of a larger result, cut to the width such a field may
    /// take. `isClipped` tells the caller to say so before the data.
    static func tagsField(_ tags: [String]) -> (text: String, isClipped: Bool) {
        let joined = tags.map(oneLine).joined(separator: ", ")
        guard joined.count > ToolCatalog.tagsFieldWidth else { return (joined, false) }
        return (String(joined.prefix(ToolCatalog.tagsFieldWidth)) + "…", true)
    }

    /// Collapses a multi-line value onto one line, so the one-row-per-file contract that
    /// makes a listing scannable survives a filename containing a newline — which is
    /// legal on APFS and does happen.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func kindMark(_ kind: FileKind) -> String {
        switch kind {
        case .directory: return "dir "
        case .file: return "file"
        case .brokenSymlink: return "link"
        case .other: return "othr"
        }
    }

    // MARK: Listings

    /// One row per entry, columns aligned, newest-relevant fields last. The hash is here
    /// so duplicate hunting is Claude's job over raw rows — there is deliberately no
    /// find_duplicates tool, because "how similar is a duplicate" is a judgement.
    ///
    /// `entries` is the page to show; `total` counts every item the listing holds.
    public func entries(_ entries: [FileEntry], total: Int, root: String) -> String {
        let header =
            "Contents of \(root): \(Self.plural(total, "item", "items")), folders first, then by name."
        guard !entries.isEmpty else { return header + Self.nothing("(empty)", total: total) }

        let nameWidth = min(entries.map { Self.oneLine($0.name).count }.max() ?? 4, 60)
        let sizeWidth = entries.map { Self.bytes($0.sizeBytes).count }.max() ?? 6

        let rows = entries.map { entry -> String in
            let name = Self.oneLine(entry.name)
            var row =
                "  \(Self.kindMark(entry.kind))  \(Self.pad(name, to: nameWidth))  "
                + Self.padLeft(
                    entry.kind == .directory ? "-" : Self.bytes(entry.sizeBytes), to: sizeWidth)
            if let modified = entry.modifiedAt {
                row += "  " + DateParsing.timestamp(modified, calendar: calendar)
            }
            if let hash = entry.contentHash {
                row += "  " + hash
            } else if let note = entry.hashNote {
                row += "  (" + note + ")"
            }
            return row
        }
        return (
            [header, "Columns: kind, name, size, modified, sha256 (first 16 hex characters).", ""]
                + rows
        ).joined(separator: "\n")
    }

    /// `nodes` is the page to show, which starts `offset` entries into the walk.
    public func tree(_ tree: FileTree, nodes: [FileTree.Node], offset: Int) -> String {
        let size: String
        if let total = tree.total {
            size = Self.plural(total, "entry", "entries")
        } else if tree.stoppedForTime {
            size = "at least \(Self.plural(tree.walked, "entry", "entries"))"
        } else {
            size = "more than \(Self.plural(tree.walked, "entry", "entries"))"
        }
        let header =
            "Tree of \(tree.root), \(Self.plural(tree.maximumDepth, "level", "levels")) deep: \(size). "
            + "Each folder's items are in name order, and a folder is followed by what it holds."
        guard !nodes.isEmpty else {
            return header + Self.nothing("(empty)", total: tree.walked)
        }
        let rows = nodes.map { node -> String in
            let indent = String(repeating: "  ", count: node.depth)
            let name = Self.oneLine(node.entry.name)
            let suffix =
                node.entry.kind == .directory ? "/" : "  \(Self.bytes(node.entry.sizeBytes))"
            return "  \(indent)\(name)\(suffix)"
        }
        return ([header, ""] + rows).joined(separator: "\n")
    }

    public func stat(_ stat: FileStat) -> String {
        let entry = stat.entry
        var rows: [(String, String?)] = [
            ("path", entry.path),
            ("kind", entry.kind.rawValue),
            ("type", stat.kindDescription),
            ("uti", stat.contentTypeIdentifier),
            ("size", entry.kind == .directory ? nil : Self.bytes(entry.sizeBytes)),
            ("bytes", entry.kind == .directory ? nil : "\(entry.sizeBytes)"),
            ("sha256", entry.contentHash ?? entry.hashNote.map { "(\($0))" }),
            ("children", stat.childCount.map { "\($0)" }),
            ("created", stat.createdAt.map { DateParsing.timestamp($0, calendar: calendar) }),
            ("modified", entry.modifiedAt.map { DateParsing.timestamp($0, calendar: calendar) }),
            ("owner", stat.ownerName),
            ("mode", stat.posixPermissions.map { String(format: "%03o", $0) }),
            ("symlink to", stat.symlinkDestination),
            ("hidden", entry.isHidden ? "yes" : nil),
            ("tags", stat.tags.isEmpty ? nil : Self.tagsField(stat.tags).text),
        ]
        // What this process can actually do with the file, which is a different question
        // from what the allow-list permits and is worth separating in the answer.
        rows.append(
            (
                "access",
                "\(stat.isReadableByProcess ? "readable" : "NOT readable") · "
                    + "\(stat.isWritableByProcess ? "writable" : "not writable") by this process"
            ))
        return Self.block(rows)
    }

    // MARK: Content

    /// `part` is the window to show, cut from `window.text`.
    public func text(_ part: String, of window: TextWindow, path: String) -> String {
        // When the time ran out the file was only read as far as `totalBytes`, so what is
        // known about its length is a lower bound.
        let size =
            window.isWholeFile
            ? Self.bytes(window.totalBytes) : "read as far as \(Self.bytes(window.totalBytes))"
        let counted = Self.plural(window.totalCharacters, "character", "characters")
        let header =
            "\(path)\n  \(window.encodingName) · \(size) · "
            + (window.isWholeFile ? counted : "at least \(counted)")
        return header + (window.totalCharacters == 0 ? "\n\n  (empty file)" : "\n\n" + part)
    }

    /// `matches` is the page to show, which starts `offset` matches into the scan.
    public func grep(
        _ page: GrepPage, matches: [GrepPage.Match], offset: Int, pattern: String, scope: String
    ) -> String {
        let files = Self.plural(page.filesSearched, "file", "files")
        let found = Self.plural(page.matchesFound, "match", "matches")
        var header = "/\(ToolStandard.echo(pattern))/ in \(scope): "
        switch page.stop {
        case .finished: header += "\(found) in \(files)."
        case .pageFull: header += "more than \(found); \(files) searched so far."
        case .fileCeiling, .timeLimit:
            header += "\(found) in the \(files) searched before the scan stopped."
        }
        header += " Files are searched in the order \(ToolCatalog.treeName) walks them."
        guard !matches.isEmpty else {
            return header + Self.nothing("(no matches)", total: page.matchesFound)
        }
        if offset > 0 { header += " Matches \(offset + 1)–\(offset + matches.count) follow." }
        let rows = matches.map { match in
            "  \(Self.oneLine(match.path)):\(match.lineNumber)\n      "
                + Self.oneLine(match.line) + (match.isClipped ? "…" : "")
        }
        return ([header, ""] + rows).joined(separator: "\n")
    }

    /// `tags` is the page to show; `total` counts every tag on the item.
    public func tags(_ tags: [String], total: Int, path: String) -> String {
        let header = "\(path): \(Self.plural(total, "Finder tag", "Finder tags")), in the order Finder keeps them."
        guard !tags.isEmpty else { return header + Self.nothing("(no Finder tags)", total: total) }
        return header + "\n\n" + tags.map { "  \(Self.oneLine($0))" }.joined(separator: "\n")
    }

    // MARK: Writes

    public func wrote(_ outcome: WriteOutcome, appended: Bool) -> String {
        let verb = outcome.created ? "Created" : (appended ? "Appended to" : "Replaced")
        var rows: [(String, String?)] = [
            ("path", outcome.path),
            ("written", Self.bytes(outcome.bytesWritten)),
        ]
        if let previous = outcome.previousSizeBytes, !outcome.created {
            rows.append(("previous size", Self.bytes(previous)))
        }
        return "\(verb) \(outcome.path)\n\n" + Self.block(rows)
    }

    public func edited(_ outcome: EditOutcome) -> String {
        """
        Replaced \(outcome.replacements) occurrence\(outcome.replacements == 1 ? "" : "s") \
        in \(outcome.path)

        """ + Self.block([("path", outcome.path), ("new size", Self.bytes(outcome.bytesWritten))])
    }

    public func madeDirectory(_ stat: FileStat) -> String {
        "Created folder \(stat.entry.path)\n\n" + self.stat(stat)
    }

    public func transferred(_ outcome: TransferOutcome, verb: String) -> String {
        var rows: [(String, String?)] = [("from", outcome.from), ("to", outcome.to)]
        if outcome.replacedExisting {
            rows.append(("note", "an existing item at the destination was replaced"))
        }
        return "\(verb):\n\n" + Self.block(rows)
    }

    public func setTags(_ tags: [String], path: String) -> String {
        let value = tags.isEmpty ? "(none — all tags removed)" : Self.tagsField(tags).text
        return "Tags set on \(path)\n\n" + Self.block([("tags", value)])
    }

    public func trashed(_ outcome: TrashOutcome) -> String {
        """
        Moved to the Trash — NOT deleted.

        """
            + Self.block([
                ("was at", outcome.originalPath),
                ("now at", outcome.trashPath ?? "(the Trash; macOS did not report the new path)"),
            ])
            + """


            Put it back from the Finder with File → Put Back, or move it out of the Trash
            by hand. This server has no delete: nothing it removes is unrecoverable.
            """
    }

    // MARK: Status

    /// `rows` is the page of configured folders to show; `all` is every one of them, which
    /// the headline and the warnings are about.
    public func status(
        rows: [RootProbe], all: [RootProbe], binaryPath: String, configuration: Configuration
    ) -> String {
        let readCount = all.filter { $0.access == .read }.count
        let writeCount = all.filter { $0.access == .write }.count

        let headline: String
        if readCount == 0 {
            headline = "Filesystem scope: NOTHING configured — this server can see no files."
        } else if writeCount == 0 {
            headline = "Filesystem scope: READ-ONLY — \(readCount) read root(s), no write root."
        } else {
            headline = "Filesystem scope: \(readCount) read root(s), \(writeCount) write root(s)."
        }

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("time zone", calendar.timeZone.identifier),
            ("max hashed file", Self.bytes(configuration.maximumHashBytes)),
        ])

        text += "\n\nConfigured folders: \(all.count), the readable ones first and then the"
        text += " writable ones, each list in the order it was configured."
        if readCount == 0 { text += "\n  (no readable folder configured — nothing is reachable)" }
        if writeCount == 0 { text += "\n  (no writable folder configured — the server is read-only)" }
        if rows.isEmpty {
            if !all.isEmpty { text += "\n  (nothing at this offset)" }
        } else {
            text += "\n" + rows.map { probe in
                var line = "  \(Self.pad(probe.access.rawValue, to: 5))  \(probe.path) — \(probe.state.rawValue)"
                if probe.isStranded { line += " — STRANDED: outside every readable folder" }
                if let canonical = probe.canonicalPath { line += "\n      resolves to \(canonical)" }
                return line
            }.joined(separator: "\n")
        }

        let stranded = all.filter(\.isStranded).count
        if stranded > 0 {
            text += """


                WARNING — \(Self.plural(stranded, "write root lies", "write roots lie")) outside \
                every read root and so \(stranded == 1 ? "governs" : "govern") nothing: a write \
                has to satisfy the read check too. Each is marked STRANDED in the list. Add \
                them to the readable list as well, or remove them.
                """
        }

        if all.contains(where: { $0.state == .notPermitted }) {
            text += """


                One or more roots are configured but macOS refuses them. That is a system
                permission, not this server's allow-list:
                  System Settings → Privacy & Security → Files and Folders → enable the folders
                  under "apple-filesystem-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)
                Anywhere outside Desktop, Documents and Downloads needs Full Disk Access
                instead, which is granted by hand and never prompts.
                """
        }
        return text
    }
}
