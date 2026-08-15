import Foundation
import Testing

@testable import FilesystemMCPCore

/// A `FilesystemStore` that only knows how to canonicalise.
///
/// `PathScope` is the one thing in this module worth proving exhaustively, and it needs
/// exactly one store method: everything else exists so the type conforms. Those methods
/// throw rather than returning something plausible — a scope test that accidentally
/// reached the disk should fail loudly, not quietly pass.
///
/// Canonicalisation is modelled rather than performed: the map below says what each raw
/// path resolves to, which is how a symlink pointing out of the allow-list can be
/// expressed without creating one on the real filesystem.
struct StubStore: FilesystemStore {

    /// raw path → where it really lands. Anything absent resolves to itself.
    var resolutions: [String: String] = [:]
    var existing: Set<String> = []

    func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = resolutions[expanded] ?? (expanded as NSString).standardizingPath
        return CanonicalPath(path: resolved, exists: existing.contains(resolved))
    }

    func probe(_ path: String) -> RootState { .reachable }

    private func unreachable() -> ToolError {
        .storeFailure("a scope test reached the filesystem, which it must never do")
    }

    func list(_ path: ScopedPath, includeHidden: Bool, hashCeilingBytes: Int) throws -> [FileEntry] {
        throw unreachable()
    }
    func stat(_ path: ScopedPath, hashCeilingBytes: Int) throws -> FileStat { throw unreachable() }
    func tree(_ path: ScopedPath, maximumDepth: Int, includeHidden: Bool, entryLimit: Int) throws
        -> FileTree
    { throw unreachable() }
    func readText(_ path: ScopedPath, maximumBytes: Int) throws -> TextContent {
        throw unreachable()
    }
    func grep(
        _ scope: ScopedPath, pattern: String, ignoreCase: Bool, namePattern: String?,
        maximumMatches: Int, maximumFiles: Int, maximumFileBytes: Int
    ) throws -> GrepPage { throw unreachable() }
    func tags(of path: ScopedPath) throws -> [String] { throw unreachable() }
    func write(_ text: String, to path: ScopedPath, append: Bool) throws -> WriteOutcome {
        throw unreachable()
    }
    func edit(_ path: ScopedPath, find: String, replace: String, expectedCount: Int) throws
        -> EditOutcome
    { throw unreachable() }
    func makeDirectory(_ path: ScopedPath, createIntermediates: Bool) throws -> FileStat {
        throw unreachable()
    }
    func move(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    { throw unreachable() }
    func copy(from source: ScopedPath, to destination: ScopedPath, overwrite: Bool) throws
        -> TransferOutcome
    { throw unreachable() }
    func setTags(_ tags: [String], on path: ScopedPath) throws -> [String] { throw unreachable() }
    func trash(_ path: ScopedPath) throws -> TrashOutcome { throw unreachable() }
}

/// The safety property this whole server exists for: a path outside the configured roots
/// must never resolve, however it is spelled.
@Suite("Path scope")
struct PathScopeTests {

    private func scope(
        read: [String] = ["/Users/invented/Documents", "/Users/invented/Code"],
        write: [String] = ["/Users/invented/Documents/Scratch"],
        resolutions: [String: String] = [:]
    ) -> PathScope {
        var configuration = Configuration()
        configuration.readRoots = read
        configuration.writeRoots = write
        return PathScope(
            configuration: configuration, store: StubStore(resolutions: resolutions))
    }

    // MARK: Reads

