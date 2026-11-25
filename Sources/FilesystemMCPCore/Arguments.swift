import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func text(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    // MARK: Text

    public func requiredString(_ name: String) throws -> String {
        guard let raw = try text(name) else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// A path as the caller wrote it. One longer than the system accepts is refused here,
    /// before anything is resolved, which is also what lets an error quote a path whole:
    /// it can never be longer than this.
    public func path(_ name: String) throws -> String {
        let path = try requiredString(name)
        guard path.utf8.count <= ToolCatalog.longestPathBytes else {
            throw ToolError.badArgument(
                name: name,
                reason: """
                    it is \(path.utf8.count) bytes long, starting '\(ToolStandard.echo(path))'. \
                    A path is at most \(ToolCatalog.longestPathBytes) bytes
                    """)
        }
        return path
    }

    /// For file contents and for the `find`/`replace` pair, where whitespace is the
    /// payload: trimming a trailing newline off an edit is exactly how an exact match
    /// stops matching.
    public func requiredRawString(_ name: String) throws -> String {
        guard let raw = try text(name) else { throw ToolError.missingArgument(name) }
        return raw
    }

    public func rawString(_ name: String, default fallback: String) throws -> String {
        try text(name) ?? fallback
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = try text(name) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Numbers and flags

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a page size, a depth, a window. Outside its range it is moved to the
    /// nearest allowed value, and `notices` gains the sentence that says which was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// A number that states something exact, such as how many replacements the caller
    /// expects. Outside its range it is refused, not moved, because the nearest allowed
    /// value would assert something the caller never said.
    public func exactInt(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        guard range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "a whole number from \(range.lowerBound) to \(range.upperBound) was expected")
        }
        return number
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    // MARK: Lists

    /// Required even when empty: "tags: []" is how every tag is removed, and no key at all
    /// is a missing argument. Each entry must be text; one that is not is refused instead
    /// of dropped, because the list replaces what is there.
    public func requiredStringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        guard let entries = raw.arrayValue, entries.allSatisfy({ $0.stringValue != nil }) else {
            throw ToolError.badArgument(name: name, reason: "a list of texts was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
