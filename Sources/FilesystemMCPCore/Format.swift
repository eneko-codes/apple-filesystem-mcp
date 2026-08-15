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
    public static func excerpt(_ text: String, limit: Int = 120) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: "⏎")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
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
    public func entries(_ entries: [FileEntry], root: String, header: String) -> String {
        guard !entries.isEmpty else {
            return "\(header)\n\n  (empty)"
        }
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
        return ([header, ""] + rows).joined(separator: "\n")
            + "\n\n  \(entries.count) entr\(entries.count == 1 ? "y" : "ies") in \(root)"
            + "\n  Columns: kind, name, size, modified, sha256 (first 16 hex chars)."
    }

    public func tree(_ tree: FileTree) -> String {
        var lines = ["Tree of \(tree.root)", ""]
        for node in tree.nodes {
            let indent = String(repeating: "  ", count: node.depth)
            let name = Self.oneLine(node.entry.name)
            let suffix =
                node.entry.kind == .directory ? "/" : "  \(Self.bytes(node.entry.sizeBytes))"
            lines.append("  \(indent)\(name)\(suffix)")
        }
        if tree.nodes.isEmpty { lines.append("  (empty)") }
        lines.append("")
        lines.append("  \(tree.nodes.count) entries")
        if tree.truncated {
            lines.append(
                """
                  TRUNCATED — the entry ceiling stopped the walk, so this is a partial
                  picture. Lower 'depth', or walk a subfolder.
                """)
        }
        return lines.joined(separator: "\n")
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
            ("tags", stat.tags.isEmpty ? nil : stat.tags.joined(separator: ", ")),
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

    public func text(_ content: TextContent, path: String) -> String {
        var header = "\(path)\n  \(content.encodingName) · \(Self.bytes(content.totalBytes))"
        if content.truncated {
            header +=
                "\n  TRUNCATED at \(Self.bytes(content.bytesRead)) — raise 'max_bytes' for more."
        }
        return header + "\n\n" + content.text
    }

    public func grep(_ page: GrepPage, pattern: String, scope: String) -> String {
        var header =
            "/\(pattern)/ in \(scope)\n  \(page.matches.count) match"
            + "\(page.matches.count == 1 ? "" : "es") · \(page.filesScanned) files scanned"
        if page.filesSkipped > 0 {
            header += " · \(page.filesSkipped) skipped (binary or too large)"
        }
        guard !page.matches.isEmpty else {
            return header + "\n\n  (no matches)"
        }
        let rows = page.matches.map { match in
            "  \(Self.oneLine(match.path)):\(match.lineNumber)\n      "
                + Self.excerpt(match.line.trimmingCharacters(in: .whitespaces), limit: 300)
        }
        var text = ([header, ""] + rows).joined(separator: "\n")
        if page.truncated {
            text += "\n\n  TRUNCATED — the match ceiling stopped the walk. Narrow the pattern or the folder."
        }
        return text
    }

    public func tags(_ tags: [String], path: String) -> String {
        guard !tags.isEmpty else { return "\(path)\n\n  (no Finder tags)" }
        return "\(path)\n\n" + tags.map { "  \($0)" }.joined(separator: "\n")
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
        let value = tags.isEmpty ? "(none — all tags removed)" : tags.joined(separator: ", ")
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

    public func status(
        probes: [RootProbe], binaryPath: String,
        configuration: Configuration, strandedWriteRoots: [String]
    ) -> String {
        let readProbes = probes.filter { $0.access == .read }
        let writeProbes = probes.filter { $0.access == .write }

        let headline: String
        if readProbes.isEmpty {
            headline = "Filesystem scope: NOTHING configured — this server can see no files."
        } else if writeProbes.isEmpty {
            headline = "Filesystem scope: READ-ONLY — \(readProbes.count) read root(s), no write root."
        } else {
            headline =
                "Filesystem scope: \(readProbes.count) read root(s), \(writeProbes.count) write root(s)."
        }

        func render(_ probes: [RootProbe]) -> String {
            probes.map { probe in
                var line = "  \(probe.path) — \(probe.state.rawValue)"
                if let canonical = probe.canonicalPath { line += "\n      resolves to \(canonical)" }
                return line
            }.joined(separator: "\n")
        }

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("time zone", calendar.timeZone.identifier),
            ("max text read", Self.bytes(configuration.maximumReadBytes)),
            ("max hashed file", Self.bytes(configuration.maximumHashBytes)),
        ])

        text += "\n\nReadable folders:\n"
        text += readProbes.isEmpty ? "  (none configured — nothing is reachable)" : render(readProbes)
        text += "\n\nWritable folders:\n"
        text +=
            writeProbes.isEmpty
            ? "  (none configured — the server is read-only)" : render(writeProbes)

        if !strandedWriteRoots.isEmpty {
            text += """


                WARNING — these write roots lie outside every read root, so they govern
                nothing: a write has to satisfy the read check too.
                  \(strandedWriteRoots.joined(separator: "\n  "))
                Add them to the readable list as well, or remove them.
                """
        }

        if probes.contains(where: { $0.state == .notPermitted }) {
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
