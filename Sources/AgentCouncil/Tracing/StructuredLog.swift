// StructuredLog.swift
// Studio.92 — Agent Council
// Structured logging with typed fields — complements traces (timelines)
// with searchable, filterable context entries.

import Foundation

// MARK: - Log Entry

/// A single structured log entry with typed fields.
public struct LogEntry: Sendable, Identifiable {

    public enum Level: String, Sendable, Comparable, CaseIterable {
        case debug
        case info
        case warn
        case error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            let order: [Level] = [.debug, .info, .warn, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let category: String
    public let message: String
    public let fields: [String: String]
    public let spanID: UUID?
    public let traceID: UUID?

    public init(
        level: Level,
        category: String,
        message: String,
        fields: [String: String] = [:],
        spanID: UUID? = nil,
        traceID: UUID? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.fields = fields
        self.spanID = spanID
        self.traceID = traceID
    }
}

// MARK: - Log Collector

/// Thread-safe log collector with filtering and streaming support.
/// Typically one per run, paired with its TraceCollector.
public actor LogCollector {

    public let traceID: UUID
    private var entries: [LogEntry] = []
    private var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    private var minimumLevel: LogEntry.Level

    private static let maxEntries = 5_000

    public init(traceID: UUID, minimumLevel: LogEntry.Level = .info) {
        self.traceID = traceID
        self.minimumLevel = minimumLevel
    }

    /// Emit a structured log entry.
    public func log(
        level: LogEntry.Level,
        category: String,
        message: String,
        fields: [String: String] = [:],
        spanID: UUID? = nil
    ) {
        guard level >= minimumLevel else { return }

        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            fields: fields,
            spanID: spanID,
            traceID: traceID
        )
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }

        for (_, continuation) in continuations {
            continuation.yield(entry)
        }
    }

    /// Convenience methods.
    public func debug(_ category: String, _ message: String, fields: [String: String] = [:], spanID: UUID? = nil) {
        log(level: .debug, category: category, message: message, fields: fields, spanID: spanID)
    }

    public func info(_ category: String, _ message: String, fields: [String: String] = [:], spanID: UUID? = nil) {
        log(level: .info, category: category, message: message, fields: fields, spanID: spanID)
    }

    public func warn(_ category: String, _ message: String, fields: [String: String] = [:], spanID: UUID? = nil) {
        log(level: .warn, category: category, message: message, fields: fields, spanID: spanID)
    }

    public func error(_ category: String, _ message: String, fields: [String: String] = [:], spanID: UUID? = nil) {
        log(level: .error, category: category, message: message, fields: fields, spanID: spanID)
    }

    /// All entries matching the given criteria.
    public func query(
        level: LogEntry.Level? = nil,
        category: String? = nil,
        containing: String? = nil
    ) -> [LogEntry] {
        entries.filter { entry in
            if let level, entry.level < level { return false }
            if let category, entry.category != category { return false }
            if let containing, !entry.message.localizedCaseInsensitiveContains(containing) { return false }
            return true
        }
    }

    /// All collected entries.
    public func allEntries() -> [LogEntry] {
        entries
    }

    /// Entry count.
    public func count() -> Int {
        entries.count
    }

    /// Live stream of log entries with replay of existing entries.
    public func stream() -> AsyncStream<LogEntry> {
        let id = UUID()
        let existing = entries
        return AsyncStream { continuation in
            for entry in existing {
                continuation.yield(entry)
            }
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    /// Summary stats.
    public func summary() -> LogSummary {
        var debugCount = 0
        var infoCount = 0
        var warnCount = 0
        var errorCount = 0
        var categories: Set<String> = []
        for entry in entries {
            categories.insert(entry.category)
            switch entry.level {
            case .debug: debugCount += 1
            case .info: infoCount += 1
            case .warn: warnCount += 1
            case .error: errorCount += 1
            }
        }
        return LogSummary(
            totalEntries: entries.count,
            debugCount: debugCount,
            infoCount: infoCount,
            warnCount: warnCount,
            errorCount: errorCount,
            categories: categories.sorted()
        )
    }

    /// Terminate all live streams.
    public func finishAllStreams() {
        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

// MARK: - Log Summary

public struct LogSummary: Sendable {
    public let totalEntries: Int
    public let debugCount: Int
    public let infoCount: Int
    public let warnCount: Int
    public let errorCount: Int
    public let categories: [String]
}
