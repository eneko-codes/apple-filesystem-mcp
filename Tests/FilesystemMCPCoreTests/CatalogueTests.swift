import Foundation
import MCP
import Testing

@testable import FilesystemMCPCore

/// Checks on the advertised surface itself. None of these open a file.
@Suite("Catalogue")
struct CatalogueTests {

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["string", "null"]` and hands the model a bare `{}` in its place. An untyped array
    /// is then serialised to a string before it leaves the client and rejected on arrival.
    /// The fault is invisible until a caller happens to use that field, so the whole
    /// catalogue is walked here rather than trusted to review.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Every tool that changes the disk is annotated as a write")
    func annotationsAreHonest() {
        for tool in ToolCatalog.all() {
            #expect(
                tool.annotations.readOnlyHint == !ToolCatalog.writeTools.contains(tool.name),
                "\(tool.name) is mis-annotated")
        }
    }

    /// Nothing here deletes. `filesystem_trash` moves an item to the Trash, where it can
    /// be put back — so no tool name should suggest otherwise.
    @Test("No tool offers an unrecoverable delete")
    func noDeleteTool() {
        for name in ToolCatalog.all().map(\.name) {
            #expect(!name.contains("delete"), "\(name) suggests a delete this server does not do")
            #expect(!name.contains("remove"), "\(name) suggests a delete this server does not do")
        }
    }

    /// Forbidden by the design rule these servers follow: the server moves raw data, and
    /// anything a reasonable person could disagree about belongs to the model instead.
    @Test("No tool computes an interpretation")
    func noComputedTools() {
        let banned = ["stats", "summary", "insight", "duplicate", "recent", "usage", "triage"]
        for name in ToolCatalog.all().map(\.name) {
            for word in banned {
                #expect(!name.contains(word), "\(name) computes something the model should")
            }
        }
    }
}
