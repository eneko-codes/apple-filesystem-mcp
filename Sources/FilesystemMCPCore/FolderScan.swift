import Foundation

/// The walks behind `filesystem_list`, `filesystem_tree` and `filesystem_grep`: the order of
/// the rows, the page cut out of them, and every reason a walk stops early.
///
/// Pure. It is handed closures that list a folder and read a file, so the real store and
/// the tests' in-memory tree run the same code, and nothing here can reach the disk.
enum FolderScan {

    /// Asked between items; `true` once the call has used the time it may spend scanning.
    typealias Expired = () -> Bool

    /// Everything directly inside a folder, hidden items included, in no order; `nil` when
    /// the folder could not be listed. A walk counts those folders, so that one macOS
    /// refused is never passed off as an empty one.
    typealias Children = (String) -> [FileEntry]?

    /// Finder's order, in which "file2" comes before "file10". The raw name settles what
    /// that comparison leaves equal, so two names never tie and a page boundary falls in
    /// the same place on the next call.
    static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs < rhs
        }
    }

    // MARK: One folder

    /// One page of a folder: folders first, then by name. Only the rows on the page are
    /// handed to `hashed`, because hashing reads every byte of a file.
    static func listing(
        children: [FileEntry], includeHidden: Bool, limit: Int, offset: Int, expired: Expired,
        hashed: (FileEntry) -> FileEntry
    ) -> FileListing {
        let shown = (includeHidden ? children : children.filter { !$0.isHidden }).sorted { lhs, rhs in
            // The shape of a folder is easier to read when its structure is not
            // interleaved with its contents.
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            return nameOrder(lhs.name, rhs.name)
        }
        var page: [FileEntry] = []
        var stoppedForTime = false
        for entry in shown.dropFirst(offset).prefix(limit) {
            // The first row is hashed whatever the clock says, so a page that has rows to
            // show is never empty and the next call always starts further on.
            if !page.isEmpty, expired() {
                stoppedForTime = true
                break
            }
            page.append(hashed(entry))
        }
        return FileListing(
            entries: page, total: shown.count, hidden: children.count - shown.count,
            stoppedForTime: stoppedForTime)
    }

    // MARK: Tree

    /// A depth-first walk: each folder's items in name order, a folder followed by what it
    /// holds. Returns the entries from `offset` on, at most `limit` of them.
    ///
    /// The walk goes on past the page to count the tree, but only as far as `countCeiling`
    /// entries: counting a home folder would mean walking all of it on every call. A tree
    /// larger than that has no total, only the knowledge that more exists.
    static func tree(
        root: String, rootChildren: [FileEntry], maximumDepth: Int, includeHidden: Bool,
        limit: Int, offset: Int, countCeiling: Int, expired: Expired, children: Children
    ) -> FileTree {
        var nodes: [FileTree.Node] = []
        var walked = 0
        var hidden = 0
        var unlisted = 0
        var reachedTheEnd = true
        var stoppedForTime = false
        let horizon = Swift.max(offset + limit, countCeiling)

        func walk(_ listed: [FileEntry], depth: Int) -> Bool {
            let shown = includeHidden ? listed : listed.filter { !$0.isHidden }
            hidden += listed.count - shown.count
            for child in shown.sorted(by: { nameOrder($0.name, $1.name) }) {
                // Reaching one entry past the horizon is what proves more exist.
                guard walked < horizon else {
                    reachedTheEnd = false
                    return false
                }
                // A folder is opened before its own row is written, so that the row can
                // say when it could not be.
                var inside: [FileEntry]?
                var couldNotBeListed = false
                if child.kind == .directory, depth < maximumDepth {
                    if expired() {
                        stoppedForTime = true
                        return false
                    }
                    inside = children(child.path)
                    couldNotBeListed = inside == nil
                }
                if walked >= offset, nodes.count < limit {
                    nodes.append(
                        FileTree.Node(entry: child, depth: depth - 1, couldNotBeListed: couldNotBeListed))
                }
                walked += 1
                if couldNotBeListed { unlisted += 1 }
                if let inside, !walk(inside, depth: depth + 1) { return false }
            }
            return true
        }
        _ = walk(rootChildren, depth: 1)

        return FileTree(
            root: root, maximumDepth: maximumDepth, nodes: nodes,
            total: reachedTheEnd && !stoppedForTime ? walked : nil, walked: walked, hidden: hidden,
            foldersNotListed: unlisted, stoppedForTime: stoppedForTime)
    }

    // MARK: Grep

    /// The same depth-first order as `tree`, reading every regular file on the way and
    /// keeping the matching lines from `offset` on, at most `limit` of them.
    ///
    /// Hidden items, the insides of packages and anything behind a symbolic link are never
    /// entered or read. The scan stops at the first match past the page (so the caller
    /// learns that more exist without paying to find them all), after `maximumFiles` files
    /// have been searched, or when the time runs out; `GrepPage.stop` says which.
    static func grep(
        rootChildren: [FileEntry], expression: NSRegularExpression,
        nameExpression: NSRegularExpression?, limit: Int, offset: Int, maximumFiles: Int,
        maximumFileBytes: Int, lineWidth: Int, expired: Expired, children: Children,
        contents: (FileEntry) -> Data?
    ) -> GrepPage {
        var matches: [GrepPage.Match] = []
        var found = 0
        var searched = 0
        var tooLarge = 0
        var notText = 0
        var unreadable = 0
        var unlisted = 0
        var stop = GrepPage.Stop.finished

        func search(_ file: FileEntry) -> Bool {
            guard file.sizeBytes <= maximumFileBytes else {
                tooLarge += 1
                return true
            }
            guard let data = contents(file) else {
                unreadable += 1
                return true
            }
            guard let text = TextDecoding.decode(data)?.text else {
                notText += 1
                return true
            }
            searched += 1
            for (index, line) in lines(of: text).enumerated() {
                guard let matched = isMatch(expression, String(line), expired: expired) else {
                    stop = .timeLimit
                    return false
                }
                guard matched else { continue }
                guard found < offset + limit else {
                    stop = .pageFull
                    return false
                }
                if found >= offset {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    matches.append(
                        GrepPage.Match(
                            path: file.path, lineNumber: index + 1,
                            line: String(trimmed.prefix(lineWidth)),
                            isClipped: trimmed.count > lineWidth))
                }
                found += 1
            }
            return true
        }

        func walk(_ listed: [FileEntry]) -> Bool {
            let visible = listed.filter { !$0.isHidden && !$0.isSymbolicLink }
            for child in visible.sorted(by: { nameOrder($0.name, $1.name) }) {
                if expired() {
                    stop = .timeLimit
                    return false
                }
                switch child.kind {
                case .directory:
                    guard !child.isPackage else { continue }
                    guard let inside = children(child.path) else {
                        unlisted += 1
                        continue
                    }
                    if !walk(inside) { return false }
                case .file:
                    if let nameExpression, !contains(nameExpression, child.name) { continue }
                    // Meeting one file past the ceiling is what proves the scan is unfinished.
                    guard searched < maximumFiles else {
                        stop = .fileCeiling
                        return false
                    }
                    if !search(child) { return false }
                case .brokenSymlink, .other:
                    continue
                }
            }
            return true
        }
        _ = walk(rootChildren)

        return GrepPage(
            matches: matches, matchesFound: found, filesSearched: searched, filesTooLarge: tooLarge,
            filesNotText: notText, filesNotRead: unreadable, foldersNotListed: unlisted, stop: stop)
    }

    /// Lines as an editor numbers them. "\r\n" is one `Character` in Swift, distinct from
    /// "\n", so a file with Windows line endings needs it named or it reads as one line.
    static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    }

    private static func contains(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether `line` matches, or `nil` when the time ran out first.
    ///
    /// A pattern that backtracks badly can spend minutes on one long line. Asking for
    /// progress reports is the only way to stop such a match from outside, so the clock is
    /// read on each report.
    private static func isMatch(
        _ expression: NSRegularExpression, _ line: String, expired: Expired
    ) -> Bool? {
        var isMatch = false
        var gaveUp = false
        expression.enumerateMatches(
            in: line, options: [.reportProgress], range: NSRange(line.startIndex..., in: line)
        ) { result, flags, stop in
            if result != nil {
                isMatch = true
                stop.pointee = true
            } else if flags.contains(.progress), expired() {
                gaveUp = true
                stop.pointee = true
            }
        }
        return gaveUp ? nil : isMatch
    }
}
