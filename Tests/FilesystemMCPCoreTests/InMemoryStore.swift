import Foundation
import Synchronization

@testable import FilesystemMCPCore

/// An invented folder tree held in memory. No file in it exists anywhere.
///
/// It lists folders and serves bytes; the walks, the paging and the stops are the real
/// ones in `FolderScan` and `TextReader`, the same code `SystemFilesystemStore` runs. The
/// write methods change nothing and answer with a plausible outcome, which is all a test of
/// what a tool says needs.
struct InMemoryStore: FilesystemStore {

    struct Item {
        var kind: FileKind = .file
        var data = Data()
        var isHidden = false
        var isSymbolicLink = false
        var isPackage = false
        var tags: [String] = []
        /// Reported instead of `data.count`, for a file that only has to look large.
        var statedSize: Int?
    }

    /// Fills a tree. Parent folders are made as needed.
    final class Builder {
        fileprivate var items: [String: Item] = ["/": Item(kind: .directory)]

        func folder(_ path: String, hidden: Bool = false, symbolicLink: Bool = false, package: Bool = false) {
            parents(of: path)
            items[path] = Item(kind: .directory, isHidden: hidden, isSymbolicLink: symbolicLink, isPackage: package)
        }

        func file(
            _ path: String, _ text: String = "", hidden: Bool = false, symbolicLink: Bool = false,
            tags: [String] = [], statedSize: Int? = nil
        ) {
            file(path, data: Data(text.utf8), hidden: hidden, symbolicLink: symbolicLink, tags: tags, statedSize: statedSize)
        }

        func file(
            _ path: String, data: Data, hidden: Bool = false, symbolicLink: Bool = false,
            tags: [String] = [], statedSize: Int? = nil
        ) {
            parents(of: path)
            items[path] = Item(
                data: data, isHidden: hidden, isSymbolicLink: symbolicLink, tags: tags, statedSize: statedSize)
        }

        private func parents(of path: String) {
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", items[parent] == nil {
                items[parent] = Item(kind: .directory)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    /// Counts calls from inside the store, which is a value and cannot count for itself.
    final class Counter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        @discardableResult func next() -> Int {
            count.withLock {
                $0 += 1
                return $0
            }
        }
    }

    private let items: [String: Item]
    private let childrenByFolder: [String: [FileEntry]]
    /// How many files were hashed, so a test can see that only a page's rows are read.
    let hashed = Counter()
    /// Seconds every call waits before answering, for the tests of the deadline.
    var delay: TimeInterval = 0

    init(_ fill: (Builder) -> Void = { _ in }) {
        let builder = Builder()
        fill(builder)
        items = builder.items
        var children: [String: [FileEntry]] = [:]
        // Deliberately not in name order: the order of a listing is the scan's to make.
        for path in builder.items.keys.sorted(by: >) where path != "/" {
            guard let item = builder.items[path] else { continue }
            children[(path as NSString).deletingLastPathComponent, default: []].append(Self.entry(path, item))
        }
        childrenByFolder = children
    }

    private static let modified = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entry(_ path: String, _ item: Item) -> FileEntry {
        FileEntry(
            path: path, name: (path as NSString).lastPathComponent, kind: item.kind,
            sizeBytes: item.statedSize ?? item.data.count, modifiedAt: modified,
            isHidden: item.isHidden, isSymbolicLink: item.isSymbolicLink, isPackage: item.isPackage)
    }