    @Test("A path inside a read root resolves")
    func insideReadRootResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents/notes.md", for: .read)
        #expect(resolved.path == "/Users/invented/Documents/notes.md")
        #expect(resolved.access == .read)
    }

    @Test("A read root itself resolves")
    func rootItselfResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents", for: .read)
        #expect(resolved.path == "/Users/invented/Documents")
    }

    @Test("A path outside every read root is refused")
    func outsideReadRootIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Library/Keychains", for: .read)
        }
    }

    /// The reason canonicalisation happens before comparison. Compared raw, this string
    /// starts with a read root and would pass a prefix test while landing in the home
    /// directory.
    @Test("Dot-dot cannot climb out of a read root")
    func dotDotCannotEscape() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents/../../../etc/passwd", for: .read)
        }
    }

    /// The other half of the same rule. A symlink inside an allowed root that points
    /// somewhere else entirely must be judged by where it lands, not by its own path.
    @Test("A symlink pointing out of the scope is judged by where it lands")
    func symlinkOutOfScopeIsRefused() {
        let escaping = scope(resolutions: [
            "/Users/invented/Documents/shortcut": "/Users/invented/Library/Secrets"
        ])
        #expect(throws: ToolError.self) {
            try escaping.resolve("/Users/invented/Documents/shortcut", for: .read)
        }
    }

    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a root compared in its raw form
    /// would reject every path that resolved through it. The roots are canonicalised too.
    @Test("A root that is itself a symlink still governs its subtree")
    func symlinkedRootStillGoverns() throws {
        var configuration = Configuration()
        configuration.readRoots = ["/tmp/invented"]
        configuration.writeRoots = []
        let store = StubStore(resolutions: [
            "/tmp/invented": "/private/tmp/invented",
            "/tmp/invented/file.txt": "/private/tmp/invented/file.txt",
        ])
        let pathScope = PathScope(configuration: configuration, store: store)

        let resolved = try pathScope.resolve("/tmp/invented/file.txt", for: .read)
        #expect(resolved.path == "/private/tmp/invented/file.txt")
    }

    /// A sibling whose name merely begins with a root's name is not inside it.
    @Test("A prefix match on the name alone is not containment")
    func siblingWithSharedPrefixIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents-private/secret", for: .read)
        }
    }

    // MARK: Writes

    @Test("A path inside a write root resolves for writing")
    func insideWriteRootResolves() throws {
        let resolved = try scope().resolve(
            "/Users/invented/Documents/Scratch/draft.md", for: .write)
        #expect(resolved.access == .write)
    }

    /// The asymmetry the server is designed around: broad read, narrow write. A path that
    /// is perfectly readable must still be refused for writing.
    @Test("A readable path is not automatically writable")
    func readableIsNotWritable() throws {
        let pathScope = scope()
        _ = try pathScope.resolve("/Users/invented/Documents/notes.md", for: .read)

        #expect(throws: ToolError.self) {
            try pathScope.resolve("/Users/invented/Documents/notes.md", for: .write)
        }
    }

    @Test("A write root outside every read root governs nothing and is reported")
    func strandedWriteRootIsReported() {
        var configuration = Configuration()
        configuration.readRoots = ["/Users/invented/Documents"]
        configuration.writeRoots = ["/Users/invented/Elsewhere"]
        let pathScope = PathScope(configuration: configuration, store: StubStore())

        #expect(pathScope.strandedWriteRoots == ["/Users/invented/Elsewhere"])
        // A write there fails the read check first, which is the outer boundary.
        #expect(throws: ToolError.self) {
            try pathScope.resolve("/Users/invented/Elsewhere/file", for: .write)
        }
    }

    // MARK: Nothing configured

    @Test("With no read roots nothing resolves at all")
    func noReadRootsRefusesEverything() {
        let empty = scope(read: [], write: [])
        #expect(throws: ToolError.self) { try empty.resolve("/Users/invented", for: .read) }
    }

    @Test("With no write roots the server is read-only")
    func noWriteRootsMakesItReadOnly() throws {
        let readOnly = scope(write: [])
        _ = try readOnly.resolve("/Users/invented/Documents/notes.md", for: .read)
        #expect(throws: ToolError.self) {
            try readOnly.resolve("/Users/invented/Documents/notes.md", for: .write)
        }
    }

    @Test("An empty path is refused")
    func emptyPathIsRefused() {
        #expect(throws: ToolError.self) { try scope().resolve("   ", for: .read) }
    }
}
