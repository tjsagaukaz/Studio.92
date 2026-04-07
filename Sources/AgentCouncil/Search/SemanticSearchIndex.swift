import CryptoKit
import Foundation
import SQLite3

public struct SemanticSearchRequest: Sendable, Equatable {
    public let query: String
    public let maxResults: Int
    public let paths: [URL]

    public init(query: String, maxResults: Int = 12, paths: [URL] = []) {
        self.query = query
        self.maxResults = maxResults
        self.paths = paths
    }
}

public struct SemanticSearchMatch: Sendable, Codable, Equatable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let summary: String
    public let snippet: String
    public let score: Double

    enum CodingKeys: String, CodingKey {
        case path, summary, snippet, score
        case startLine = "start_line"
        case endLine = "end_line"
    }
}

public struct SemanticSearchResult: Sendable, Codable, Equatable {
    public let query: String
    public let queryTimeMs: Int
    public let totalMatches: Int
    public let returnedMatches: Int
    public let truncated: Bool
    public let matches: [SemanticSearchMatch]

    enum CodingKeys: String, CodingKey {
        case query, truncated, matches
        case queryTimeMs = "query_time_ms"
        case totalMatches = "total_matches"
        case returnedMatches = "returned_matches"
    }

    public func prettyPrintedJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"query\":\"\(escapedQuery)\"}"
        }
        return text
    }
}

public enum SemanticSearchError: LocalizedError, Sendable {
    case emptyQuery
    case databaseOpenFailed(String)
    case sqliteFailure(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Search query cannot be empty."
        case .databaseOpenFailed(let message), .sqliteFailure(let message):
            return message
        }
    }
}

