import Foundation

/// The seam between the tool layer and the real disk.
///
/// Everything above this protocol is exercised by the tests against an in-memory tree;
/// everything below it can only be verified against real files. Keeping the boundary
/// this thin is what makes the untested surface small enough to check by hand — and it
/// is what lets the suite prove the two allow-lists without a single byte of the owner's
/// data being read.
///
/// Every path-taking method takes a `ScopedPath`, which cannot be constructed without
/// passing the allow-list check. `canonicalise` is the one exception: it is the step
/// that *feeds* the check, and it reads nothing but the shape of the path.
public protocol FilesystemStore: Sendable {

    // MARK: Resolution

    /// Expands `~`, removes `.`/`..`, and resolves every symlink in the path.
    ///
    /// Must tolerate a leaf that does not exist — a write target normally does not — by
    /// canonicalising the deepest existing ancestor and re-appending the rest. That is
    /// what stops `~/Documents/../../etc/passwd` and a symlink out of a read root from
    /// ever reaching the containment test as anything but their true destination.
    func canonicalise(_ path: String) throws -> CanonicalPath

    // MARK: Status

    /// Whether the root is there and this process may actually look inside it.
    func probe(_ path: String) -> RootState

    // MARK: Reads

    /// One page of a folder, folders first and then by name. Only the rows on the page are
    /// hashed, and none when `hashCeilingBytes` is zero. `expired` is asked between rows.
    func list(
        _ path: ScopedPath, includeHidden: Bool, hashCeilingBytes: Int, limit: Int, offset: Int,
        expired: () -> Bool
    ) throws -> FileListing

    func stat(_ path: ScopedPath, hashCeilingBytes: Int) throws -> FileStat

    /// One page of a depth-first walk. The walk counts the tree only as far as
    /// `countCeiling` entries; past that the page has no total.
    func tree(
        _ path: ScopedPath, maximumDepth: Int, includeHidden: Bool, limit: Int, offset: Int,
        countCeiling: Int, expired: () -> Bool
    ) throws -> FileTree

    /// Hands a file's bytes to `body` in order, at most `chunkBytes` at a time, until the
    /// file ends or `body` returns `false`. The file is never held whole, which is what
    /// lets a file of any size be read.
    func read(_ path: ScopedPath, chunkBytes: Int, _ body: (Data) throws -> Bool) throws

    /// Regex walk over a folder, for what Spotlight (a separate server,
    /// `apple-spotlight-mcp`) has not indexed. `scope` is a directory; the walk never
    /// leaves it, and visits it in the order of `tree`.
    func grep(
        _ scope: ScopedPath, expression: NSRegularExpression, nameExpression: NSRegularExpression?,
        limit: Int, offset: Int, maximumFiles: Int, maximumFileBytes: Int, lineWidth: Int,
        expired: () -> Bool
    ) throws -> GrepPage

    func tags(of path: ScopedPath) throws -> [String]

    // MARK: Writes

    /// `append: false` replaces the file's contents. The caller has already established
    /// that overwriting was asked for.
    func write(_ text: String, to path: ScopedPath, append: Bool) throws -> WriteOutcome

    /// Exact string replacement. `expectedCount` is the number of occurrences the caller
    /// believes exist; the store must change nothing at all if the file disagrees.
    func edit(
        _ path: ScopedPath, find: String, replace: String, expectedCount: Int
    ) throws -> EditOutcome

    func makeDirectory(_ path: ScopedPath, createIntermediates: Bool) throws -> FileStat

    func move(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome

    func copy(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome

    func setTags(_ tags: [String], on path: ScopedPath) throws -> [String]

    /// Moves to the Trash. There is no delete on this protocol and there must never be
    /// one: everything this server removes stays recoverable from the Finder.
    func trash(_ path: ScopedPath) throws -> TrashOutcome
}