    private func wait() {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    private func item(_ path: ScopedPath) throws -> Item {
        guard let item = items[path.path] else { throw ToolError.notFound(path: path.path) }
        return item
    }

    private func folder(_ path: ScopedPath) throws {
        guard try item(path).kind == .directory else { throw ToolError.notADirectory(path: path.path) }
    }

    // MARK: Resolution and status

    func canonicalise(_ path: String) throws -> CanonicalPath {
        let resolved = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return CanonicalPath(path: resolved, exists: items[resolved] != nil)
    }

    func probe(_ path: String) -> RootState {
        wait()
        return items[path] == nil ? .missing : .reachable
    }

    // MARK: Reads

    func list(
        _ path: ScopedPath, includeHidden: Bool, hashCeilingBytes: Int, limit: Int, offset: Int,
        expired: () -> Bool
    ) throws -> FileListing {
        wait()
        try folder(path)
        return FolderScan.listing(
            children: childrenByFolder[path.path] ?? [], includeHidden: includeHidden, limit: limit,
            offset: offset, expired: expired
        ) { entry in
            guard entry.kind == .file, hashCeilingBytes > 0 else { return entry }
            guard entry.sizeBytes <= hashCeilingBytes else {
                return entry.withHash(nil, note: "too large to hash")
            }
            hashed.next()
            return entry.withHash(String(format: "%016llx", UInt64(entry.sizeBytes)), note: nil)
        }
    }

    func stat(_ path: ScopedPath, hashCeilingBytes: Int) throws -> FileStat {
        let item = try item(path)
        return FileStat(entry: Self.entry(path.path, item), tags: item.tags)
    }

    func tree(
        _ path: ScopedPath, maximumDepth: Int, includeHidden: Bool, limit: Int, offset: Int,
        countCeiling: Int, expired: () -> Bool
    ) throws -> FileTree {
        try folder(path)
        return FolderScan.tree(
            root: path.path, rootChildren: childrenByFolder[path.path] ?? [],
            maximumDepth: maximumDepth, includeHidden: includeHidden, limit: limit,
            offset: offset, countCeiling: countCeiling, expired: expired,
            children: { childrenByFolder[$0] ?? [] })
    }

    func read(_ path: ScopedPath, chunkBytes: Int, _ body: (Data) throws -> Bool) throws {
        let item = try item(path)
        guard item.kind != .directory else { throw ToolError.notAFile(path: path.path) }
        var start = 0
        while start < item.data.count {
            let end = min(start + chunkBytes, item.data.count)
            guard try body(item.data.subdata(in: start..<end)) else { return }
            start = end
        }
    }

    func grep(
        _ scope: ScopedPath, expression: NSRegularExpression, nameExpression: NSRegularExpression?,
        limit: Int, offset: Int, maximumFiles: Int, maximumFileBytes: Int, lineWidth: Int,
        expired: () -> Bool
    ) throws -> GrepPage {
        try folder(scope)
        return FolderScan.grep(
            rootChildren: childrenByFolder[scope.path] ?? [], expression: expression, nameExpression: nameExpression, limit: limit,
            offset: offset, maximumFiles: maximumFiles, maximumFileBytes: maximumFileBytes,
            lineWidth: lineWidth, expired: expired,
            children: { childrenByFolder[$0] ?? [] }, contents: { items[$0.path]?.data })
    }

    func tags(of path: ScopedPath) throws -> [String] {
        try item(path).tags
    }

    // MARK: Writes, which change nothing

    func write(_ text: String, to path: ScopedPath, append: Bool) throws -> WriteOutcome {
        WriteOutcome(
            path: path.path, bytesWritten: text.utf8.count, created: items[path.path] == nil,
            previousSizeBytes: items[path.path]?.data.count)
    }

    func edit(_ path: ScopedPath, find: String, replace: String, expectedCount: Int) throws
        -> EditOutcome
    {
        EditOutcome(path: path.path, replacements: expectedCount, bytesWritten: try item(path).data.count)
    }

    func makeDirectory(_ path: ScopedPath, createIntermediates: Bool) throws -> FileStat {
        let entry = FileEntry(
            path: path.path, name: path.lastComponent, kind: .directory, sizeBytes: 0,
            modifiedAt: Self.modified, isHidden: false)
        return FileStat(entry: entry, tags: items[path.path]?.tags ?? [])
    }

    func move(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    {
        wait()
        return TransferOutcome(from: source.path, to: destination.path, replacedExisting: false)
    }

    func copy(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    {
        wait()
        return TransferOutcome(from: source.path, to: destination.path, replacedExisting: false)
    }

    func setTags(_ tags: [String], on path: ScopedPath) throws -> [String] { tags }

    func trash(_ path: ScopedPath) throws -> TrashOutcome {
        TrashOutcome(originalPath: path.path, trashPath: "/invented/.Trash/\(path.lastComponent)")
    }
}

/// Calls one tool against an invented tree. Everything under `/invented` may be read, and
/// `/invented/scratch` may be written, unless the test says otherwise.
func call(
    _ tool: String, _ arguments: [String: Value] = [:], store: InMemoryStore,
    readRoots: [String] = ["/invented"], writeRoots: [String] = ["/invented/scratch"],
    timeout: Duration = FilesystemTools.defaultTimeout,
    scanClock: FilesystemTools.ScanClock? = nil
) async -> ToolOutput {
    var configuration = Configuration()
    configuration.readRoots = readRoots
    configuration.writeRoots = writeRoots
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let tools = FilesystemTools(
        store: store, configuration: configuration, calendar: calendar, timeout: timeout,
        scanClock: scanClock ?? FilesystemTools.ScanClock { { false } })
    return await tools.handle(ToolCall(name: tool, arguments: arguments))
}

/// A scan clock that runs out after it has been asked `checks` times.
func expiring(after checks: Int) -> FilesystemTools.ScanClock {
    FilesystemTools.ScanClock {
        let asked = InMemoryStore.Counter()
        return { asked.next() > checks }
    }
}
