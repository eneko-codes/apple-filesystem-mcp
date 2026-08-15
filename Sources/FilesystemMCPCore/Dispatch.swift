import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `FilesystemStore`, which is
/// what lets the tests drive every branch below against an in-memory tree with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct FilesystemTools: Sendable {
    private let store: any FilesystemStore
    private let scope: PathScope
    private let configuration: Configuration
    private let format: Format

    /// Ceiling on a single `filesystem_tree` walk. Not configurable: it exists to stop
    /// one call returning a million lines, and nobody needs to tune that.
    static let treeEntryLimit = 2_000
    /// `filesystem_grep` walks files itself. These bound the walk rather than the answer.
    static let grepFileLimit = 5_000
    static let grepFileByteLimit = 4_194_304

    public init(
        store: any FilesystemStore,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.configuration = configuration
        self.format = Format(calendar: calendar)
        self.scope = PathScope(configuration: configuration, store: store)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return status()

        case ToolCatalog.listName:
            return try list(arguments)

        case ToolCatalog.statName:
            let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
            return format.stat(try store.stat(path, hashCeilingBytes: configuration.maximumHashBytes))

        case ToolCatalog.treeName:
            return try tree(arguments)

        case ToolCatalog.readTextName:
            return try readText(arguments)

        case ToolCatalog.grepName:
            return try grep(arguments)

        case ToolCatalog.tagsGetName:
            let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
            return format.tags(try store.tags(of: path), path: path.path)

        case ToolCatalog.writeName:
            return try write(arguments)

        case ToolCatalog.editName:
            return try edit(arguments)

        case ToolCatalog.makeDirectoryName:
            let path = try scope.resolve(try arguments.requiredString("path"), for: .write)
            let intermediates = arguments.bool("create_intermediates", default: true)
            return format.madeDirectory(
                try store.makeDirectory(path, createIntermediates: intermediates))

        case ToolCatalog.moveName:
            return try move(arguments)

        case ToolCatalog.copyName:
            return try copy(arguments)

        case ToolCatalog.tagsSetName:
            let path = try scope.resolve(try arguments.requiredString("path"), for: .write)
            let tags = try arguments.requiredStringArray("tags")
            return format.setTags(try store.setTags(tags, on: path), path: path.path)

        case ToolCatalog.trashName:
            return try trash(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func status() -> String {
        format.status(
            probes: scope.probeRoots(), binaryPath: Self.binaryPath,
            configuration: configuration, strandedWriteRoots: scope.strandedWriteRoots)
    }

    private func list(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
        // 0 disables hashing in the store, which keeps "do not hash" as one concept
        // rather than a flag the store also has to understand.
        let ceiling = arguments.bool("hashes", default: true) ? configuration.maximumHashBytes : 0
        let entries = try store.list(
            path, includeHidden: arguments.bool("include_hidden"), hashCeilingBytes: ceiling)
        return format.entries(entries, root: path.path, header: "Contents of \(path.path)")
    }

    private func tree(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
        let depth = try arguments.int("depth", default: 3, in: 1...12)
        let walked = try store.tree(
            path, maximumDepth: depth, includeHidden: arguments.bool("include_hidden"),
            entryLimit: Self.treeEntryLimit)
        return format.tree(walked)
    }

    private func readText(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
        let maximum = try arguments.int(
            "max_bytes", default: configuration.maximumReadBytes, in: Configuration.readBytesRange)
        return format.text(try store.readText(path, maximumBytes: maximum), path: path.path)
    }

    private func grep(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .read)
        let pattern = try arguments.requiredString("pattern")
        // Compiled here rather than in the store so a bad pattern is an argument error the
        // tests can reach, not a filesystem error surfaced from below the seam.
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ToolError.badRegex(pattern: pattern, reason: error.localizedDescription)
        }
        if let namePattern = arguments.optionalString("name_pattern") {
            do {
                _ = try NSRegularExpression(pattern: namePattern)
            } catch {
                throw ToolError.badRegex(pattern: namePattern, reason: error.localizedDescription)
            }
        }

        let page = try store.grep(
            path, pattern: pattern, ignoreCase: arguments.bool("ignore_case", default: true),
            namePattern: arguments.optionalString("name_pattern"),
            maximumMatches: try arguments.int("max_matches", default: 200, in: 1...2000),
            maximumFiles: Self.grepFileLimit, maximumFileBytes: Self.grepFileByteLimit)
        return format.grep(page, pattern: pattern, scope: path.path)
    }

    // MARK: Writes

    private func write(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .write)
        let append = arguments.bool("append")
        // Content is taken raw: trimming it would silently drop the trailing newline that
        // every well-formed text file ends with.
        let content = try arguments.requiredRawString("content")

        if path.exists, !append, !arguments.bool("overwrite") {
            throw ToolError.alreadyExists(path: path.path)
        }
        return format.wrote(try store.write(content, to: path, append: append), appended: append)
    }

    private func edit(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .write)
        let find = try arguments.requiredRawString("find")
        guard !find.isEmpty else {
            throw ToolError.badArgument(
                name: "find", reason: "it is empty, which would match everywhere and nowhere")
        }
        let replace = arguments.rawString("replace", default: "")
        let expected = try arguments.int("expected_count", default: 1, in: 1...1000)
        return format.edited(
            try store.edit(path, find: find, replace: replace, expectedCount: expected))
    }

    private func move(_ arguments: Arguments) throws -> String {
        // Both ends writable. A move out of the write scope would take the file somewhere
        // this server is not allowed to touch, which is a way around the boundary rather
        // than a use of it.
        let from = try scope.resolve(try arguments.requiredString("from"), for: .write)
        let to = try scope.resolve(try arguments.requiredString("to"), for: .write)
        try guardTransfer(from: from, to: to, overwrite: arguments.bool("overwrite"))
        return format.transferred(
            try store.move(from: from, to: to, overwrite: arguments.bool("overwrite")),
            verb: "Moved")
    }

    private func copy(_ arguments: Arguments) throws -> String {
        // Asymmetric on purpose: reading the source changes nothing about it, so a copy
        // out of a read-only folder into a working one is exactly what the two lists are
        // for.
        let from = try scope.resolve(try arguments.requiredString("from"), for: .read)
        let to = try scope.resolve(try arguments.requiredString("to"), for: .write)
        try guardTransfer(from: from, to: to, overwrite: arguments.bool("overwrite"))
        return format.transferred(
            try store.copy(from: from, to: to, overwrite: arguments.bool("overwrite")),
            verb: "Copied")
    }

    private func guardTransfer(from: ScopedPath, to: ScopedPath, overwrite: Bool) throws {
        guard from.exists else { throw ToolError.notFound(path: from.path) }
        if to.exists, !overwrite { throw ToolError.alreadyExists(path: to.path) }
        // Both paths are already canonical, so a containment test on the strings is the
        // real relationship and not a guess about symlinks.
        guard !PathScope.contains(root: from.path, candidate: to.path) else {
            throw ToolError.destinationInsideSource(from: from.path, to: to.path)
        }
    }

    private func trash(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"), for: .write)
        guard path.exists else { throw ToolError.notFound(path: path.path) }
        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Moving something to the Trash")
        }
        return format.trashed(try store.trash(path))
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
