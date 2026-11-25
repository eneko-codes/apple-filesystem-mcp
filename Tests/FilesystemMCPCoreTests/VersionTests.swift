import Foundation
import Testing

@testable import FilesystemMCPCore

@Suite("Release metadata")
struct VersionTests {

    /// Derived from this file's own path: SwiftPM makes no promise about the working
    /// directory a test runs in.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FilesystemMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The installer keys on the manifest version alone, so a build whose three version
    /// strings disagree is a bug report that describes a build nobody has.
    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifestVersion = try #require(try manifest()["version"] as? String)
        let plistData = try Data(contentsOf: Self.repositoryRoot.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(manifestVersion == FilesystemMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == FilesystemMCPServer.version)
    }

    /// A tool missing from the manifest has no permission switch at all, and the manifest
    /// is read before the server has ever run.
    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        let manifestNames = listed.compactMap { $0["name"] as? String }
        #expect(Set(manifestNames) == Set(ToolCatalog.all().map(\.name)))
        #expect(manifestNames.count == Set(manifestNames).count)
        for tool in listed {
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    /// The manifest is plain JSON and cannot take a figure from a constant, so this holds
    /// the bounds it states to the ones the code enforces.
    @Test("The manifest states the time limits the server enforces")
    func manifestStatesTheTimeLimits() throws {
        let description = try #require(try manifest()["long_description"] as? String)
        #expect(description.contains("more than \(FilesystemTools.defaultScanBudget.components.seconds) seconds"))
        #expect(description.contains("after \(FilesystemTools.defaultTimeout.components.seconds) seconds"))
    }

    /// The README states figures in prose, so a constant that moves has to break this test
    /// before the README goes on telling readers the old one.
    @Test("The README states the bounds the server enforces")
    func readmeStatesTheBounds() throws {
        let readme = try String(
            contentsOf: Self.repositoryRoot.appending(path: "README.md"), encoding: .utf8
        ).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        func thousands(_ number: Int) -> String {
            number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        }
        #expect(readme.contains("more than \(FilesystemTools.defaultScanBudget.components.seconds) seconds"))
        #expect(readme.contains("after \(FilesystemTools.defaultTimeout.components.seconds) seconds"))
        #expect(readme.contains("at \(thousands(ToolCatalog.grepFileCeiling)) files searched"))
        #expect(readme.contains("larger than \(Format.bytes(ToolCatalog.grepFileBytes))"))
        #expect(readme.contains("at most \(thousands(ToolCatalog.treeCountCeiling)) entries"))
        #expect(readme.contains("up to \(Format.bytes(ToolCatalog.wholeFileBytes))"))
    }

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
