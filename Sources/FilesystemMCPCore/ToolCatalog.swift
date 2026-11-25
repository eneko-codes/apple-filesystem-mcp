import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Naming diverges from the sibling servers on purpose. There, reads carry no verb and
/// writes start `create_`/`update_`/`delete_`. Here every name starts `filesystem_` —
/// the domain is a prefix rather than a suffix — and the verb follows it, so
/// `filesystem_write`, `filesystem_move` and `filesystem_trash` still sort apart from
/// `filesystem_list` and `filesystem_stat` at a glance. The convention that actually
/// matters is kept: a write is never spelled like a read.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, so the dispatcher,
    /// the error messages and the tests all name a tool the same way.
    public static let statusName = "filesystem_status"
    public static let listName = "filesystem_list"
    public static let statName = "filesystem_stat"
    public static let treeName = "filesystem_tree"
    public static let readTextName = "filesystem_read_text"
    public static let grepName = "filesystem_grep"
    public static let tagsGetName = "filesystem_tags_get"
    public static let writeName = "filesystem_write"
    public static let editName = "filesystem_edit"
    public static let makeDirectoryName = "filesystem_mkdir"
    public static let moveName = "filesystem_move"
    public static let copyName = "filesystem_copy"
    public static let tagsSetName = "filesystem_tags_set"
    public static let trashName = "filesystem_trash"

    /// Every tool that changes something on disk. Kept as data rather than inferred from
    /// the name, because the naming convention is a habit and this is a boundary.
    public static let writeTools: Set<String> = [
        writeName, editName, makeDirectoryName, moveName, copyName, tagsSetName, trashName,
    ]

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with
    // no optional argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a
    // full page of the widest ordinary rows of every listing to hold both to that.
    public static let offsetRange = 0...10_000_000
    public static let rootLimitRange = 1...100
    public static let defaultRootLimit = 25
    public static let listLimitRange = 1...200
    public static let defaultListLimit = 50
    public static let treeLimitRange = 1...300
    public static let defaultTreeLimit = 100
    public static let grepLimitRange = 1...100
    public static let defaultGrepLimit = 25
    public static let tagLimitRange = 1...500
    public static let defaultTagLimit = 100

    public static let depthRange = 1...12
    public static let defaultDepth = 3

    /// How far `filesystem_tree` walks past a page to count the tree. A larger tree gets
    /// no total: counting a home folder would mean walking all of it on every call.
    public static let treeCountCeiling = 10_000

    /// `filesystem_grep` walks files itself. These bound the walk rather than the answer.
    public static let grepFileCeiling = 5_000
    public static let grepFileBytes = 4_194_304
    /// The width a matching line is clipped to in its row.
    public static let grepLineWidth = 200

    /// The window on a file's text. The maximum leaves a quarter of the longest result for
    /// the header and the notices; `ToolStandard.fitting` shrinks a window whose characters
    /// take more UTF-16 units than that. A file can hold far more characters than a listing
    /// has rows, so the offset has its own range, the largest a JSON client keeps exact.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult * 3 / 4)
    public static let defaultMaxCharacters = ToolStandard.usualPage
    public static let characterOffsetRange = 0...1_000_000_000_000

    /// How much of a file `filesystem_read_text` holds at once while it reads.
    public static let readChunkBytes = 1_048_576
    /// The largest file read in an encoding other than UTF-8, which has to be decoded from
    /// the whole file in memory.
    public static let wholeFileBytes = 16_777_216

    /// The width a list of tags is clipped to where it is one field of a larger result.
    public static let tagsFieldWidth = 500

    /// An exact number, refused outside its range instead of moved.
    public static let expectedCountRange = 1...1000

    /// The longest path the system accepts, in bytes. A longer argument is refused before
    /// anything is resolved.
    public static let longestPathBytes = Int(PATH_MAX)

    public static func all() -> [Tool] {
        [
            status, list, stat, tree, readText, grep, tagsGet,
            write, edit, makeDirectory, move, copy, tagsSet, trash,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property whose `type` is a union and hands the
    /// model a bare `{}` in its place. Text fields survive that by luck — an unschema'd
    /// string is still sent as a string — but an array alongside them is serialised to a
    /// string and rejected on arrival. Nothing here ever advertises a nullable type; a
    /// list is cleared with `[]`, a string with `""`.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description), "default": .bool(def),
        ])
    }

    private static func integer(
        _ description: String, range: ClosedRange<Int>, default def: Int
    ) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static var scanSeconds: Int64 { FilesystemTools.defaultScanBudget.components.seconds }
    private static var timeoutSeconds: Int64 { FilesystemTools.defaultTimeout.components.seconds }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static let pathHelp = """
        Absolute path, or one starting with ~. It is canonicalised — ~ expanded, .. \
        removed, symlinks followed — and then checked against the configured folders \
        before anything happens.
        """

    private static let confirmProperty: Value = .object([
        "type": .string("boolean"),
        "description": .string("Must be true. Without it the call is refused."),
    ])

    private static let hiddenProperty: Value = boolean(
        "Include dotfiles and items macOS marks hidden.", default: false)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Filesystem scope and permissions",
        description: """
            Reports which folders this server may read and which it may change, \
            \(defaultRootLimit) to a page, and whether macOS is actually letting it reach \
            each one. Reads no file contents. When more folders are configured than the \
            page holds, the first lines of the result give the offset of the next page: \
            pass limit (up to \(rootLimitRange.upperBound)) and offset.

            Call it first in any session that will touch files, and again whenever another \
            tool fails: it separates "outside the configured scope" from "macOS refused", \
            which are two different problems with two different fixes.
            """,
        inputSchema: object(properties: [
            "limit": limit("configured folders", range: rootLimitRange, default: defaultRootLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let list = Tool(
        name: listName,
        title: "List a folder",
        description: """
            One row per item directly inside a folder, \(defaultListLimit) to a page, \
            folders first and then by name: kind, name, size, modification date and a \
            content hash. Hidden items are left out and counted; include_hidden lists them. \
            When the folder holds more than the page, the first lines of the result say how \
            many items there are and the offset of the next page: pass limit (up to \
            \(listLimitRange.upperBound)) and offset. Does not recurse — use \
            filesystem_tree for that.

            The hash is the first 16 hex characters of the file's SHA-256, and it is here so \
            that finding duplicates is your job over raw rows rather than a heuristic \
            compiled into this server. Two files with the same size and the same hash are \
            the same bytes. Only the files on the page are hashed. Files above the \
            configured hash ceiling are listed with a note instead; pass hashes=false to \
            skip hashing entirely, which is much faster on a folder of large files. A page \
            whose hashing takes more than \(scanSeconds) seconds ends early and says where \
            to resume.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to list. \(pathHelp)"),
                "include_hidden": hiddenProperty,
                "hashes": boolean(
                    "Compute a content hash per file. Reads every byte of every file on "
                        + "the page, so turn it off when you only want names and sizes.",
                    default: true),
                "limit": limit("items", range: listLimitRange, default: defaultListLimit),
                "offset": offset,
            ],
            required: ["path"]),
        annotations: readOnly)

    static let stat = Tool(
        name: statName,
        title: "Everything about one path",
        description: """
            Full metadata for a single file or folder: kind, UTI, Finder's type \
            description, size in bytes, content hash, created and modified dates, owner, \
            POSIX mode, symlink destination, Finder tags, and whether this process can \
            actually read and write it. A list of tags longer than \(tagsFieldWidth) \
            characters is clipped and says so; filesystem_tags_get lists them all.

            "Can this process write it" is a different question from "does the allow-list \
            permit it": a file can be in a write root and still be read-only on disk, and \
            this is where the two are separated.
            """,
        inputSchema: object(
            properties: ["path": string("File or folder to inspect. \(pathHelp)")],
            required: ["path"]),
        annotations: readOnly)

    static let tree = Tool(
        name: treeName,
        title: "Depth-limited folder tree",
        description: """
            Walks a folder \(defaultDepth) levels deep and returns an indented tree of \
            what is in it, \(defaultTreeLimit) entries to a page: each folder's items in \
            name order, a folder followed by what it holds. Sizes only; no hashes — \
            filesystem_list is where a row carries everything. Hidden items are left out \
            and counted; include_hidden shows them. When the tree holds more than the \
            page, the first lines of the result give the offset of the next page: pass \
            limit (up to \(treeLimitRange.upperBound)) and offset, or ask for less with a \
            lower depth or a subfolder.

            The result states how many entries the tree has when that is at most \
            \(treeCountCeiling); for a larger tree it says only that more exist. A page far \
            into a large tree walks everything before it again, so it is slower. A walk \
            that takes more than \(scanSeconds) seconds returns what it reached and says \
            it is partial, because a partial tree that reads as a whole one is how a \
            folder gets concluded to be empty.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to walk. \(pathHelp)"),
                "depth": integer(
                    "How many levels below 'path' to descend. 1 is the folder's own contents.",
                    range: depthRange, default: defaultDepth),
                "include_hidden": hiddenProperty,
                "limit": limit("entries", range: treeLimitRange, default: defaultTreeLimit),
                "offset": offset,
            ],
            required: ["path"]),
        annotations: readOnly)

    static let readText = Tool(
        name: readTextName,
        title: "Read a text file",
        description: """
            Returns the first \(defaultMaxCharacters) characters of a text file, with its \
            encoding, its size and its length in characters. When the file is longer, the \
            first lines of the result say how many characters it has and the \
            character_offset that returns the rest: pass character_offset and \
            max_characters (up to \(maxCharactersRange.upperBound)) to read any other \
            window of it.

            A UTF-8 file of any size is read this way. A window is counted in characters, \
            so every call reads the file from its start: a very large file is slow. A read \
            that has cut its window but not reached the end of the file within \
            \(scanSeconds) seconds returns the window with a partial notice; one that has \
            not reached the window is answered with an error, and a smaller \
            character_offset reaches an earlier part. A file in another encoding (UTF-16 by its byte-order mark, otherwise a \
            guess such as ISO Latin 1 or Mac OS Roman) is read only up to \
            \(Format.bytes(wholeFileBytes)). The answer says which encoding decoded it.

            To find something in a file of up to \(Format.bytes(grepFileBytes)), \
            filesystem_grep returns the matching lines without reading the rest here. A \
            PDF needs apple-pdf-mcp's pdf_read tool, and a scan or photo needs \
            apple-vision-mcp's vision_ocr — this tool will refuse both.
            """,
        inputSchema: object(
            properties: [
                "path": string("File to read. \(pathHelp)"),
                "character_offset": integer(
                    """
                    Number of characters to skip. A result that does not hold the whole \
                    file says, in its first lines, the value to pass for the rest.
                    """, range: characterOffsetRange, default: 0),
                "max_characters": integer(
                    "The most characters to return.", range: maxCharactersRange,
                    default: defaultMaxCharacters),
            ],
            required: ["path"]),
        annotations: readOnly)

    static let grep = Tool(
        name: grepName,
        title: "Regex search inside a folder's files",
        description: """
            Walks a folder and returns the lines matching a regular expression, \
            \(defaultGrepLimit) to a page, each with its path and line number, in the \
            order filesystem_tree walks. When more lines match, the first lines of the \
            result give the offset of the next page: pass limit (up to \
            \(grepLimitRange.upperBound)) and offset. A line is shown up to \
            \(grepLineWidth) characters; filesystem_read_text reads the file itself.

            This is the tool for a pattern rather than a word, and the fallback for what \
            apple-spotlight-mcp's spotlight_search has not indexed. It reads files itself, \
            so it is far slower than a Spotlight search — scope it to the smallest folder \
            that could hold the answer, and narrow further with 'name_pattern'.

            Not searched: hidden items, the insides of packages such as applications, \
            anything behind a symbolic link, binary files and files larger than \
            \(Format.bytes(grepFileBytes)). The result counts the files it passed over. The \
            scan stops after \(grepFileCeiling) files or \(scanSeconds) seconds and says \
            so; narrow by path or name_pattern to search what it did not reach. ICU \
            regular expressions, the same dialect as NSRegularExpression.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to walk. \(pathHelp)"),
                "pattern": string("Regular expression to match against each line."),
                "ignore_case": boolean("Match case-insensitively.", default: true),
                "name_pattern": string(
                    """
                    Only read files whose name matches this regular expression, ignoring \
                    case, for example "\\\\.swift$". Skipping files you cannot need is the \
                    difference between seconds and minutes.
                    """),
                "limit": limit("matching lines", range: grepLimitRange, default: defaultGrepLimit),
                "offset": offset,
            ],
            required: ["path", "pattern"]),
        annotations: readOnly)

    static let tagsGet = Tool(
        name: tagsGetName,
        title: "Read Finder tags",
        description: """
            Lists the Finder tags on one file or folder, \(defaultTagLimit) to a page in \
            the order Finder keeps them. When there are more, the first lines of the \
            result give the offset of the next page: pass limit (up to \
            \(tagLimitRange.upperBound)) and offset. Tags are an ordinary extended \
            attribute, so they are readable without opening the file, and they are how many \
            people actually organise a folder that has no useful structure in its names.
            """,
        inputSchema: object(
            properties: [
                "path": string("File or folder. \(pathHelp)"),
                "limit": limit("tags", range: tagLimitRange, default: defaultTagLimit),
                "offset": offset,
            ],
            required: ["path"]),
        annotations: readOnly)

    // MARK: Writes

    static let write = Tool(
        name: writeName,
        title: "Write a text file",
        description: """
            Creates a text file, or replaces one, or appends to one. UTF-8 only. The \
            destination must be inside a configured WRITABLE folder, which is a narrower \
            list than the readable one.

            Replacing an existing file requires overwrite=true and the old contents are \
            gone — this server does not keep a copy. Prefer filesystem_edit for a change \
            to part of a file, and append=true for adding to a log. The parent folder must \
            already exist; filesystem_mkdir makes it.
            """,
        inputSchema: object(
            properties: [
                "path": string("File to write. \(pathHelp)"),
                "content": string("The text to write. Written as UTF-8."),
                "append": boolean(
                    "Add to the end of the file instead of replacing it.", default: false),
                "overwrite": boolean(
                    "Required to replace a file that already exists. Ignored when appending.",
                    default: false),
            ],
            required: ["path", "content"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let edit = Tool(
        name: editName,
        title: "Replace exact text in a file",
        description: """
            Replaces an exact string in a text file with another. The match is literal — \
            whitespace, indentation and line endings included — and no regular expression is \
            involved.

            Nothing is written unless the number of occurrences found matches \
            'expected_count', which defaults to 1. That is the safety: an edit meant for one \
            place cannot silently hit five. Read the file with filesystem_read_text first \
            and copy the passage from what it returned; a hand-typed 'find' with the wrong \
            indentation simply will not match.
            """,
        inputSchema: object(
            properties: [
                "path": string("File to edit. \(pathHelp)"),
                "find": string("Exact text to replace, whitespace included."),
                "replace": string("Text to put in its place. \"\" deletes the passage."),
                "expected_count": integer(
                    """
                    How many occurrences you expect. The file is not touched if it \
                    disagrees. A number outside the range is refused, not adjusted.
                    """, range: expectedCountRange, default: 1),
            ],
            required: ["path", "find", "replace"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let makeDirectory = Tool(
        name: makeDirectoryName,
        title: "Create a folder",
        description: """
            Creates a folder inside a configured writable folder. Creating the intermediate \
            folders along the way is the default; turn it off to be told when the parent is \
            missing rather than having it invented.

            A folder that already exists is not an error — the result describes what is \
            there.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to create. \(pathHelp)"),
                "create_intermediates": boolean(
                    "Create any missing parent folders too.", default: true),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let move = Tool(
        name: moveName,
        title: "Move or rename",
        description: """
            Moves a file or folder to a new path, which is also how it is renamed. BOTH ends \
            must be inside a configured writable folder — moving something out of the \
            writable scope would be a way around the boundary, so it is refused.

            Refuses to clobber anything at the destination unless overwrite=true. A folder \
            cannot be moved into itself. A move to another volume is a copy, and one that \
            takes more than \(timeoutSeconds) seconds is answered with an error while it \
            carries on: look at the destination before repeating it.
            """,
        inputSchema: object(
            properties: [
                "from": string("What to move. \(pathHelp)"),
                "to": string("Where it goes, including the new name. \(pathHelp)"),
                "overwrite": boolean(
                    "Required to replace something already at the destination.", default: false),
            ],
            required: ["from", "to"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let copy = Tool(
        name: copyName,
        title: "Copy a file or folder",
        description: """
            Copies a file or folder. The SOURCE need only be readable; the DESTINATION must \
            be inside a configured writable folder. That asymmetry is deliberate: copying a \
            document out of a read-only folder into a working one is the common case, and it \
            changes nothing where it came from.

            Refuses to clobber anything at the destination unless overwrite=true. A copy \
            that takes more than \(timeoutSeconds) seconds is answered with an error while \
            it carries on: look at the destination before repeating it.
            """,
        inputSchema: object(
            properties: [
                "from": string("What to copy. Must be readable. \(pathHelp)"),
                "to": string("Where the copy goes. Must be writable. \(pathHelp)"),
                "overwrite": boolean(
                    "Required to replace something already at the destination.", default: false),
            ],
            required: ["from", "to"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
    )

    static let tagsSet = Tool(
        name: tagsSetName,
        title: "Set Finder tags",
        description: """
            Replaces ALL Finder tags on a file or folder with the list given. [] removes \
            every tag. This is a replace, not an add: read the current tags with \
            filesystem_tags_get first and send them back along with the new one if they \
            should be kept.

            The path must be inside a configured writable folder. The result repeats the \
            tags as they are now, clipped to \(tagsFieldWidth) characters.
            """,
        inputSchema: object(
            properties: [
                "path": string("File or folder to tag. \(pathHelp)"),
                "tags": stringArray("The complete new set of tag names. [] removes all tags."),
            ],
            required: ["path", "tags"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let trash = Tool(
        name: trashName,
        title: "Move to the Trash",
        description: """
            Moves a file or folder to the Trash and reports where it landed. Requires \
            confirm=true.

            THIS SERVER HAS NO DELETE. Nothing it removes is unrecoverable: the item sits in \
            the Trash until the person empties it, and the Finder's File → Put Back returns \
            it to exactly where it was. Emptying the Trash is not something this server can \
            do, and that is the design.

            The path must be inside a configured writable folder.
            """,
        inputSchema: object(
            properties: [
                "path": string("File or folder to move to the Trash. \(pathHelp)"),
                "confirm": confirmProperty,
            ],
            required: ["path", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
