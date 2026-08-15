import Foundation

/// Rendering of a date for tool output.
///
/// Parsing a date *argument* (for a date-range filter) lives in `apple-spotlight-mcp`
/// now, the only server left in this family that accepts one — `spotlight_search`'s
/// `modified_after`/`modified_before`. This server only ever displays a date it already
/// has (`filesystem_list`'s `modified` column, `filesystem_stat`'s `created`/`modified`
/// rows), so only the rendering half moved with it.
public enum DateParsing {

    /// `2026-08-12 09:00`. Hand-rolled rather than `DateFormatter` so output does not
    /// change shape with the machine's locale: a model that has learned to read a
    /// timestamp should not be handed a different one on a differently configured Mac.
    /// Sortable as a string, which is what a listing wants.
    public static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }
}
