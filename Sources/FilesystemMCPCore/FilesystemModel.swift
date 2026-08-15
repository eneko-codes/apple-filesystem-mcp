import Foundation

/// Value types crossing the store seam. Nothing here imports a filesystem API, which is
/// what lets the tests build a whole tree in memory.

// MARK: - Paths

/// What a caller intends to do with a path. Carried on `ScopedPath` so the check that
/// approved it is visible at the call site.
public enum Access: String, Sendable, Equatable {
    case read
    case write
}

// `ScopedPath` deliberately lives in PathScope.swift instead: its initialiser is
// fileprivate, so that file is the only place in the module able to mint one.

/// The result of canonicalising a raw path string, before any scope check.
public struct CanonicalPath: Sendable, Equatable {
    public let path: String
    public let exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

// MARK: - Entries

public enum FileKind: String, Sendable, Equatable {
    case file
    case directory
    /// A symlink whose target is missing. A symlink that resolves is reported as
    /// whatever it points at, because that is what reading it would give you.
    case brokenSymlink
    case other
}

/// One row of a listing. `sizeBytes` and `contentHash` are here so duplicate hunting is
/// Claude's job over raw rows rather than a heuristic compiled into this binary.
public struct FileEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let kind: FileKind
    public let sizeBytes: Int
    public let modifiedAt: Date?
    public let isHidden: Bool
    /// First 16 hex characters of the file's SHA-256. `nil` for a directory, for a file
    /// above the configured hash ceiling, or when hashing was not asked for.
    public let contentHash: String?
    /// Why `contentHash` is nil, when the reason is worth showing ("too large").
    public let hashNote: String?

    public init(
        path: String, name: String, kind: FileKind, sizeBytes: Int, modifiedAt: Date?,
        isHidden: Bool, contentHash: String? = nil, hashNote: String? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.isHidden = isHidden
        self.contentHash = contentHash
        self.hashNote = hashNote
    }
}

/// Everything one path knows about itself.
public struct FileStat: Sendable, Equatable {
    public let entry: FileEntry
    public let createdAt: Date?
    public let contentTypeIdentifier: String?
    public let kindDescription: String?
    public let ownerName: String?
    public let posixPermissions: Int?
    public let isReadableByProcess: Bool
    public let isWritableByProcess: Bool
    public let symlinkDestination: String?
    /// Directories only: how many entries are directly inside.
    public let childCount: Int?
    public let tags: [String]

    public init(
        entry: FileEntry, createdAt: Date? = nil, contentTypeIdentifier: String? = nil,
        kindDescription: String? = nil, ownerName: String? = nil, posixPermissions: Int? = nil,
        isReadableByProcess: Bool = true, isWritableByProcess: Bool = false,
        symlinkDestination: String? = nil, childCount: Int? = nil, tags: [String] = []
    ) {
        self.entry = entry
        self.createdAt = createdAt
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kindDescription = kindDescription
        self.ownerName = ownerName
        self.posixPermissions = posixPermissions
        self.isReadableByProcess = isReadableByProcess
        self.isWritableByProcess = isWritableByProcess
        self.symlinkDestination = symlinkDestination
        self.childCount = childCount
        self.tags = tags
    }
}

/// A depth-limited walk. `truncated` is set when the entry ceiling stopped it, so a
/// partial tree is never mistaken for a complete one.
public struct FileTree: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public let entry: FileEntry
        public let depth: Int

        public init(entry: FileEntry, depth: Int) {
            self.entry = entry
            self.depth = depth
        }
    }

    public let root: String
    public let nodes: [Node]
    public let truncated: Bool

    public init(root: String, nodes: [Node], truncated: Bool) {
        self.root = root
        self.nodes = nodes
        self.truncated = truncated
    }
}

// MARK: - Content

public struct TextContent: Sendable, Equatable {
    public let text: String
    /// Name of the encoding that decoded cleanly, or the one that was assumed.
    public let encodingName: String
    public let bytesRead: Int
    public let totalBytes: Int
    public var truncated: Bool { bytesRead < totalBytes }

    public init(text: String, encodingName: String, bytesRead: Int, totalBytes: Int) {
        self.text = text
        self.encodingName = encodingName
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
    }
}

public struct GrepPage: Sendable, Equatable {
    public struct Match: Sendable, Equatable {
        public let path: String
        public let lineNumber: Int
        public let line: String

        public init(path: String, lineNumber: Int, line: String) {
            self.path = path
            self.lineNumber = lineNumber
            self.line = line
        }
    }

    public let matches: [Match]
    public let filesScanned: Int
    public let filesSkipped: Int
    /// True when the match limit or the file ceiling cut the walk short.
    public let truncated: Bool

    public init(matches: [Match], filesScanned: Int, filesSkipped: Int, truncated: Bool) {
        self.matches = matches
        self.filesScanned = filesScanned
        self.filesSkipped = filesSkipped
        self.truncated = truncated
    }
}

// MARK: - Status

/// What one configured root is actually worth right now. There is no API that asks TCC
/// "may I read this folder?", so the only honest answer comes from trying.
public enum RootState: String, Sendable, Equatable {
    case reachable
    case missing
    /// The path is there and macOS refused. This is the TCC denial, and the one the
    /// status message has to explain how to fix.
    case notPermitted
}

public struct RootProbe: Sendable, Equatable {
    public let path: String
    public let access: Access
    public let state: RootState
    /// Set when the configured root does not canonicalise to itself — a symlinked root
    /// silently governs a different subtree than the one that was typed.
    public let canonicalPath: String?

    public init(path: String, access: Access, state: RootState, canonicalPath: String? = nil) {
        self.path = path
        self.access = access
        self.state = state
        self.canonicalPath = canonicalPath
    }
}

// MARK: - Write outcomes

public struct WriteOutcome: Sendable, Equatable {
    public let path: String
    public let bytesWritten: Int
    public let created: Bool
    public let previousSizeBytes: Int?

    public init(path: String, bytesWritten: Int, created: Bool, previousSizeBytes: Int?) {
        self.path = path
        self.bytesWritten = bytesWritten
        self.created = created
        self.previousSizeBytes = previousSizeBytes
    }
}

public struct EditOutcome: Sendable, Equatable {
    public let path: String
    public let replacements: Int
    public let bytesWritten: Int

    public init(path: String, replacements: Int, bytesWritten: Int) {
        self.path = path
        self.replacements = replacements
        self.bytesWritten = bytesWritten
    }
}

public struct TransferOutcome: Sendable, Equatable {
    public let from: String
    public let to: String
    public let replacedExisting: Bool

    public init(from: String, to: String, replacedExisting: Bool) {
        self.from = from
        self.to = to
        self.replacedExisting = replacedExisting
    }
}

/// Where the file went. `filesystem_trash` never deletes, so the answer always names a
/// place the file can be recovered from.
public struct TrashOutcome: Sendable, Equatable {
    public let originalPath: String
    public let trashPath: String?

    public init(originalPath: String, trashPath: String?) {
        self.originalPath = originalPath
        self.trashPath = trashPath
    }
}
