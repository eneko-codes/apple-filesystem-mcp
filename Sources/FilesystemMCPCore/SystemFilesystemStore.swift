import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The only file in this repository that touches the real disk.
///
/// Everything above the `FilesystemStore` seam is proven against an in-memory tree. This
/// is the part that cannot be, so it is kept as thin as it can be: no policy, no
/// formatting, no decisions about what is allowed — those all happen above, and by the
/// time a `ScopedPath` reaches any method here it has already passed the allow-list.
public struct SystemFilesystemStore: FilesystemStore {

    /// Computed rather than stored: `FileManager` is not `Sendable`, so it cannot be held
    /// by a type that is. The shared instance is the only one documented as safe to use
    /// from several threads, and nothing here ever wanted a different one.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Resolution

    /// Expands `~`, standardises away `.` and `..`, and resolves every symlink.
    ///
    /// A missing leaf is normal — a write target usually does not exist yet — so
    /// resolution walks up to the deepest ancestor that does exist, canonicalises that,
    /// and re-appends the components below it. Canonicalising only what exists is what
    /// stops a symlinked parent from hiding the real destination from the scope check.
    public func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        // A relative path has no meaning here: the process's working directory is
        // whatever Claude Desktop happened to spawn it in, which is nobody's intent.
        guard expanded.hasPrefix("/") else {
            throw ToolError.badArgument(
                name: "path",
                reason: "'\(path)' is not absolute. Give a full path, or one starting with ~")
        }

