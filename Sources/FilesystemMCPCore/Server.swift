import Foundation

public enum FilesystemMCPServer {

    public static let name = "apple-filesystem-mcp"
    public static let version = "1.0.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the two allow-lists, which sibling server answers which kind of question,
    /// and the fact that nothing here deletes.
    public static let instructions = """
        Access to files on this Mac through FileManager. No Finder, no Apple events, no \
        network.

        TWO SEPARATE SCOPES. A broad list of folders that may be READ and a narrower list \
        that may be WRITTEN, both chosen by the person who installed the extension. Every \
        path is canonicalised — ~ expanded, .. removed, symlinks followed — and then checked \
        against the right list before anything happens. A path outside its list is refused \
        and the error names the configured scope. Call filesystem_status first: it reports \
        both lists and whether macOS is actually letting this process reach them.

        Searching, PDF text and OCR are three separate MCP servers, not tools here: \
        apple-spotlight-mcp's spotlight_search finds a word inside a file without opening \
        it, using content macOS has already indexed; apple-pdf-mcp's pdf_read extracts a \
        PDF's text, outline and metadata, and says explicitly when a PDF is a scan with no \
        text layer; apple-vision-mcp's vision_ocr is what reads that scan. \
        filesystem_grep is this server's own fallback for what Spotlight has not indexed, \
        and for a regular expression rather than a word. filesystem_list and \
        filesystem_stat give you rows with size and content hash — that is how you find \
        duplicates, by reading the rows yourself; there is no duplicate-finding tool and \
        there will not be one.

        NOTHING HERE DELETES. filesystem_trash moves an item to the Trash, where the \
        Finder's File → Put Back returns it to where it was. There is no delete tool and \
        emptying the Trash is not something this server can do.

        Write tools name their verb: filesystem_write, filesystem_edit, filesystem_mkdir, \
        filesystem_move, filesystem_copy, filesystem_tags_set, filesystem_trash. \
        filesystem_trash requires confirm=true; filesystem_write, filesystem_move and \
        filesystem_copy require overwrite=true before they will replace anything.

        This server exposes the filesystem's full capability within its scope. What may be \
        used at any moment is decided by the permission switches in the client, not by this \
        code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a file by itself.
    public static func run(
        store: any FilesystemStore = SystemFilesystemStore(),
        configuration: Configuration = Configuration()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(
                tools: FilesystemTools(store: store, configuration: configuration),
                configuration: configuration))
    }

    /// The configuration is passed again because the catalogue's descriptions are built
    /// from it, not only the tools.
    public static func handler(tools: FilesystemTools, configuration: Configuration) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(configuration), tools: tools)
    }
}
