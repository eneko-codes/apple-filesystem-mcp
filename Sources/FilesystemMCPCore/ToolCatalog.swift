import Foundation
import MCP

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

    /// Names are constants rather than being read back off a `Tool`, because a tool
    /// whose schema depends on the configuration has to be built as a function and its
    /// name would then have nowhere stable to live.
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

    /// Built from the live configuration so a description never states a limit the
    /// running server does not actually enforce.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [
            status, list, stat, tree, readText(configuration), grep, tagsGet,
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
        _ description: String, minimum: Int, maximum: Int, default def: Int
    ) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

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

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Filesystem scope and permissions",
        description: """
            Reports which folders this server may read, which it may change, and whether \
            macOS is actually letting it reach them. Reads no file contents.

            Call it first in any session that will touch files, and again whenever another \
            tool fails: it separates "outside the configured scope" from "macOS refused", \
            which are two different problems with two different fixes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let list = Tool(
        name: listName,
        title: "List a folder",
        description: """
            One row per item directly inside a folder: kind, name, size, modification date \
            and a content hash. Does not recurse — use filesystem_tree for that.

            The hash is the first 16 hex characters of the file's SHA-256, and it is here so \
            that finding duplicates is your job over raw rows rather than a heuristic \
            compiled into this server. Two files with the same size and the same hash are \
            the same bytes. Files above the configured hash ceiling are listed with a note \
            instead; pass hashes=false to skip hashing entirely, which is much faster on a \
            folder of large files.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to list. \(pathHelp)"),
                "include_hidden": hiddenProperty,
                "hashes": boolean(
                    "Compute a content hash per file. Reads every byte of every file, so "
                        + "turn it off when you only want names and sizes.", default: true),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let stat = Tool(
        name: statName,
        title: "Everything about one path",
        description: """
            Full metadata for a single file or folder: kind, UTI, Finder's type \
            description, size in bytes, content hash, created and modified dates, owner, \
            POSIX mode, symlink destination, Finder tags, and whether this process can \
            actually read and write it.

            "Can this process write it" is a different question from "does the allow-list \
            permit it": a file can be in a write root and still be read-only on disk, and \
            this is where the two are separated.
            """,
        inputSchema: object(
            properties: ["path": string("File or folder to inspect. \(pathHelp)")],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let tree = Tool(
        name: treeName,
        title: "Depth-limited folder tree",
        description: """
            Walks a folder to a bounded depth and returns an indented tree of what is in it. \
            Sizes only; no hashes — filesystem_list is where a row carries everything.

            Depth is capped and so is the number of entries. A truncated walk says so \
            rather than looking complete, because a partial tree that reads as a whole one \
            is how a folder gets concluded to be empty.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to walk. \(pathHelp)"),
                "depth": integer(
                    "How many levels below 'path' to descend. 1 is the folder's own contents.",
                    minimum: 1, maximum: 12, default: 3),
                "include_hidden": hiddenProperty,
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func readText(_ configuration: Configuration) -> Tool {
        Tool(
            name: readTextName,
            title: "Read a text file",
            description: """
                Returns a text file's contents, with the encoding guessed rather than \
                assumed: UTF-8, then UTF-16 by its byte-order mark, then ISO Latin 1, then \
                Mac OS Roman. The answer says which one decoded it.

                Capped at \(Format.bytes(configuration.maximumReadBytes)) per call by \
                default; a longer file comes back truncated and says so. For a big file, \
                filesystem_grep returns the matching lines instead of the whole thing. A \
                PDF needs apple-pdf-mcp's pdf_read tool, and a scan or photo needs \
                apple-vision-mcp's vision_ocr — this tool will refuse both.
                """,
            inputSchema: object(
                properties: [
                    "path": string("File to read. \(pathHelp)"),
                    "max_bytes": integer(
                        "Stop after this many bytes.",
                        minimum: Configuration.readBytesRange.lowerBound,
                        maximum: Configuration.readBytesRange.upperBound,
                        default: configuration.maximumReadBytes),
                ],
                required: ["path"]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }

    static let grep = Tool(
        name: grepName,
        title: "Regex search inside a folder's files",
        description: """
            Walks a folder and returns every line matching a regular expression, with its \
            path and line number. This is the tool for a pattern rather than a word, and \
            the fallback for what apple-spotlight-mcp's spotlight_search has not indexed.

            Reads files itself, so it is far slower than a Spotlight search — scope it to \
            the smallest folder that could hold the answer, and narrow further with \
            'name_pattern'. Binary files and files above the size ceiling are skipped and \
            counted. ICU regular expressions, the same dialect as NSRegularExpression.
            """,
        inputSchema: object(
            properties: [
                "path": string("Folder to walk. \(pathHelp)"),
                "pattern": string("Regular expression to match against each line."),
                "ignore_case": boolean("Match case-insensitively.", default: true),
                "name_pattern": string(
                    """
                    Only read files whose name matches this regular expression, for example \
                    "\\\\.swift$". Skipping files you cannot need is the difference between \
                    seconds and minutes.
                    """),
                "max_matches": integer(
                    "Stop after this many matching lines.", minimum: 1, maximum: 2000, default: 200),
            ],
            required: ["path", "pattern"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let tagsGet = Tool(
        name: tagsGetName,
        title: "Read Finder tags",
        description: """
            Lists the Finder tags on one file or folder. Tags are an ordinary extended \
            attribute, so they are readable without opening the file, and they are how many \
            people actually organise a folder that has no useful structure in its names.
            """,
        inputSchema: object(
            properties: ["path": string("File or folder. \(pathHelp)")],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

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
                    "How many occurrences you expect. The file is not touched if it disagrees.",
                    minimum: 1, maximum: 1000, default: 1),
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
            cannot be moved into itself.
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

            Refuses to clobber anything at the destination unless overwrite=true.
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

            The path must be inside a configured writable folder.
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
