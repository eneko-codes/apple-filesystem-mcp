import Foundation

/// Settings the person installing the extension can change.
///
/// These arrive as command-line arguments because that is how a Claude extension passes
/// `user_config`: the manifest substitutes `${user_config.key}` into `mcp_config.args`.
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is four settings, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {

    /// Folders Claude may look inside. Not a default a caller can widen — a boundary.
    ///
    /// **Empty means nothing is reachable, not everything.** The sibling calendar server
    /// reads an empty allow-list as "no restriction", which is the right default there:
    /// the worst case is a calendar the owner would rather have hidden. Here the worst
    /// case is the whole disk, so this list fails closed. A server that does nothing
    /// until it is configured is a nuisance for one minute; one that starts with the
    /// home directory in scope is a different kind of program entirely.
    public var readRoots: [String] = []

    /// Folders Claude may change. A subset check, not a second universe: a path must be
    /// inside a read root *and* inside a write root before anything may be written to
    /// it. A write root outside every read root governs nothing, and `filesystem_status`
    /// says so rather than leaving it to be discovered.
    ///
    /// The whole reason this server exists as its own repository is that one scope for
    /// both would make home-wide read imply home-wide write.
    public var writeRoots: [String] = []

    /// Ceiling on what `filesystem_read_text` will pull across the boundary in one call.
    public var maximumReadBytes: Int = 1_000_000

    /// Files above this are listed without a hash. Hashing a listing means reading every
    /// byte of every file in it, so the ceiling is what keeps `filesystem_list` on a
    /// folder of disk images from turning into a gigabyte of I/O.
    public var maximumHashBytes: Int = 16_777_216

    public init() {}

    public static let readBytesRange = 1_024...20_000_000
    public static let hashBytesRange = 0...1_073_741_824

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Observed live in the
    /// calendar server: an empty `multiple: true` list produced a bare
    /// `${user_config.calendars}`.
    ///
    /// Taking those at face value is worse than ignoring them: a read-root list would
    /// come to contain one folder nobody has, and every real path would fall out of
    /// scope with an error blaming the caller.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Flag, then every bare argument until the next flag.
    ///
    /// A `multiple: true` user_config expands to one bare argument per value, so a
    /// repeated `--read-root` flag is not available: the values arrive loose, in place.
    /// Two such lists rule out the sibling servers' single `--` separator — there is
    /// only one end of the argument vector — so each list is introduced by its own flag
    /// and ends at the next token starting with `--`.
    ///
    /// Unknown flags are ignored rather than fatal. A server that will not launch is
    /// much harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0

        /// Everything from `index + 1` up to the next flag, cleaned of blanks and
        /// placeholders. Returns the index to continue from.
        func collectList(from start: Int) -> (values: [String], next: Int) {
            var values: [String] = []
            var cursor = start + 1
            while cursor < arguments.count, !arguments[cursor].hasPrefix("--") {
                let value = arguments[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !isPlaceholder(value) { values.append(value) }
                cursor += 1
            }
            return (values, cursor)
        }

        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            func clamped(_ range: ClosedRange<Int>) -> Int? {
                guard let value, !isPlaceholder(value), let number = Int(value) else { return nil }
                return min(max(number, range.lowerBound), range.upperBound)
            }

            switch flag {
            case "--read-roots":
                let collected = collectList(from: index)
                configuration.readRoots = collected.values
                index = collected.next

            case "--write-roots":
                let collected = collectList(from: index)
                configuration.writeRoots = collected.values
                index = collected.next

            case "--max-read-bytes":
                if let number = clamped(readBytesRange) { configuration.maximumReadBytes = number }
                index += 2

            case "--max-hash-bytes":
                if let number = clamped(hashBytesRange) { configuration.maximumHashBytes = number }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
