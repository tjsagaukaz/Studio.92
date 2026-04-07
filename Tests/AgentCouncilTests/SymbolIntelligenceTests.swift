import Foundation
import XCTest
@testable import AgentCouncil

final class SymbolIntelligenceTests: XCTestCase {

    private let decoder = JSONDecoder()

    func testToolExecutorExecutesCanonicalSymbolTools() async throws {
        let fixture = try makePackageWorkspace(includeBrokenFile: false)
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        try buildPackage(at: fixture.root)

        let executor = ToolExecutor(projectRoot: fixture.root, allowMachineWideAccess: false)
        let symbolOutcome = await executor.execute(
            toolCallID: "symbol-1",
            name: "find_symbol",
            input: [
                "query": .string("helper"),
                "max_results": .int(5)
            ]
        )

        XCTAssertFalse(symbolOutcome.isError)
        switch symbolOutcome.toolResultContent {
        case .text(let payload):
            let symbolResult = try decoder.decode(FoundSymbolResult.self, from: Data(payload.utf8))
            XCTAssertGreaterThanOrEqual(symbolResult.returnedMatches, 1)
            let symbol = try XCTUnwrap(symbolResult.matches.first)
            XCTAssertEqual(symbol.name, "helper()")
            XCTAssertEqual(symbol.path, "Sources/TestLib/TestLib.swift")
            XCTAssertEqual(symbol.sourceKitPlaceholder, "helper")

            let usagesOutcome = await executor.execute(
                toolCallID: "symbol-2",
                name: "find_usages",
                input: [
                    "path": .string(symbol.path),
                    "line": .int(symbol.line),
                    "column": .int(symbol.column),
                    "max_results": .int(10)
                ]
            )

            XCTAssertFalse(usagesOutcome.isError)
            switch usagesOutcome.toolResultContent {
            case .text(let usagesPayload):
                let usagesResult = try decoder.decode(FindUsagesResult.self, from: Data(usagesPayload.utf8))
                XCTAssertEqual(usagesResult.resolvedSymbol.usr, symbol.usr)
                XCTAssertGreaterThanOrEqual(usagesResult.totalMatches, 3)
                XCTAssertTrue(usagesResult.matches.contains { $0.role == "definition" && $0.path == "Sources/TestLib/TestLib.swift" })
                XCTAssertTrue(usagesResult.matches.contains { $0.role == "call" && $0.path == "Sources/TestLib/TestLib.swift" })
            case .blocks:
                XCTFail("Expected find_usages to return text payload")
            }
        case .blocks:
            XCTFail("Expected find_symbol to return text payload")
        }
    }

    func testSourceKitClientPrepareRenameAndDiagnostics() async throws {
        let fixture = try makePackageWorkspace(includeBrokenFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let client = SourceKitLSPClient(projectRoot: fixture.root)
        let stableFile = fixture.root.appendingPathComponent("Sources/TestLib/TestLib.swift")
        let stableSource = try String(contentsOf: stableFile, encoding: .utf8)
        let position = try XCTUnwrap(position(of: "trackedValue", in: stableSource))

        let prepareRename = try await client.prepareRename(
            fileURL: stableFile,
            line: position.line,
            utf8Column: position.column
        )

        XCTAssertEqual(prepareRename?.placeholder, "trackedValue")

        let diagnosticsFile = fixture.root.appendingPathComponent("Sources/TestLib/Broken.swift")
        let diagnostics = try await client.documentDiagnostics(fileURL: diagnosticsFile)
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertTrue(diagnostics.contains { $0.message.localizedCaseInsensitiveContains("cannot convert") || $0.message.localizedCaseInsensitiveContains("convert value") })
    }

    private func makePackageWorkspace(includeBrokenFile: Bool) throws -> (base: URL, root: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let packageSwift = root.appendingPathComponent("Package.swift")
        try """
        // swift-tools-version: 5.10
        import PackageDescription

        let package = Package(
            name: "TestLib",
            platforms: [.macOS(.v14)],
            products: [
                .library(name: "TestLib", targets: ["TestLib"])
            ],
            targets: [
                .target(name: "TestLib")
            ]
        )
        """.write(to: packageSwift, atomically: true, encoding: .utf8)

        let sourceDir = root.appendingPathComponent("Sources/TestLib", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        try """
        public let trackedValue = 1

        public struct Greeter {
            public init() {}

            public func greet() -> String {
                helper()
            }
        }

        public func helper() -> String {
            "hi"
        }

        public func callHelper() -> String {
            helper()
        }
        """.write(to: sourceDir.appendingPathComponent("TestLib.swift"), atomically: true, encoding: .utf8)

        if includeBrokenFile {
            try """
            let broken: String = 1
            """.write(to: sourceDir.appendingPathComponent("Broken.swift"), atomically: true, encoding: .utf8)
        }

        return (base, root)
    }

    private func buildPackage(at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "build"]
        process.currentDirectoryURL = root

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("swift build failed: \(message)")
            return
        }
    }

    private func position(of needle: String, in source: String) -> (line: Int, column: Int)? {
        let lines = source.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: needle) else { continue }
            let column = line[..<range.lowerBound].utf8.count + 1
            return (line: index + 1, column: column)
        }
        return nil
    }
}