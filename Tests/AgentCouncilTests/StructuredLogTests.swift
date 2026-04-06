// StructuredLogTests.swift
// Studio.92 — Structured Logging Tests

import Foundation
import XCTest
@testable import AgentCouncil

final class StructuredLogTests: XCTestCase {

    func testLogEntryCreation() {
        let entry = LogEntry(level: .info, category: "pipeline", message: "Run started", fields: ["runID": "abc"])
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.category, "pipeline")
        XCTAssertEqual(entry.message, "Run started")
        XCTAssertEqual(entry.fields["runID"], "abc")
        XCTAssertNil(entry.spanID)
    }

    func testLogLevelOrdering() {
        XCTAssertTrue(LogEntry.Level.debug < .info)
        XCTAssertTrue(LogEntry.Level.info < .warn)
        XCTAssertTrue(LogEntry.Level.warn < .error)
        XCTAssertFalse(LogEntry.Level.error < .debug)
    }

    func testCollectorFiltersMinimumLevel() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .warn)
        await collector.debug("test", "debug message")
        await collector.info("test", "info message")
        await collector.warn("test", "warn message")
        await collector.error("test", "error message")
        let entries = await collector.allEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].level, .warn)
        XCTAssertEqual(entries[1].level, .error)
    }

    func testCollectorQueryByCategory() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        await collector.info("pipeline", "started")
        await collector.info("recovery", "retrying")
        await collector.info("pipeline", "finished")
        let pipelineEntries = await collector.query(category: "pipeline")
        XCTAssertEqual(pipelineEntries.count, 2)
    }

    func testCollectorQueryByLevel() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        await collector.debug("test", "d")
        await collector.info("test", "i")
        await collector.warn("test", "w")
        await collector.error("test", "e")
        let warnAndAbove = await collector.query(level: .warn)
        XCTAssertEqual(warnAndAbove.count, 2)
    }

    func testCollectorQueryContaining() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        await collector.info("test", "Build succeeded for target X")
        await collector.info("test", "Tests passed")
        await collector.info("test", "Build failed for target Y")
        let buildEntries = await collector.query(containing: "build")
        XCTAssertEqual(buildEntries.count, 2)
    }

    func testCollectorSummary() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        await collector.debug("a", "x")
        await collector.info("a", "x")
        await collector.info("b", "x")
        await collector.warn("b", "x")
        await collector.error("c", "x")
        let summary = await collector.summary()
        XCTAssertEqual(summary.totalEntries, 5)
        XCTAssertEqual(summary.debugCount, 1)
        XCTAssertEqual(summary.infoCount, 2)
        XCTAssertEqual(summary.warnCount, 1)
        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertEqual(summary.categories, ["a", "b", "c"])
    }

    func testCollectorFieldsPreserved() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        let spanID = UUID()
        await collector.info("tool", "file_read completed", fields: ["path": "/src/main.swift", "bytes": "2048"], spanID: spanID)
        let entries = await collector.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fields["path"], "/src/main.swift")
        XCTAssertEqual(entries[0].fields["bytes"], "2048")
        XCTAssertEqual(entries[0].spanID, spanID)
    }

    func testCollectorBoundsEntries() async {
        let collector = LogCollector(traceID: UUID(), minimumLevel: .debug)
        for i in 0..<5_100 {
            await collector.debug("test", "entry \(i)")
        }
        let count = await collector.count()
        XCTAssertLessThanOrEqual(count, 5_000)
    }
}
