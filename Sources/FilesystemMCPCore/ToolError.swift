import Foundation

public enum ToolError: Error, Equatable {
    case noReadRootsConfigured
    case noWriteRootsConfigured
    case pathOutOfScope(
        requested: String, resolved: String, access: Access, readRoots: [String],
        writeRoots: [String])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badRegex(pattern: String, reason: String)
    case notFound(path: String)
    case alreadyExists(path: String)
    case notADirectory(path: String)
    case notAFile(path: String)
    case permissionDenied(path: String, detail: String)
    case fileTooLarge(path: String, bytes: Int, maximum: Int)
    case undecodableText(path: String)
    case editTextNotFound(path: String, find: String)
    case editTextAmbiguous(path: String, find: String, found: Int)
    case destinationInsideSource(from: String, to: String)
    case confirmationRequired(action: String)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .noReadRootsConfigured:
            return """
                This server has no read roots configured, so it can see nothing at all.

                That is the safe default, not a fault: an unconfigured filesystem server
                would otherwise start with the whole disk in reach. Name the folders
                Claude may look inside in:
                  Claude Desktop → Settings → Extensions → Apple Filesystem → Folders Claude may read

                Nothing outside that list can be listed, read or written, and nothing
                inside it can be written either until a write root is set too.
                """

        case .noWriteRootsConfigured:
            return """
                This server has no write roots configured, so it is read-only right now.

                Write roots are a deliberately separate, narrower list: a folder has to be
                readable AND writable before anything may be changed in it. Set one in:
                  Claude Desktop → Settings → Extensions → Apple Filesystem → Folders Claude may change

                Leaving it empty is a reasonable way to run this server.
                """

        case .pathOutOfScope(let requested, let resolved, let access, let readRoots, let writeRoots):
            let list = access == .read ? readRoots : writeRoots
            let label = access == .read ? "Readable folders" : "Writable folders"
            let scope = list.isEmpty ? "(none configured)" : list.joined(separator: ", ")
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(resolved)\n(symlinks and .. are followed before the check, always)."
            let writeNote =
                access == .write
                ? """


                    A writable folder must also be a readable one — the write list is a \
                    narrowing of the read list, not a second scope beside it.
                    """ : ""
            return """
                Path '\(requested)' is outside the \(access.rawValue) scope this extension was \
                configured with.\(resolution)

                \(label): \(scope)

                This is not something to work around: the person installing the extension
                chose those folders in its settings, deliberately keeping everything else
                out of reach. Change them in Claude Desktop → Settings → Extensions.\(writeNote)
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badRegex(let pattern, let reason):
            return """
                'pattern' is not a valid regular expression: /\(pattern)/

                \(reason)

                filesystem_grep uses ICU regular expressions — the same dialect as
                NSRegularExpression, close to PCRE. Escape a literal ( ) [ ] { } . * + ? \
                | ^ $ \\ with a backslash.
                """

        case .notFound(let path):
            return """
                Nothing exists at '\(path)'.

                Check the spelling with filesystem_list on the parent folder. A path
                inside scope that is simply not there gives this error; a path outside
                scope gives a different one, so this is not a scope problem.
                """

        case .alreadyExists(let path):
            return """
                Something already exists at '\(path)'.

                This server does not silently replace a file. Pass overwrite=true if
                replacing it is really what you mean, or filesystem_trash it first so the
                old copy stays recoverable.
                """

        case .notADirectory(let path):
            return "'\(path)' is a file, and this tool needs a folder."

        case .notAFile(let path):
            return "'\(path)' is a folder, and this tool needs a file."

        case .permissionDenied(let path, let detail):
            return """
                macOS refused access to '\(path)': \(detail)

                The path is inside the configured scope, so this is a system permission,
                not this server's allow-list. Two different grants can be missing:

                For Desktop, Documents or Downloads:
                  System Settings → Privacy & Security → Files and Folders → enable the folder
                  under "apple-filesystem-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)

                For anywhere else — iCloud Drive, an external disk, another user's folder:
                  System Settings → Privacy & Security → Full Disk Access → add and enable
                  "apple-filesystem-mcp"
                  (Spanish UI: Privacidad y seguridad → Acceso total al disco)

                Then restart Claude Desktop: the permission is resolved when the process
                starts. Full Disk Access has no consent dialog — it is never requested,
                only granted by hand.
                """

        case .fileTooLarge(let path, let bytes, let maximum):
            return """
                '\(path)' is \(Format.bytes(bytes)); this call may read at most \
                \(Format.bytes(maximum)).

                Raise 'max_bytes' on the call, or raise the extension's own ceiling in
                Claude Desktop → Settings → Extensions. For a big text file,
                filesystem_grep is usually the better tool: it returns matching lines
                instead of the file.
                """

        case .undecodableText(let path):
            return """
                '\(path)' is not text in any encoding this server recognises.

                UTF-8, UTF-16 with a byte-order mark, ISO Latin 1 and Mac OS Roman were all
                tried. A binary file gives this error; so does a text file in an unusual
                legacy encoding. If it is a PDF, apple-pdf-mcp's pdf_read tool is what
                reads it; if it is a scan or an image, apple-vision-mcp's vision_ocr is.
                """

        case .editTextNotFound(let path, let find):
            return """
                The text to replace does not appear in '\(path)'.

                Looking for:
                  \(Format.excerpt(find))

                The match is exact, including whitespace and line endings — that is the
                point of filesystem_edit, and it is why nothing was changed. Read the
                file with filesystem_read_text and copy the passage from what it
                returned.
                """

        case .editTextAmbiguous(let path, let find, let found):
            return """
                The text to replace appears \(found) times in '\(path)', and 'expected_count' \
                said otherwise.

                Looking for:
                  \(Format.excerpt(find))

                Nothing was changed. Either extend the search text with a surrounding line
                until it is unique, or pass expected_count=\(found) to replace every
                occurrence deliberately.
                """

        case .destinationInsideSource(let from, let to):
            return """
                '\(to)' is inside '\(from)', so this would move a folder into itself.

                The filesystem would either refuse or produce an infinite path. Pick a
                destination outside the folder being moved.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                Nothing is deleted by this server — the file goes to the Trash and can be
                put back from the Finder — but it does disappear from where it is now.
                Call again with confirm=true only if that is what you mean.
                """

        case .storeFailure(let detail):
            return "The filesystem returned an error: \(detail)"
        }
    }
}