public actor SemanticSearchIndex {

    private let projectRoot: URL
    private let databaseURL: URL
    private var db: OpaquePointer?

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.databaseURL = projectRoot
            .appendingPathComponent(".studio92", isDirectory: true)
            .appendingPathComponent("index", isDirectory: true)
            .appendingPathComponent("semantic-search.sqlite3", isDirectory: false)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func refresh(paths: [URL]? = nil) throws {
        try ensureDatabase()

        let allRecords = try loadFileRecords()
        let scan = try collectSwiftFiles(in: paths, existingRecords: allRecords)
        try beginTransaction()
        do {
            for removedPath in scan.removedRelativePaths {
                try deleteFile(path: removedPath)
            }

            for fileURL in scan.files {
                try refreshFile(at: fileURL, existingRecord: allRecords[relativePath(for: fileURL)])
            }

            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    public func search(request: SemanticSearchRequest) throws -> SemanticSearchResult {
        let startedAt = Date()
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SemanticSearchError.emptyQuery }

        try refresh(paths: request.paths.isEmpty ? nil : request.paths)
        try ensureDatabase()

        let maxResults = min(max(request.maxResults, 1), 50)
        let normalizedPaths = normalizedScopePaths(from: request.paths)
        let ftsQuery = Self.ftsQuery(from: query)
        let totalMatches = try countMatches(ftsQuery: ftsQuery, pathFilters: normalizedPaths)
        let rows = try queryMatches(ftsQuery: ftsQuery, pathFilters: normalizedPaths, limit: maxResults)
        let queryTimeMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000.0))

        return SemanticSearchResult(
            query: query,
            queryTimeMs: queryTimeMs,
            totalMatches: totalMatches,
            returnedMatches: rows.count,
            truncated: totalMatches > rows.count,
            matches: rows
        )
    }

    private func refreshFile(at fileURL: URL, existingRecord: FileRecord?) throws {
        let relativePath = relativePath(for: fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if let existingRecord, abs(existingRecord.mtime - mtime) < 0.000_1 {
            return
        }

        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let fileHash = Self.sha256(source)
        if let existingRecord, existingRecord.contentHash == fileHash {
            try upsertFile(path: relativePath, contentHash: fileHash, mtime: mtime)
            return
        }

        let chunks = SwiftStructuredChunker.chunkFile(path: relativePath, source: source)
        let existingChunks = try loadChunks(for: relativePath)

        try upsertFile(path: relativePath, contentHash: fileHash, mtime: mtime)

        for chunk in chunks {
            if let existingChunk = existingChunks[chunk.chunkID],
               existingChunk.chunkHash == chunk.chunkHash,
               existingChunk.startLine == chunk.startLine,
               existingChunk.endLine == chunk.endLine {
                continue
            }
            try upsertChunk(chunk, fileHash: fileHash)
        }

        let newChunkIDs = Set(chunks.map(\.chunkID))
        for existingChunkID in existingChunks.keys where !newChunkIDs.contains(existingChunkID) {
            try deleteChunk(chunkID: existingChunkID)
        }
    }

    private func collectSwiftFiles(
        in scopedPaths: [URL]?,
        existingRecords: [String: FileRecord]
    ) throws -> FileScanResult {
        let fileManager = FileManager.default
        let normalizedScope = (scopedPaths ?? [projectRoot]).map { $0.standardizedFileURL }
        var files: [URL] = []
        var seenPaths = Set<String>()
        var removedRelativePaths = Set<String>()
        var scopePrefixes: [String] = []

        for scopeURL in normalizedScope {
            if let relativePrefix = relativePrefixForScope(scopeURL) {
                scopePrefixes.append(relativePrefix)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: scopeURL.path, isDirectory: &isDirectory) else {
                if let relativePrefix = relativePrefixForScope(scopeURL) {
                    for path in existingRecords.keys where path == relativePrefix || path.hasPrefix(relativePrefix + "/") {
                        removedRelativePaths.insert(path)
                    }
                }
                continue
            }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: scopeURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsPackageDescendants, .skipsHiddenFiles]
                )

                while let candidate = enumerator?.nextObject() as? URL {
                    let standardized = candidate.standardizedFileURL
                    if shouldSkip(url: standardized) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    guard standardized.pathExtension == "swift" else { continue }
                    guard seenPaths.insert(standardized.path).inserted else { continue }
                    files.append(standardized)
                }
            } else if scopeURL.pathExtension == "swift", seenPaths.insert(scopeURL.path).inserted {
                files.append(scopeURL)
            }
        }

        let currentRelativePaths = Set(files.map(relativePath(for:)))
        if scopedPaths == nil {
            for path in existingRecords.keys where !currentRelativePaths.contains(path) {
                removedRelativePaths.insert(path)
            }
        } else {
            for prefix in scopePrefixes {
                for path in existingRecords.keys where (path == prefix || path.hasPrefix(prefix + "/")) && !currentRelativePaths.contains(path) {
                    removedRelativePaths.insert(path)
                }
            }
        }

        return FileScanResult(files: files.sorted { $0.path < $1.path }, removedRelativePaths: Array(removedRelativePaths).sorted())
    }

    private func shouldSkip(url: URL) -> Bool {
        let path = url.path
        return path.contains("/.git/")
            || path.contains("/.build/")
            || path.contains("/DerivedData/")
            || path.contains("/node_modules/")
            || path.contains("/.studio92/sessions/")
            || path.contains("/.studio92/worktrees/")
            || path.contains("/xcuserdata/")
    }

    private func normalizedScopePaths(from paths: [URL]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for path in paths {
            guard let relative = relativePrefixForScope(path.standardizedFileURL), seen.insert(relative).inserted else { continue }
            normalized.append(relative)
        }

        return normalized.sorted()
    }

    private func relativePrefixForScope(_ url: URL) -> String? {
        let normalizedPath = url.standardizedFileURL.path
        let rootPath = projectRoot.path
        guard normalizedPath == rootPath || normalizedPath.hasPrefix(rootPath + "/") else { return nil }
        if normalizedPath == rootPath { return "" }
        return String(normalizedPath.dropFirst(rootPath.count + 1))
    }

    private func relativePath(for fileURL: URL) -> String {
        let standardized = fileURL.standardizedFileURL.path
        let root = projectRoot.path
        if standardized.hasPrefix(root + "/") {
            return String(standardized.dropFirst(root.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private static func ftsQuery(from query: String) -> String {
        let tokens = tokenizedTerms(from: query.lowercased())
        if !tokens.isEmpty {
            return tokens.map { "\($0)*" }.joined(separator: " OR ")
        }
        let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func queryMatches(
        ftsQuery: String,
        pathFilters: [String],
        limit: Int
    ) throws -> [SemanticSearchMatch] {
        let filterClause = pathFilterClause(for: pathFilters)
        let sql = """
        WITH matches AS (
            SELECT c.path, c.start_line, c.end_line, c.summary, c.text, c.chunk_id,
                   bm25(semantic_chunks_fts, 1.0, 0.65) AS score
            FROM semantic_chunks_fts
            JOIN chunks c ON c.chunk_id = semantic_chunks_fts.chunk_id
            WHERE semantic_chunks_fts MATCH ?\(filterClause.sql)
        ), ranked AS (
            SELECT path, start_line, end_line, summary, text, chunk_id,
                   MIN(score) OVER (PARTITION BY path) AS path_score,
                   ROW_NUMBER() OVER (PARTITION BY path ORDER BY start_line ASC, chunk_id ASC) AS path_row
            FROM matches
        )
        SELECT path, start_line, end_line, summary, text, path_score
        FROM ranked
        WHERE path_row = 1
        ORDER BY path_score ASC, path ASC, start_line ASC
        LIMIT ?;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, sqliteTransientDestructor)
        bindIndex += 1
        bind(pathFilters: filterClause.bindings, into: statement, startingAt: &bindIndex)
        sqlite3_bind_int64(statement, bindIndex, sqlite3_int64(limit))

        var rows: [SemanticSearchMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let startLine = Int(sqlite3_column_int64(statement, 1))
            let endLine = Int(sqlite3_column_int64(statement, 2))
            let summary = String(cString: sqlite3_column_text(statement, 3))
            let text = String(cString: sqlite3_column_text(statement, 4))
            let score = sqlite3_column_double(statement, 5)

            rows.append(
                SemanticSearchMatch(
                    path: path,
                    startLine: startLine,
                    endLine: endLine,
                    summary: summary,
                    snippet: Self.snippet(from: text),
                    score: score
                )
            )
        }

        return rows
    }

    private func countMatches(ftsQuery: String, pathFilters: [String]) throws -> Int {
        let filterClause = pathFilterClause(for: pathFilters)
        let sql = """
        WITH matches AS (
            SELECT c.path
            FROM semantic_chunks_fts
            JOIN chunks c ON c.chunk_id = semantic_chunks_fts.chunk_id
            WHERE semantic_chunks_fts MATCH ?\(filterClause.sql)
            GROUP BY c.path
        )
        SELECT COUNT(*)
        FROM matches;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, sqliteTransientDestructor)
        bindIndex += 1
        bind(pathFilters: filterClause.bindings, into: statement, startingAt: &bindIndex)

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func pathFilterClause(for pathFilters: [String]) -> (sql: String, bindings: [String]) {
        guard !pathFilters.isEmpty else { return ("", []) }
        let clauses = pathFilters.map { _ in "(c.path = ? OR c.path LIKE ?)" }.joined(separator: " OR ")
        let bindings = pathFilters.flatMap { path -> [String] in
            if path.isEmpty { return ["", "%"] }
            return [path, path + "/%"]
        }
        return (" AND (" + clauses + ")", bindings)
    }

    private func loadFileRecords() throws -> [String: FileRecord] {
        let statement = try prepare("SELECT path, content_hash, mtime FROM files;")
        defer { sqlite3_finalize(statement) }

        var records: [String: FileRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let contentHash = String(cString: sqlite3_column_text(statement, 1))
            let mtime = sqlite3_column_double(statement, 2)
            records[path] = FileRecord(contentHash: contentHash, mtime: mtime)
        }
        return records
    }

    private func loadChunks(for path: String) throws -> [String: ExistingChunkRecord] {
        let statement = try prepare("SELECT chunk_id, chunk_hash, start_line, end_line FROM chunks WHERE path = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, sqliteTransientDestructor)

        var rows: [String: ExistingChunkRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let chunkID = String(cString: sqlite3_column_text(statement, 0))
            let chunkHash = String(cString: sqlite3_column_text(statement, 1))
            let startLine = Int(sqlite3_column_int64(statement, 2))
            let endLine = Int(sqlite3_column_int64(statement, 3))
            rows[chunkID] = ExistingChunkRecord(chunkHash: chunkHash, startLine: startLine, endLine: endLine)
        }
        return rows
    }

    private func upsertFile(path: String, contentHash: String, mtime: Double) throws {
        let sql = """
        INSERT INTO files(path, content_hash, mtime, indexed_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            content_hash = excluded.content_hash,
            mtime = excluded.mtime,
            indexed_at = excluded.indexed_at;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, path, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 2, contentHash, -1, sqliteTransientDestructor)
        sqlite3_bind_double(statement, 3, mtime)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func upsertChunk(_ chunk: SwiftStructuredChunker.ChunkDescriptor, fileHash: String) throws {
        let sql = """
        INSERT INTO chunks(
            chunk_id, path, file_hash, chunk_hash, kind, symbol, parent_symbol,
            start_line, end_line, text, summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(chunk_id) DO UPDATE SET
            path = excluded.path,
            file_hash = excluded.file_hash,
            chunk_hash = excluded.chunk_hash,
            kind = excluded.kind,
            symbol = excluded.symbol,
            parent_symbol = excluded.parent_symbol,
            start_line = excluded.start_line,
            end_line = excluded.end_line,
            text = excluded.text,
            summary = excluded.summary;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chunk.chunkID, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 2, chunk.path, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 3, fileHash, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 4, chunk.chunkHash, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 5, chunk.kind, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 6, chunk.symbol, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 7, chunk.parentSymbol, -1, sqliteTransientDestructor)
        sqlite3_bind_int64(statement, 8, sqlite3_int64(chunk.startLine))
        sqlite3_bind_int64(statement, 9, sqlite3_int64(chunk.endLine))
        sqlite3_bind_text(statement, 10, chunk.text, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 11, chunk.summary, -1, sqliteTransientDestructor)
        try stepDone(statement)

        let deleteFTS = try prepare("DELETE FROM semantic_chunks_fts WHERE chunk_id = ?;")
        sqlite3_bind_text(deleteFTS, 1, chunk.chunkID, -1, sqliteTransientDestructor)
        _ = sqlite3_step(deleteFTS)
        sqlite3_finalize(deleteFTS)

        let insertFTS = try prepare("INSERT INTO semantic_chunks_fts(chunk_id, path, text, summary) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(insertFTS) }
        sqlite3_bind_text(insertFTS, 1, chunk.chunkID, -1, sqliteTransientDestructor)
        sqlite3_bind_text(insertFTS, 2, chunk.path, -1, sqliteTransientDestructor)
        sqlite3_bind_text(insertFTS, 3, chunk.text, -1, sqliteTransientDestructor)
        sqlite3_bind_text(insertFTS, 4, chunk.summary, -1, sqliteTransientDestructor)
        try stepDone(insertFTS)
    }

    private func deleteChunk(chunkID: String) throws {
        let deleteFTS = try prepare("DELETE FROM semantic_chunks_fts WHERE chunk_id = ?;")
        sqlite3_bind_text(deleteFTS, 1, chunkID, -1, sqliteTransientDestructor)
        _ = sqlite3_step(deleteFTS)
        sqlite3_finalize(deleteFTS)

        let statement = try prepare("DELETE FROM chunks WHERE chunk_id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, chunkID, -1, sqliteTransientDestructor)
        try stepDone(statement)
    }

    private func deleteFile(path: String) throws {
        let chunkIDs = try loadChunkIDs(for: path)
        for chunkID in chunkIDs {
            try deleteChunk(chunkID: chunkID)
        }

        let statement = try prepare("DELETE FROM files WHERE path = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, sqliteTransientDestructor)
        try stepDone(statement)
    }

    private func loadChunkIDs(for path: String) throws -> [String] {
        let statement = try prepare("SELECT chunk_id FROM chunks WHERE path = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, sqliteTransientDestructor)

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return ids
    }

    private func ensureDatabase() throws {
        if db != nil { return }

        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            throw SemanticSearchError.databaseOpenFailed(message)
        }

        db = handle
        sqlite3_busy_timeout(handle, 2_000)

        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA synchronous=NORMAL;")
        try execute(sql: "PRAGMA foreign_keys=ON;")
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            mtime REAL NOT NULL,
            indexed_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks (
            chunk_id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            file_hash TEXT NOT NULL,
            chunk_hash TEXT NOT NULL,
            kind TEXT NOT NULL,
            symbol TEXT NOT NULL,
            parent_symbol TEXT NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            text TEXT NOT NULL,
            summary TEXT NOT NULL,
            FOREIGN KEY(path) REFERENCES files(path) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);
        CREATE INDEX IF NOT EXISTS idx_chunks_start_line ON chunks(path, start_line);

        CREATE VIRTUAL TABLE IF NOT EXISTS semantic_chunks_fts USING fts5(
            chunk_id UNINDEXED,
            path UNINDEXED,
            text,
            summary,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
    }

    private func beginTransaction() throws {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
    }

    private func commitTransaction() throws {
        try execute(sql: "COMMIT;")
    }

    private func rollbackTransaction() throws {
        try execute(sql: "ROLLBACK;")
    }

    private func execute(sql: String) throws {
        guard let db else { throw SemanticSearchError.databaseOpenFailed("SQLite database not open.") }
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw SemanticSearchError.sqliteFailure(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw SemanticSearchError.databaseOpenFailed("SQLite database not open.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SemanticSearchError.sqliteFailure(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            guard let db else { throw SemanticSearchError.sqliteFailure("SQLite step failed.") }
            throw SemanticSearchError.sqliteFailure(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(pathFilters: [String], into statement: OpaquePointer?, startingAt index: inout Int32) {
        for value in pathFilters {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
            index += 1
        }
    }

    private static func snippet(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let snippet = lines.prefix(6).joined(separator: " ")
        if snippet.count <= 320 {
            return snippet
        }
        return String(snippet.prefix(317)) + "..."
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func tokenizedTerms(from query: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[a-z0-9_]+") else { return [] }
        let range = NSRange(location: 0, length: query.utf16.count)
        return regex.matches(in: query, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: query) else { return nil }
            return String(query[tokenRange])
        }
    }
}

private struct FileScanResult {
    let files: [URL]
    let removedRelativePaths: [String]
}

private struct FileRecord {
    let contentHash: String
    let mtime: Double
}

private struct ExistingChunkRecord {
    let chunkHash: String
    let startLine: Int
    let endLine: Int
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)