import Foundation

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `FilesystemStore`, which is
/// what lets the tests drive every branch below against an in-memory tree with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct FilesystemTools: ToolHandler {

    /// Started once for a call that scans; what it returns says whether the call has used
    /// the time it may spend scanning. A parameter so the tests can run a scan out of time
    /// without waiting.
    public struct ScanClock: Sendable {
        private let makeTimer: @Sendable () -> (() -> Bool)

        public init(_ makeTimer: @escaping @Sendable () -> (() -> Bool)) {
            self.makeTimer = makeTimer
        }

        /// Runs out `budget` after it is started.
        public static func lasting(_ budget: Duration) -> ScanClock {
            ScanClock {
                let end = ContinuousClock.now + budget
                return { ContinuousClock.now >= end }
            }
        }

        func start() -> () -> Bool { makeTimer() }
    }

    private let store: any FilesystemStore
    private let scope: PathScope
    private let configuration: Configuration
    private let format: Format
    private let timeout: Duration
    private let scanClock: ScanClock

    /// When a call is abandoned and answered with an error. It sits inside
    /// `ToolStandard.timeLimit`, so the answer is this server's and not a client's generic
    /// "no result".
    public static let defaultTimeout = Duration.seconds(180)

    /// How long a call may spend walking, hashing or reading before it returns what it has
    /// and says it is partial. Well short of `defaultTimeout`, so that the item in hand when
    /// the time runs out can still finish and the partial result still be sent.
    public static let defaultScanBudget = Duration.seconds(100)

    public init(
        store: any FilesystemStore,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current,
        timeout: Duration = FilesystemTools.defaultTimeout,
        scanClock: ScanClock = .lasting(FilesystemTools.defaultScanBudget)
    ) {
        self.store = store
        self.configuration = configuration
        self.format = Format(calendar: calendar)
        self.scope = PathScope(configuration: configuration, store: store)
        self.timeout = timeout
        self.scanClock = scanClock
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(tool: parameters.name, seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? ToolError.storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    private func run(_ parameters: ToolCall) throws -> String {
        try Self.refuseUnknownArguments(parameters)
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName: return try status(arguments)
        case ToolCatalog.listName: return try list(arguments)
        case ToolCatalog.statName: return try stat(arguments)
        case ToolCatalog.treeName: return try tree(arguments)
        case ToolCatalog.readTextName: return try readText(arguments)
        case ToolCatalog.grepName: return try grep(arguments)
        case ToolCatalog.tagsGetName: return try tags(arguments)
        case ToolCatalog.writeName: return try write(arguments)
        case ToolCatalog.editName: return try edit(arguments)
        case ToolCatalog.makeDirectoryName: return try makeDirectory(arguments)
        case ToolCatalog.moveName: return try move(arguments)
        case ToolCatalog.copyName: return try copy(arguments)
        case ToolCatalog.tagsSetName: return try setTags(arguments)
        case ToolCatalog.trashName: return try trash(arguments)
        default: throw ToolError.unknownTool(parameters.name)
        }
    }

    /// A call that still uses a name this server no longer has (after a rename) or spells
    /// one wrong must fail, not run without that argument and return something else.
    private static func refuseUnknownArguments(_ parameters: ToolCall) throws {
        guard let tool = ToolCatalog.all().first(where: { $0.name == parameters.name }),
            let given = parameters.arguments
        else { return }
        let allowed = Set(tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let unknown = given.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        throw ToolError.unknownArguments(
            tool: tool.name, unknown: unknown, allowed: allowed.sorted())
    }

    // MARK: Notices

    /// The sentence that places a page cut at the source, where the rows were never all in
    /// hand. `returned` is how many rows the scan gave and `shown` how many of them fit the
    /// result; `total` is `nil` when the scan did not reach the end.
    ///
    /// With no total, a next page is offered only when one is known to exist: the scan met
    /// a row past the page, or the result holds fewer rows than the scan gave. A scan that
    /// stopped for another reason says so in its own notice, and offers no offset that
    /// would only stop at the same place.
    private static func position(
        offset: Int, shown: Int, returned: Int, total: Int?, moreExist: Bool, things: String
    ) -> String? {
        if let total {
            return Notice.page(offset: offset, count: shown, total: total, things: things)
        }
        guard shown > 0, moreExist || shown < returned else { return nil }
        return Notice.page(offset: offset, count: shown, total: nil, things: things)
    }

    /// Puts the clipped-tags notice before a result whose tags field was cut.
    private func withTagsNotice(_ tags: [String], _ text: String) -> String {
        guard Format.tagsField(tags).isClipped else { return text }
        return ToolStandard.withNotices(
            [
                Notice.clipped(
                    field: "Tags", width: ToolCatalog.tagsFieldWidth, tool: ToolCatalog.tagsGetName)
            ], text)
    }

    // MARK: Reads

    private func status(_ arguments: Arguments) throws -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultRootLimit, limits: ToolCatalog.rootLimitRange)
        let probes = scope.probeRoots()
        return ToolStandard.page(
            of: probes, limit: page.limit, offset: page.offset, things: "configured folders",
            notices: arguments.notices
        ) {
            format.status(
                rows: $0, all: probes, binaryPath: Self.binaryPath, configuration: configuration)
        }
    }

    private func list(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let includeHidden = try arguments.bool("include_hidden")
        // 0 disables hashing in the store, which keeps "do not hash" as one concept
        // rather than a flag the store also has to understand.
        let ceiling = try arguments.bool("hashes", default: true) ? configuration.maximumHashBytes : 0
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultListLimit, limits: ToolCatalog.listLimitRange)

        let listing = try store.list(
            path, includeHidden: includeHidden, hashCeilingBytes: ceiling, limit: page.limit,
            offset: page.offset, expired: scanClock.start())

        var notices = arguments.notices
        if listing.hidden > 0 {
            notices.append(
                Notice.notShown(count: listing.hidden, things: "hidden items", pass: "include_hidden=true"))
        }
        if listing.stoppedForTime {
            notices.append(
                Notice.partial(
                    after: listing.entries.count, things: "items",
                    narrowBy: "a smaller limit or hashes=false"))
        }
        return ToolStandard.fitting(listing.entries.count) { size in
            let rows = Array(listing.entries.prefix(size))
            let position = Notice.page(
                offset: page.offset, count: rows.count, total: listing.total, things: "items")
            return ToolStandard.withNotices(
                notices + [position].compactMap { $0 },
                format.entries(rows, total: listing.total, root: path.path))
        }
    }

    private func stat(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let stat = try store.stat(path, hashCeilingBytes: configuration.maximumHashBytes)
        return withTagsNotice(stat.tags, format.stat(stat))
    }

    private func tree(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let depth = try arguments.int(
            "depth", default: ToolCatalog.defaultDepth, in: ToolCatalog.depthRange)
        let includeHidden = try arguments.bool("include_hidden")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTreeLimit, limits: ToolCatalog.treeLimitRange)

        let walked = try store.tree(
            path, maximumDepth: depth, includeHidden: includeHidden, limit: page.limit,
            offset: page.offset, countCeiling: ToolCatalog.treeCountCeiling, expired: scanClock.start())

        var notices = arguments.notices
        if walked.hidden > 0 {
            notices.append(
                Notice.notShown(
                    count: walked.hidden, things: "hidden items in the folders walked",
                    pass: "include_hidden=true"))
        }
        if walked.stoppedForTime {
            notices.append(
                Notice.partial(
                    after: walked.walked, things: "entries", narrowBy: "path or a lower depth"))
        }
        return ToolStandard.fitting(walked.nodes.count) { size in
            let rows = Array(walked.nodes.prefix(size))
            let position = Self.position(
                offset: page.offset, shown: rows.count, returned: walked.nodes.count,
                total: walked.total, moreExist: !walked.stoppedForTime, things: "entries")
            return ToolStandard.withNotices(
                notices + [position].compactMap { $0 },
                format.tree(walked, nodes: rows, offset: page.offset))
        }
    }

    private func readText(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: ToolCatalog.characterOffsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: ToolCatalog.defaultMaxCharacters,
            in: ToolCatalog.maxCharactersRange)

        let outcome = try TextReader.read(
            characterOffset: characterOffset, maxCharacters: maxCharacters,
            wholeFileBytes: ToolCatalog.wholeFileBytes, expired: scanClock.start()
        ) { body in
            try store.read(path, chunkBytes: ToolCatalog.readChunkBytes, body)
        }

        switch outcome {
        case .notText:
            throw ToolError.undecodableText(path: path.path)
        case .tooLargeToDecode:
            throw ToolError.tooLargeToDecode(
                path: path.path, bytes: (try? store.stat(path, hashCeilingBytes: 0))?.entry.sizeBytes,
                maximum: ToolCatalog.wholeFileBytes)
        case .timeLimit(let bytesRead, _):
            throw ToolError.readTimeLimit(
                path: path.path, bytesRead: bytesRead,
                seconds: Int(Self.defaultScanBudget.components.seconds))
        case .window(let window):
            return ToolStandard.fitting(maxCharacters) { size in
                let part = String(window.text.prefix(size))
                var notices = arguments.notices
                if window.isWholeFile {
                    notices += [
                        Notice.window(
                            offset: characterOffset, count: part.count, total: window.totalCharacters)
                    ].compactMap { $0 }
                } else {
                    // The time ran out after this window was cut and before the file ended,
                    // so its length is not known and a `Notice.window` would state a false
                    // total. What follows the window is read from where it ends.
                    notices.append(
                        Notice.partial(
                            after: window.totalCharacters, things: "characters counted",
                            narrowBy: "character_offset=\(characterOffset + part.count) to read on"))
                }
                return ToolStandard.withNotices(
                    notices, format.text(part, of: window, path: path.path))
            }
        }
    }

    private func grep(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let pattern = try arguments.requiredString("pattern")
        let ignoreCase = try arguments.bool("ignore_case", default: true)
        // Compiled here rather than in the store so a bad pattern is an argument error the
        // tests can reach, not a filesystem error surfaced from below the seam.
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        else {
            throw ToolError.badRegex(argument: "pattern", pattern: pattern)
        }
        var nameExpression: NSRegularExpression?
        if let namePattern = try arguments.optionalString("name_pattern") {
            guard
                let compiled = try? NSRegularExpression(pattern: namePattern, options: [.caseInsensitive])
            else {
                throw ToolError.badRegex(argument: "name_pattern", pattern: namePattern)
            }
            nameExpression = compiled
        }
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultGrepLimit, limits: ToolCatalog.grepLimitRange)

        let found = try store.grep(
            path, expression: expression, nameExpression: nameExpression, limit: page.limit,
            offset: page.offset, maximumFiles: ToolCatalog.grepFileCeiling,
            maximumFileBytes: ToolCatalog.grepFileBytes, lineWidth: ToolCatalog.grepLineWidth,
            expired: scanClock.start())

        var notices = arguments.notices
        if found.filesTooLarge + found.filesNotText > 0 {
            // No argument brings these into a search, so no standard notice fits: the
            // sentence says what was passed over and which tool reads such a file.
            notices.append(
                """
                \(found.filesTooLarge + found.filesNotText) files were not searched: \
                \(found.filesTooLarge) larger than \(Format.bytes(ToolCatalog.grepFileBytes)), \
                \(found.filesNotText) binary or not text. Read a large text file with \
                \(ToolCatalog.readTextName).
                """)
        }
        switch found.stop {
        case .fileCeiling:
            notices.append(
                Notice.scanStopped(
                    after: found.filesSearched, things: "files", narrowBy: "path or name_pattern"))
        case .timeLimit:
            notices.append(
                Notice.partial(
                    after: found.filesSearched, things: "files", narrowBy: "path or name_pattern"))
        case .finished, .pageFull:
            break
        }
        return ToolStandard.fitting(found.matches.count) { size in
            let rows = Array(found.matches.prefix(size))
            var notices = notices
            if let position = Self.position(
                offset: page.offset, shown: rows.count, returned: found.matches.count,
                total: found.stop == .finished ? found.matchesFound : nil,
                moreExist: found.stop == .pageFull, things: "matching lines")
            {
                notices.append(position)
            }
            if rows.contains(where: \.isClipped) {
                notices.append(
                    Notice.clipped(
                        field: "Line", width: ToolCatalog.grepLineWidth,
                        tool: ToolCatalog.readTextName))
            }
            return ToolStandard.withNotices(
                notices,
                format.grep(found, matches: rows, offset: page.offset, pattern: pattern, scope: path.path))
        }
    }

    private func tags(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .read)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultTagLimit, limits: ToolCatalog.tagLimitRange)
        let tags = try store.tags(of: path)
        return ToolStandard.page(
            of: tags, limit: page.limit, offset: page.offset, things: "tags",
            notices: arguments.notices
        ) {
            format.tags($0, total: tags.count, path: path.path)
        }
    }

    // MARK: Writes

    private func write(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .write)
        let append = try arguments.bool("append")
        let overwrite = try arguments.bool("overwrite")
        // Content is taken raw: trimming it would silently drop the trailing newline that
        // every well-formed text file ends with.
        let content = try arguments.requiredRawString("content")

        if path.exists, !append, !overwrite {
            throw ToolError.alreadyExists(path: path.path)
        }
        return format.wrote(try store.write(content, to: path, append: append), appended: append)
    }

    private func edit(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .write)
        let find = try arguments.requiredRawString("find")
        guard !find.isEmpty else {
            throw ToolError.badArgument(
                name: "find", reason: "it is empty, which would match everywhere and nowhere")
        }
        let replace = try arguments.rawString("replace", default: "")
        let expected = try arguments.exactInt(
            "expected_count", default: 1, in: ToolCatalog.expectedCountRange)
        return format.edited(
            try store.edit(path, find: find, replace: replace, expectedCount: expected))
    }

    private func makeDirectory(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .write)
        let intermediates = try arguments.bool("create_intermediates", default: true)
        let made = try store.makeDirectory(path, createIntermediates: intermediates)
        return withTagsNotice(made.tags, format.madeDirectory(made))
    }

    private func move(_ arguments: Arguments) throws -> String {
        // Both ends writable. A move out of the write scope would take the file somewhere
        // this server is not allowed to touch, which is a way around the boundary rather
        // than a use of it.
        let from = try scope.resolve(try arguments.path("from"), for: .write)
        let to = try scope.resolve(try arguments.path("to"), for: .write)
        let overwrite = try arguments.bool("overwrite")
        try guardTransfer(from: from, to: to, overwrite: overwrite)
        return format.transferred(
            try store.move(from: from, to: to, overwrite: overwrite), verb: "Moved")
    }

    private func copy(_ arguments: Arguments) throws -> String {
        // Asymmetric on purpose: reading the source changes nothing about it, so a copy
        // out of a read-only folder into a working one is exactly what the two lists are
        // for.
        let from = try scope.resolve(try arguments.path("from"), for: .read)
        let to = try scope.resolve(try arguments.path("to"), for: .write)
        let overwrite = try arguments.bool("overwrite")
        try guardTransfer(from: from, to: to, overwrite: overwrite)
        return format.transferred(
            try store.copy(from: from, to: to, overwrite: overwrite), verb: "Copied")
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

    private func setTags(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .write)
        let tags = try store.setTags(try arguments.requiredStringArray("tags"), on: path)
        return withTagsNotice(tags, format.setTags(tags, path: path.path))
    }

    private func trash(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.path("path"), for: .write)
        guard path.exists else { throw ToolError.notFound(path: path.path) }
        guard try arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Moving something to the Trash")
        }
        return format.trashed(try store.trash(path))
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
