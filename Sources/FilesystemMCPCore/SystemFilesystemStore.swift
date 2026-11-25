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

    public func list(
        _ path: ScopedPath, includeHidden: Bool, hashCeilingBytes: Int, limit: Int, offset: Int,
        expired: () -> Bool
    ) throws -> FileListing {
        FolderScan.listing(
            children: try folder(path), includeHidden: includeHidden, limit: limit,
            offset: offset, expired: expired
        ) { hashed($0, ceilingBytes: hashCeilingBytes) }
    }

    public func stat(_ path: ScopedPath, hashCeilingBytes: Int) throws -> FileStat {
        let url = URL(fileURLWithPath: path.path)
        guard fileManager.fileExists(atPath: path.path) || isSymbolicLink(url) else {
            throw ToolError.notFound(path: path.path)
        }
        let entry = hashed(entry(at: url), ceilingBytes: hashCeilingBytes)

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
        _ path: ScopedPath, maximumDepth: Int, includeHidden: Bool, limit: Int, offset: Int,
        countCeiling: Int, expired: () -> Bool
    ) throws -> FileTree {
        // No hashing in a tree: it would mean reading every byte under the root, which is
        // a different order of cost from listing names. filesystem_list is where a row
        // carries a hash.
        FolderScan.tree(
            root: path.path, rootChildren: try folder(path), maximumDepth: maximumDepth,
            includeHidden: includeHidden, limit: limit, offset: offset,
            countCeiling: countCeiling, expired: expired, children: children(of:))
    }

    public func read(_ path: ScopedPath, chunkBytes: Int, _ body: (Data) throws -> Bool) throws {
        let url = URL(fileURLWithPath: path.path)
        guard fileManager.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }
        guard try !isDirectory(url) else { throw ToolError.notAFile(path: path.path) }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw mapError(error, path: path.path)
        }
        defer { try? handle.close() }

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkBytes)
            } catch {
                throw mapError(error, path: path.path)
            }
            guard let chunk, !chunk.isEmpty, try body(chunk) else { return }
        }
    }

    public func grep(
        _ scope: ScopedPath, expression: NSRegularExpression, nameExpression: NSRegularExpression?,
        limit: Int, offset: Int, maximumFiles: Int, maximumFileBytes: Int, lineWidth: Int,
        expired: () -> Bool
    ) throws -> GrepPage {
        FolderScan.grep(
            rootChildren: try folder(scope), expression: expression, nameExpression: nameExpression,
            limit: limit, offset: offset, maximumFiles: maximumFiles,
            maximumFileBytes: maximumFileBytes, lineWidth: lineWidth, expired: expired,
            children: children(of:),
            contents: { try? Data(contentsOf: URL(fileURLWithPath: $0.path)) })
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
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
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

    /// Everything directly inside a folder, hidden items included, unhashed and in no
    /// order; `nil` when the folder cannot be listed, which a walk counts and says.
    private func children(of directory: String) -> [FileEntry]? {
        let urls = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: Array(Self.entryKeys))
        return urls?.map(entry(at:))
    }

    /// The folder a tool was pointed at. Unlike a folder met during a walk, failing to
    /// list this one is the tool's error to report, with the reason.
    private func folder(_ path: ScopedPath) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path.path)
        guard try isDirectory(url) else { throw ToolError.notADirectory(path: path.path) }
        do {
            return try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(Self.entryKeys)
            ).map(entry(at:))
        } catch {
            throw mapError(error, path: path.path)
        }
    }

    private func entry(at url: URL) -> FileEntry {
        let values = try? url.resourceValues(forKeys: Self.entryKeys)

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

        return FileEntry(
            path: url.path, name: values?.name ?? url.lastPathComponent, kind: kind,
            sizeBytes: values?.fileSize ?? 0, modifiedAt: values?.contentModificationDate,
            isHidden: values?.isHidden ?? false,
            isSymbolicLink: values?.isSymbolicLink ?? false, isPackage: values?.isPackage ?? false)
    }

    /// `entry` with its content hash, or with the reason it has none. A ceiling of zero
    /// means hashing was not asked for.
    private func hashed(_ entry: FileEntry, ceilingBytes: Int) -> FileEntry {
        guard entry.kind == .file, ceilingBytes > 0 else { return entry }
        guard entry.sizeBytes <= ceilingBytes else {
            return entry.withHash(nil, note: "too large to hash")
        }
        let hash = Self.contentHash(of: URL(fileURLWithPath: entry.path))
        return entry.withHash(hash, note: hash == nil ? "unreadable" : nil)
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
