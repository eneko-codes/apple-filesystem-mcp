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
    /// True for a link whatever it points at. `kind` already describes the destination;
    /// this is what lets a walk refuse to follow it.
    public let isSymbolicLink: Bool
    /// A folder the Finder shows as one file, such as an application.
    public let isPackage: Bool

    public init(
        path: String, name: String, kind: FileKind, sizeBytes: Int, modifiedAt: Date?,
        isHidden: Bool, contentHash: String? = nil, hashNote: String? = nil,
        isSymbolicLink: Bool = false, isPackage: Bool = false
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.isHidden = isHidden
        self.contentHash = contentHash
        self.hashNote = hashNote
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
    }

    /// The same entry with the outcome of hashing it.
    func withHash(_ contentHash: String?, note: String?) -> FileEntry {
        FileEntry(
            path: path, name: name, kind: kind, sizeBytes: sizeBytes, modifiedAt: modifiedAt,
            isHidden: isHidden, contentHash: contentHash, hashNote: note,
            isSymbolicLink: isSymbolicLink, isPackage: isPackage)
    }
}

/// One page of a folder's items.
public struct FileListing: Sendable, Equatable {
    public let entries: [FileEntry]
    /// Every item the listing shows, on this page or another.
    public let total: Int
    /// Hidden items left out because they were not asked for.
    public let hidden: Int
    /// True when hashing ran out of time, so the page holds fewer rows than were asked for.
    public let stoppedForTime: Bool

    public init(entries: [FileEntry], total: Int, hidden: Int, stoppedForTime: Bool) {
        self.entries = entries
        self.total = total
        self.hidden = hidden
        self.stoppedForTime = stoppedForTime
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

/// One page of a depth-limited walk.
public struct FileTree: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public let entry: FileEntry
        public let depth: Int
        /// A folder the walk tried to open and could not, so nothing is shown under it.
        public let couldNotBeListed: Bool

        public init(entry: FileEntry, depth: Int, couldNotBeListed: Bool = false) {
            self.entry = entry
            self.depth = depth
            self.couldNotBeListed = couldNotBeListed
        }
    }

    public let root: String
    public let maximumDepth: Int
    public let nodes: [Node]
    /// Every entry of the tree, or `nil` when the walk stopped before reaching its end, so
    /// a partial tree is never mistaken for a complete one.
    public let total: Int?
    /// How many entries the walk reached, on this page or before it.
    public let walked: Int
    /// Hidden items met in the folders walked and left out because they were not asked for.
    public let hidden: Int
    /// Folders the walk could not open, on this page or before it.
    public let foldersNotListed: Int
    public let stoppedForTime: Bool

    public init(
        root: String, maximumDepth: Int, nodes: [Node], total: Int?, walked: Int, hidden: Int,
        foldersNotListed: Int, stoppedForTime: Bool
    ) {
        self.root = root
        self.maximumDepth = maximumDepth
        self.nodes = nodes
        self.total = total
        self.walked = walked
        self.hidden = hidden
        self.foldersNotListed = foldersNotListed
        self.stoppedForTime = stoppedForTime
    }
}

// MARK: - Content

/// A window of a text file's characters.
public struct TextWindow: Sendable, Equatable {
    public let text: String
    /// Characters in the whole file, of which `text` is a part. When `isWholeFile` is
    /// false it is only how many were counted before the time ran out.
    public let totalCharacters: Int
    /// Name of the encoding that decoded cleanly.
    public let encodingName: String
    /// The file's size, or how much of it was read when `isWholeFile` is false.
    public let totalBytes: Int
    /// False when the time ran out after the window was cut but before the file ended, so
    /// its length is not known.
    public let isWholeFile: Bool

    public init(
        text: String, totalCharacters: Int, encodingName: String, totalBytes: Int,
        isWholeFile: Bool = true
    ) {
        self.text = text
        self.totalCharacters = totalCharacters
        self.encodingName = encodingName
        self.totalBytes = totalBytes
        self.isWholeFile = isWholeFile
    }
}

/// One page of matching lines.
public struct GrepPage: Sendable, Equatable {
    public struct Match: Sendable, Equatable {
        public let path: String
        public let lineNumber: Int
        /// The line without the white space around it, cut to the width a row may take.
        public let line: String
        public let isClipped: Bool

        public init(path: String, lineNumber: Int, line: String, isClipped: Bool = false) {
            self.path = path
            self.lineNumber = lineNumber
            self.line = line
            self.isClipped = isClipped
        }
    }

    /// Why the scan ended.
    public enum Stop: Sendable, Equatable {
        /// Every file was searched.
        case finished
        /// The page was full and one more match was met, so more exist.
        case pageFull
        /// The ceiling on files searched was reached with files still unread.
        case fileCeiling
        case timeLimit
    }

    public let matches: [Match]
    /// Matches met before the scan ended, on this page or before it.
    public let matchesFound: Int
    public let filesSearched: Int
    /// Files passed over because they are larger than one scan reads.
    public let filesTooLarge: Int
    /// Files passed over because they are binary or in no encoding that could be decoded.
    public let filesNotText: Int
    /// Files that could not be opened.
    public let filesNotRead: Int
    /// Folders that could not be opened, so nothing under them was searched.
    public let foldersNotListed: Int
    public let stop: Stop

    public init(
        matches: [Match], matchesFound: Int, filesSearched: Int, filesTooLarge: Int,
        filesNotText: Int, filesNotRead: Int, foldersNotListed: Int, stop: Stop
    ) {
        self.matches = matches
        self.matchesFound = matchesFound
        self.filesSearched = filesSearched
        self.filesTooLarge = filesTooLarge
        self.filesNotText = filesNotText
        self.filesNotRead = filesNotRead
        self.foldersNotListed = foldersNotListed
        self.stop = stop
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
    /// A write root outside every read root. It governs nothing, because a write has to
    /// satisfy the read check too.
    public let isStranded: Bool

    public init(
        path: String, access: Access, state: RootState, canonicalPath: String? = nil,
        isStranded: Bool = false
    ) {
        self.path = path
        self.access = access
        self.state = state
        self.canonicalPath = canonicalPath
        self.isStranded = isStranded
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