        let standardised = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: standardised.path) {
            return CanonicalPath(path: standardised.resolvingSymlinksInPath().path, exists: true)
        }

        var missing: [String] = []
        var ancestor = standardised
        while ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
            if fileManager.fileExists(atPath: ancestor.path) {
                let resolved = missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
                    $0.appendingPathComponent($1)
                }
                return CanonicalPath(path: resolved.path, exists: false)
            }
        }
        return CanonicalPath(path: standardised.path, exists: false)
    }

    // MARK: - Status

    public func probe(_ path: String) -> RootState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return fileManager.isReadableFile(atPath: path) ? .reachable : .notPermitted
        }
        // The only honest test of a TCC-protected folder is to open it: the path exists
        // and is perfectly visible, and the refusal only arrives on the first read.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return .reachable
        } catch {
            return Self.isPermissionError(error) ? .notPermitted : .missing
        }
    }

    // MARK: - Reads

    public func list(_ path: ScopedPath, includeHidden: Bool, hashCeilingBytes: Int) throws
        -> [FileEntry]
    {
        let url = URL(fileURLWithPath: path.path)
        guard try isDirectory(url) else { throw ToolError.notADirectory(path: path.path) }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(Self.entryKeys),
                options: includeHidden ? [] : [.skipsHiddenFiles])
        } catch {
            throw mapError(error, path: path.path)
        }
        return
            children
            .map { entry(at: $0, hashCeilingBytes: hashCeilingBytes) }
            .sorted { lhs, rhs in
                // Folders first, then by name: the shape of a folder is easier to read
                // when its structure is not interleaved with its contents.
                if (lhs.kind == .directory) != (rhs.kind == .directory) {
                    return lhs.kind == .directory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public func stat(_ path: ScopedPath, hashCeilingBytes: Int) throws -> FileStat {
        let url = URL(fileURLWithPath: path.path)
        guard fileManager.fileExists(atPath: path.path) || isSymbolicLink(url) else {
            throw ToolError.notFound(path: path.path)
        }
        let entry = entry(at: url, hashCeilingBytes: hashCeilingBytes)

        let values = try? url.resourceValues(forKeys: [
            .creationDateKey, .contentTypeKey, .localizedTypeDescriptionKey, .tagNamesKey,
        ])
        let attributes = try? fileManager.attributesOfItem(atPath: path.path)

        var childCount: Int?
        if entry.kind == .directory {
            childCount = (try? fileManager.contentsOfDirectory(atPath: path.path))?.count
        }

        return FileStat(
            entry: entry,
            createdAt: values?.creationDate,
            contentTypeIdentifier: values?.contentType?.identifier,
            kindDescription: values?.localizedTypeDescription,
            ownerName: attributes?[.ownerAccountName] as? String,
            posixPermissions: (attributes?[.posixPermissions] as? NSNumber)?.intValue,
            isReadableByProcess: fileManager.isReadableFile(atPath: path.path),
            isWritableByProcess: fileManager.isWritableFile(atPath: path.path),
            symlinkDestination: try? fileManager.destinationOfSymbolicLink(atPath: path.path),
            childCount: childCount,
            tags: values?.tagNames ?? [])
    }

    public func tree(
        _ path: ScopedPath, maximumDepth: Int, includeHidden: Bool, entryLimit: Int
    ) throws -> FileTree {
        let root = URL(fileURLWithPath: path.path)
        guard try isDirectory(root) else { throw ToolError.notADirectory(path: path.path) }

        var nodes: [FileTree.Node] = []
        var truncated = false

        func walk(_ directory: URL, depth: Int) {
            guard depth <= maximumDepth, !truncated else { return }
            let children =
                (try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(Self.entryKeys),
                    options: includeHidden ? [] : [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }) {
                guard nodes.count < entryLimit else {
                    truncated = true
                    return
                }
                // No hashing in a tree: it would mean reading every byte under the root,
                // which is a different order of cost from listing names. filesystem_list
                // is where a row carries a hash.
                let child = entry(at: child, hashCeilingBytes: 0)
                nodes.append(FileTree.Node(entry: child, depth: depth - 1))
                if child.kind == .directory {
                    walk(URL(fileURLWithPath: child.path), depth: depth + 1)
                }
            }
        }
        walk(root, depth: 1)
        return FileTree(root: path.path, nodes: nodes, truncated: truncated)
    }

    public func readText(_ path: ScopedPath, maximumBytes: Int) throws -> TextContent {
        let url = URL(fileURLWithPath: path.path)
        guard fileManager.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }
        guard try !isDirectory(url) else { throw ToolError.notAFile(path: path.path) }

        let total = (try? fileManager.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw mapError(error, path: path.path)
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        guard let decoded = Self.decode(data, truncated: data.count < (total ?? 0)) else {
            throw ToolError.undecodableText(path: path.path)
        }
        return TextContent(
            text: decoded.text, encodingName: decoded.encodingName, bytesRead: data.count,
            totalBytes: total ?? data.count)
    }

    public func grep(
        _ scope: ScopedPath, pattern: String, ignoreCase: Bool, namePattern: String?,
        maximumMatches: Int, maximumFiles: Int, maximumFileBytes: Int
    ) throws -> GrepPage {
        let root = URL(fileURLWithPath: scope.path)
        guard try isDirectory(root) else { throw ToolError.notADirectory(path: scope.path) }

        let expression = try NSRegularExpression(
            pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        let nameExpression = try namePattern.map {
            try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }

        var matches: [GrepPage.Match] = []
        var scanned = 0
        var skipped = 0
        var truncated = false

        let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        while let url = enumerator?.nextObject() as? URL {
            if matches.count >= maximumMatches || scanned >= maximumFiles {
                truncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            if let nameExpression {
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard nameExpression.firstMatch(in: name, range: range) != nil else { continue }
            }
            guard (values?.fileSize ?? 0) <= maximumFileBytes else {
                skipped += 1
                continue
            }
            guard let data = try? Data(contentsOf: url), !Self.looksBinary(data),
                let text = Self.decode(data, truncated: false)?.text
            else {
                skipped += 1
                continue
            }
            scanned += 1

            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                guard matches.count < maximumMatches else {
                    truncated = true
                    break
                }
                let candidate = String(line)
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                if expression.firstMatch(in: candidate, range: range) != nil {
                    matches.append(
                        GrepPage.Match(path: url.path, lineNumber: index + 1, line: candidate))
                }
            }
        }

        return GrepPage(
            matches: matches, filesScanned: scanned, filesSkipped: skipped, truncated: truncated)
    }

    public func tags(of path: ScopedPath) throws -> [String] {
        guard fileManager.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }
        let url = URL(fileURLWithPath: path.path)
        do {
            return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        } catch {
            throw mapError(error, path: path.path)
        }
    }

    // MARK: - Writes

    public func write(_ text: String, to path: ScopedPath, append: Bool) throws -> WriteOutcome {
        let url = URL(fileURLWithPath: path.path)
        let existed = fileManager.fileExists(atPath: path.path)
        let previous = existed ? (try? fileManager.attributesOfItem(atPath: path.path)[.size]) : nil
        let data = Data(text.utf8)

        do {
            if append, existed {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw mapError(error, path: path.path)
        }

        return WriteOutcome(
            path: path.path, bytesWritten: data.count, created: !existed,
            previousSizeBytes: (previous as? Int))
    }

    public func edit(
        _ path: ScopedPath, find: String, replace: String, expectedCount: Int
    ) throws -> EditOutcome {
        let url = URL(fileURLWithPath: path.path)
        guard fileManager.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw mapError(error, path: path.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.undecodableText(path: path.path)
        }

        // Counted before anything is written, and the file is left untouched when the
        // count is not what the caller expected. An edit meant for one place must not
        // silently hit five.
        let occurrences = Self.count(of: find, in: text)
        guard occurrences > 0 else {
            throw ToolError.editTextNotFound(path: path.path, find: find)
        }
        guard occurrences == expectedCount else {
            throw ToolError.editTextAmbiguous(path: path.path, find: find, found: occurrences)
        }

        let updated = text.replacingOccurrences(of: find, with: replace)
        let output = Data(updated.utf8)
        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw mapError(error, path: path.path)
        }
        return EditOutcome(
            path: path.path, replacements: occurrences, bytesWritten: output.count)
    }

    public func makeDirectory(_ path: ScopedPath, createIntermediates: Bool) throws -> FileStat {
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path.path),
                withIntermediateDirectories: createIntermediates)
        } catch {
            // An existing folder is the outcome that was asked for, so it is not an error.
            let alreadyThere =
                (error as NSError).code == NSFileWriteFileExistsError
                && (try? isDirectory(URL(fileURLWithPath: path.path))) == true
            if !alreadyThere { throw mapError(error, path: path.path) }
        }
        return try stat(path, hashCeilingBytes: 0)
    }

    public func move(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    {
        let replaced = try clearDestination(destination, overwrite: overwrite)
        do {
            try fileManager.moveItem(
                at: URL(fileURLWithPath: source.path),
                to: URL(fileURLWithPath: destination.path))
        } catch {
            throw mapError(error, path: destination.path)
        }
        return TransferOutcome(
            from: source.path, to: destination.path, replacedExisting: replaced)
    }

    public func copy(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    {
        let replaced = try clearDestination(destination, overwrite: overwrite)
        do {
            try fileManager.copyItem(
                at: URL(fileURLWithPath: source.path),
                to: URL(fileURLWithPath: destination.path))
        } catch {
            throw mapError(error, path: destination.path)
        }
        return TransferOutcome(
            from: source.path, to: destination.path, replacedExisting: replaced)
    }

    public func setTags(_ tags: [String], on path: ScopedPath) throws -> [String] {
        guard fileManager.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }
        var url = URL(fileURLWithPath: path.path)
        var values = URLResourceValues()
        values.tagNames = tags
        do {
            try url.setResourceValues(values)
        } catch {
            throw mapError(error, path: path.path)
        }
        return (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) as? [String] ?? tags
    }

    public func trash(_ path: ScopedPath) throws -> TrashOutcome {
        var landed: NSURL?
        do {
            // trashItem, never removeItem. There is no code path in this repository that
            // deletes a file, and adding one would break the promise the tool description
            // makes.
            try fileManager.trashItem(at: URL(fileURLWithPath: path.path), resultingItemURL: &landed)
        } catch {
            throw mapError(error, path: path.path)
        }
        return TrashOutcome(
            originalPath: path.path, trashPath: (landed as URL?)?.path)
    }

    // MARK: - Helpers

    private static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .isHiddenKey, .nameKey,
    ]

    private func isDirectory(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError.notFound(path: url.path)
        }
        return isDirectory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func entry(at url: URL, hashCeilingBytes: Int) -> FileEntry {
        let values = try? url.resourceValues(forKeys: Self.entryKeys)
        let size = values?.fileSize ?? 0

        let kind: FileKind
        if values?.isSymbolicLink == true {
            // A symlink that resolves is reported as whatever it points at, because that
            // is what reading it would give you. Only a dangling one is worth flagging.
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                kind = isDirectory.boolValue ? .directory : .file
            } else {
                kind = .brokenSymlink
            }
        } else if values?.isDirectory == true {
            kind = .directory
        } else if values?.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }

        var hash: String?
        var hashNote: String?
        if kind == .file, hashCeilingBytes > 0 {
            if size > hashCeilingBytes {
                hashNote = "too large to hash"
            } else {
                hash = Self.contentHash(of: url)
                if hash == nil { hashNote = "unreadable" }
            }
        }

        return FileEntry(
            path: url.path, name: values?.name ?? url.lastPathComponent, kind: kind,
            sizeBytes: size, modifiedAt: values?.contentModificationDate,
            isHidden: values?.isHidden ?? false, contentHash: hash, hashNote: hashNote)
    }

    /// First 16 hex characters of the file's SHA-256, read in chunks so a large file does
    /// not have to fit in memory to be identified.
    static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// A NUL byte in the first few kilobytes is how every text tool has told binary from
    /// text for fifty years, and it is right often enough to be the rule here too.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8_000).contains(0)
    }

    /// UTF-8 first, then a byte-order mark, then whatever `NSString` guesses, then Latin-1
    /// as the encoding that can decode any byte sequence at all.
    ///
    /// A truncated read can cut a multi-byte character in half, so up to three trailing
    /// bytes are dropped before giving up on UTF-8 — otherwise a byte cap in the middle of
    /// an accented word would report the whole file as undecodable.
    static func decode(_ data: Data, truncated: Bool) -> (text: String, encodingName: String)? {
        guard !looksBinary(data) else { return nil }

        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        if truncated {
            for trim in 1...3 where data.count > trim {
                if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                    return (text, "UTF-8")
                }
            }
        }

        let bom = Array(data.prefix(2))
        if bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF],
            let text = String(data: data, encoding: .utf16)
        {
            return (text, "UTF-16")
        }

        var converted: NSString?
        let guessed = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted,
            usedLossyConversion: nil)
        if guessed != 0, let converted {
            return (converted as String, String.localizedName(of: String.Encoding(rawValue: guessed)))
        }

        if let text = String(data: data, encoding: .isoLatin1) { return (text, "ISO Latin 1") }
        if let text = String(data: data, encoding: .macOSRoman) { return (text, "Mac OS Roman") }
        return nil
    }

    /// Non-overlapping occurrences, which is what `replacingOccurrences` will replace.
    /// Counting any other way would make the expected-count guard disagree with the edit
    /// it is guarding.
    static func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Returns whether something was removed. An existing destination is moved to the
    /// Trash rather than deleted, so "overwrite" still leaves the old copy recoverable.
    private func clearDestination(_ destination: ScopedPath, overwrite: Bool) throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else { return false }
        guard overwrite else { throw ToolError.alreadyExists(path: destination.path) }
        do {
            try fileManager.trashItem(
                at: URL(fileURLWithPath: destination.path), resultingItemURL: nil)
        } catch {
            throw mapError(error, path: destination.path)
        }
        return true
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }

    /// Turns a Cocoa error into one that says how to fix it. A raw
    /// "Operation not permitted" is the single most confusing thing this server can emit,
    /// because it looks like a bug in the allow-list and is actually TCC.
    private func mapError(_ error: Error, path: String) -> ToolError {
        if let toolError = error as? ToolError { return toolError }
        if Self.isPermissionError(error) {
            return .permissionDenied(path: path, detail: error.localizedDescription)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return .notFound(path: path)
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteFileExistsError {
            return .alreadyExists(path: path)
        }
        return .storeFailure(error.localizedDescription)
    }
}
