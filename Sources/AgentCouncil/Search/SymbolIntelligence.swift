import CryptoKit
import Foundation
import IndexStoreDB

public struct FindSymbolRequest: Sendable, Equatable {
    public let query: String
    public let maxResults: Int
    public let paths: [URL]

    public init(query: String, maxResults: Int = 12, paths: [URL] = []) {
        self.query = query
        self.maxResults = maxResults
        self.paths = paths
    }
}

public struct FindUsagesRequest: Sendable, Equatable {
    public let usr: String?
    public let path: URL?
    public let line: Int?
    public let column: Int?
    public let maxResults: Int
    public let paths: [URL]
    public let includeDefinitions: Bool

    public init(
        usr: String? = nil,
        path: URL? = nil,
        line: Int? = nil,
        column: Int? = nil,
        maxResults: Int = 200,
        paths: [URL] = [],
        includeDefinitions: Bool = true
    ) {
        self.usr = usr
        self.path = path
        self.line = line
        self.column = column
        self.maxResults = maxResults
        self.paths = paths
        self.includeDefinitions = includeDefinitions
    }
}

public struct FoundSymbolMatch: Sendable, Codable, Equatable {
    public let usr: String
    public let name: String
    public let kind: String
    public let language: String
    public let path: String
    public let line: Int
    public let column: Int
    public let sourceKitPlaceholder: String?
    public let chunkSummary: String?

    enum CodingKeys: String, CodingKey {
        case usr, name, kind, language, path, line, column
        case sourceKitPlaceholder = "sourcekit_placeholder"
        case chunkSummary = "chunk_summary"
    }
}

public struct FoundSymbolResult: Sendable, Codable, Equatable {
    public let query: String
    public let queryTimeMs: Int
    public let totalMatches: Int
    public let returnedMatches: Int
    public let truncated: Bool
    public let matches: [FoundSymbolMatch]

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

public struct SymbolUsageResolution: Sendable, Codable, Equatable {
    public let usr: String
    public let name: String
    public let kind: String
    public let language: String
    public let path: String
    public let line: Int
    public let column: Int
    public let sourceKitPlaceholder: String?
    public let chunkSummary: String?

    enum CodingKeys: String, CodingKey {
        case usr, name, kind, language, path, line, column
        case sourceKitPlaceholder = "sourcekit_placeholder"
        case chunkSummary = "chunk_summary"
    }
}

public struct SymbolUsageMatch: Sendable, Codable, Equatable {
    public let path: String
    public let line: Int
    public let column: Int
    public let role: String
    public let kind: String
    public let language: String
    public let chunkSummary: String?

    enum CodingKeys: String, CodingKey {
        case path, line, column, role, kind, language
        case chunkSummary = "chunk_summary"
    }
}

public struct FindUsagesResult: Sendable, Codable, Equatable {
    public let queryTimeMs: Int
    public let totalMatches: Int
    public let returnedMatches: Int
    public let truncated: Bool
    public let resolvedSymbol: SymbolUsageResolution
    public let matches: [SymbolUsageMatch]

    enum CodingKeys: String, CodingKey {
        case truncated, matches
        case queryTimeMs = "query_time_ms"
        case totalMatches = "total_matches"
        case returnedMatches = "returned_matches"
        case resolvedSymbol = "resolved_symbol"
    }

    public func prettyPrintedJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public enum SymbolIntelligenceError: LocalizedError, Sendable {
    case emptyQuery
    case invalidUsageInput
    case noIndexStoreFound
    case staleIndex(path: String)
    case symbolNotFound(path: String, line: Int, column: Int)
    case unsupportedSourceKit(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Symbol query cannot be empty."
        case .invalidUsageInput:
            return "find_usages requires either a USR or an exact path + line + column."
        case .noIndexStoreFound:
            return "No usable index store was found. Build the workspace first so IndexStoreDB has data to read."
        case .staleIndex(let path):
            return "The symbol index is stale for \(path). Rebuild the workspace before using symbol-aware tools."
        case .symbolNotFound(let path, let line, let column):
            return "No indexed symbol was found at \(path):\(line):\(column). Use an exact symbol location or rebuild if the index is stale."
        case .unsupportedSourceKit(let message):
            return message
        }
    }
}

public actor SymbolIntelligenceService {

    private let projectRoot: URL
    private let sourceKit: SourceKitLSPClient
    private var indexLibrary: IndexStoreLibrary?
    private var openedIndexes: [String: OpenedIndex] = [:]
    private var chunkCache: [String: [SwiftStructuredChunker.ChunkDescriptor]] = [:]

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.sourceKit = SourceKitLSPClient(projectRoot: projectRoot)
    }

    public func findSymbols(request: FindSymbolRequest) async throws -> FoundSymbolResult {
        let startedAt = Date()
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SymbolIntelligenceError.emptyQuery }

        let indexes = try loadIndexes()
        guard !indexes.isEmpty else { throw SymbolIntelligenceError.noIndexStoreFound }

        let scopes = normalizedScopePaths(from: request.paths)
        let rawCandidates = indexes.flatMap { index in
            index.db.canonicalOccurrences(
                containing: query,
                anchorStart: false,
                anchorEnd: false,
                subsequence: false,
                ignoreCase: true
            )
        }

        let filtered = rawCandidates.compactMap { occurrence -> CandidateSymbol? in
            guard let relativePath = workspaceRelativePath(for: occurrence.location.path) else { return nil }
            guard scopes.isEmpty || pathMatchesScopes(relativePath, scopes: scopes) else { return nil }
            guard !occurrence.location.isSystem else { return nil }
            return CandidateSymbol(
                usr: occurrence.symbol.usr,
                name: occurrence.symbol.name,
                kind: occurrence.symbol.kind,
                language: occurrence.symbol.language,
                relativePath: relativePath,
                absolutePath: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
                score: candidateScore(for: occurrence.symbol.name, query: query)
            )
        }

        let deduped = Dictionary(grouping: filtered, by: \ .usr)
            .values
            .compactMap { bucket in
                bucket.min { lhs, rhs in lhs.sortKey < rhs.sortKey }
            }
            .sorted { lhs, rhs in lhs.sortKey < rhs.sortKey }

        let maxResults = min(max(request.maxResults, 1), 50)
        var validated: [FoundSymbolMatch] = []
        for candidate in deduped {
            let fileURL = URL(fileURLWithPath: candidate.absolutePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let prepareRename = try? await sourceKit.prepareRename(
                fileURL: fileURL,
                line: candidate.line,
                utf8Column: candidate.column
            )
            let definitionLocations = try? await sourceKit.definition(
                fileURL: fileURL,
                line: candidate.line,
                utf8Column: candidate.column
            )

            if prepareRename == nil,
               (definitionLocations?.contains { $0.path == candidate.absolutePath } != true) {
                continue
            }

            validated.append(
                FoundSymbolMatch(
                    usr: candidate.usr,
                    name: candidate.name,
                    kind: kindLabel(candidate.kind),
                    language: languageLabel(candidate.language),
                    path: candidate.relativePath,
                    line: candidate.line,
                    column: candidate.column,
                    sourceKitPlaceholder: prepareRename?.placeholder,
                    chunkSummary: chunkSummary(forAbsolutePath: candidate.absolutePath, relativePath: candidate.relativePath, line: candidate.line)
                )
            )

            if validated.count >= maxResults {
                break
            }
        }

        let elapsedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        return FoundSymbolResult(
            query: query,
            queryTimeMs: elapsedMs,
            totalMatches: deduped.count,
            returnedMatches: validated.count,
            truncated: deduped.count > validated.count,
            matches: validated
        )
    }

    public func findUsages(request: FindUsagesRequest) async throws -> FindUsagesResult {
        let startedAt = Date()
        let indexes = try loadIndexes()
        guard !indexes.isEmpty else { throw SymbolIntelligenceError.noIndexStoreFound }

        let scopes = normalizedScopePaths(from: request.paths)
        let resolved = try await resolveSymbol(request: request, indexes: indexes)

        let roles = request.includeDefinitions
            ? SymbolRole.definition.union(.declaration).union(.reference).union(.call).union(.read).union(.write)
            : SymbolRole.reference.union(.call).union(.read).union(.write)

        let occurrences = indexes.flatMap { $0.db.occurrences(ofUSR: resolved.usr, roles: roles) }
        let matches = occurrences.compactMap { occurrence -> UsageOccurrence? in
            guard let relativePath = workspaceRelativePath(for: occurrence.location.path) else { return nil }
            guard scopes.isEmpty || pathMatchesScopes(relativePath, scopes: scopes) else { return nil }
            return UsageOccurrence(
                relativePath: relativePath,
                absolutePath: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
                role: roleLabel(for: occurrence.roles),
                kind: kindLabel(occurrence.symbol.kind),
                language: languageLabel(occurrence.symbol.language)
            )
        }

        let uniqueMatches = Array(Set(matches)).sorted { lhs, rhs in lhs.sortKey < rhs.sortKey }
        let maxResults = min(max(request.maxResults, 1), 500)
        let limitedMatches = uniqueMatches.prefix(maxResults).map { occurrence in
            SymbolUsageMatch(
                path: occurrence.relativePath,
                line: occurrence.line,
                column: occurrence.column,
                role: occurrence.role,
                kind: occurrence.kind,
                language: occurrence.language,
                chunkSummary: chunkSummary(forAbsolutePath: occurrence.absolutePath, relativePath: occurrence.relativePath, line: occurrence.line)
            )
        }

        let elapsedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        return FindUsagesResult(
            queryTimeMs: elapsedMs,
            totalMatches: uniqueMatches.count,
            returnedMatches: limitedMatches.count,
            truncated: uniqueMatches.count > limitedMatches.count,
            resolvedSymbol: SymbolUsageResolution(
                usr: resolved.usr,
                name: resolved.name,
                kind: resolved.kind,
                language: resolved.language,
                path: resolved.path,
                line: resolved.line,
                column: resolved.column,
                sourceKitPlaceholder: resolved.sourceKitPlaceholder,
                chunkSummary: resolved.chunkSummary
            ),
            matches: limitedMatches
        )
    }

    private func resolveSymbol(request: FindUsagesRequest, indexes: [OpenedIndex]) async throws -> ResolvedSymbol {
        if let usr = request.usr?.trimmingCharacters(in: .whitespacesAndNewlines), !usr.isEmpty {
            let definitions = indexes
                .flatMap { $0.db.occurrences(ofUSR: usr, roles: SymbolRole.definition.union(.declaration)) }
                .compactMap { occurrence -> ResolvedSymbol? in
                    guard let relativePath = workspaceRelativePath(for: occurrence.location.path),
                          !occurrence.location.isSystem else {
                        return nil
                    }
                    return ResolvedSymbol(
                        usr: usr,
                        name: occurrence.symbol.name,
                        kind: kindLabel(occurrence.symbol.kind),
                        language: languageLabel(occurrence.symbol.language),
                        path: relativePath,
                        absolutePath: occurrence.location.path,
                        line: occurrence.location.line,
                        column: occurrence.location.utf8Column,
                        sourceKitPlaceholder: nil,
                        chunkSummary: chunkSummary(forAbsolutePath: occurrence.location.path, relativePath: relativePath, line: occurrence.location.line)
                    )
                }
                .sorted { lhs, rhs in lhs.sortKey < rhs.sortKey }

            guard let resolved = definitions.first else {
                throw SymbolIntelligenceError.symbolNotFound(path: usr, line: 0, column: 0)
            }

            let fileURL = URL(fileURLWithPath: resolved.absolutePath)
            let prepareRename = try? await sourceKit.prepareRename(fileURL: fileURL, line: resolved.line, utf8Column: resolved.column)
            return resolved.withSourceKitPlaceholder(prepareRename?.placeholder)
        }

        guard let path = request.path,
              let line = request.line,
              let column = request.column else {
            throw SymbolIntelligenceError.invalidUsageInput
        }

        let targetURL = path.standardizedFileURL
        let targetPath = workspaceRelativePath(for: targetURL.path) ?? targetURL.lastPathComponent
        try assertFreshIndex(for: targetURL, indexes: indexes)

        guard let prepareRename = try await sourceKit.prepareRename(fileURL: targetURL, line: line, utf8Column: column) else {
            let diagnostics = try? await sourceKit.documentDiagnostics(fileURL: targetURL)
            if let diagnostics, !diagnostics.isEmpty {
                let first = diagnostics[0]
                throw SymbolIntelligenceError.unsupportedSourceKit(
                    "SourceKit could not prepare rename at \(targetPath):\(line):\(column). First diagnostic: \(first.message)"
                )
            }
            throw SymbolIntelligenceError.symbolNotFound(path: targetPath, line: line, column: column)
        }

        let candidateOccurrence = try indexedOccurrence(at: targetURL, line: line, column: column, indexes: indexes)
        let relativePath = workspaceRelativePath(for: candidateOccurrence.location.path) ?? targetURL.lastPathComponent
        return ResolvedSymbol(
            usr: candidateOccurrence.symbol.usr,
            name: candidateOccurrence.symbol.name,
            kind: kindLabel(candidateOccurrence.symbol.kind),
            language: languageLabel(candidateOccurrence.symbol.language),
            path: relativePath,
            absolutePath: candidateOccurrence.location.path,
            line: candidateOccurrence.location.line,
            column: candidateOccurrence.location.utf8Column,
            sourceKitPlaceholder: prepareRename.placeholder,
            chunkSummary: chunkSummary(forAbsolutePath: candidateOccurrence.location.path, relativePath: relativePath, line: candidateOccurrence.location.line)
        )
    }

    private func indexedOccurrence(at fileURL: URL, line: Int, column: Int, indexes: [OpenedIndex]) throws -> SymbolOccurrence {
        let matches = indexes
            .flatMap { $0.db.symbolOccurrences(inFilePath: fileURL.path) }
            .filter { !$0.location.isSystem && $0.location.line == line }
            .sorted { lhs, rhs in
                let lhsDistance = abs(lhs.location.utf8Column - column)
                let rhsDistance = abs(rhs.location.utf8Column - column)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return (lhs.location.utf8Column, lhs.symbol.usr) < (rhs.location.utf8Column, rhs.symbol.usr)
            }

        guard let occurrence = matches.first,
              occurrence.location.utf8Column == column else {
            throw SymbolIntelligenceError.symbolNotFound(
                path: workspaceRelativePath(for: fileURL.path) ?? fileURL.lastPathComponent,
                line: line,
                column: column
            )
        }

        return occurrence
    }

    private func assertFreshIndex(for fileURL: URL, indexes: [OpenedIndex]) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modificationDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let indexedDate = indexes.compactMap { $0.db.dateOfLatestUnitFor(filePath: fileURL.path) }.max() ?? .distantPast
        guard indexedDate >= modificationDate else {
            throw SymbolIntelligenceError.staleIndex(path: workspaceRelativePath(for: fileURL.path) ?? fileURL.lastPathComponent)
        }
    }

    private func loadIndexes() throws -> [OpenedIndex] {
        let descriptors = IndexStoreLocator.discover(projectRoot: projectRoot)
        guard !descriptors.isEmpty else { return [] }

        let library = try indexStoreLibrary()
        var loaded: [OpenedIndex] = []
        for descriptor in descriptors {
            if let existing = openedIndexes[descriptor.storeURL.path] {
                existing.db.pollForUnitChangesAndWait(isInitialScan: false)
                loaded.append(existing)
                continue
            }

            try FileManager.default.createDirectory(
                at: descriptor.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let db = try IndexStoreDB(
                storePath: descriptor.storeURL.path,
                databasePath: descriptor.databaseURL.path,
                library: library,
                waitUntilDoneInitializing: true,
                readonly: false,
                enableOutOfDateFileWatching: false,
                listenToUnitEvents: true
            )
            db.pollForUnitChangesAndWait(isInitialScan: false)

            let opened = OpenedIndex(descriptor: descriptor, db: db)
            openedIndexes[descriptor.storeURL.path] = opened
            loaded.append(opened)
        }
        return loaded.sorted { lhs, rhs in lhs.descriptor.sortKey < rhs.descriptor.sortKey }
    }

    private func indexStoreLibrary() throws -> IndexStoreLibrary {
        if let indexLibrary {
            return indexLibrary
        }

        let swiftcOutput = try Self.runTool(arguments: ["--find", "swiftc"])
        let swiftcPath = swiftcOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolchainRoot = URL(fileURLWithPath: swiftcPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let libraryPath = toolchainRoot
            .appendingPathComponent("usr/lib/libIndexStore.dylib")
            .path
        let library = try IndexStoreLibrary(dylibPath: libraryPath)
        indexLibrary = library
        return library
    }

    private func chunkSummary(forAbsolutePath absolutePath: String, relativePath: String, line: Int) -> String? {
        if let cached = chunkCache[absolutePath] {
            return cached
                .filter { $0.startLine <= line && $0.endLine >= line }
                .min { lhs, rhs in (lhs.endLine - lhs.startLine, lhs.startLine) < (rhs.endLine - rhs.startLine, rhs.startLine) }?
                .summary
        }

        guard let source = try? String(contentsOf: URL(fileURLWithPath: absolutePath), encoding: .utf8) else {
            return nil
        }

        let chunks = SwiftStructuredChunker.chunkFile(path: relativePath, source: source)
        chunkCache[absolutePath] = chunks
        return chunks
            .filter { $0.startLine <= line && $0.endLine >= line }
            .min { lhs, rhs in (lhs.endLine - lhs.startLine, lhs.startLine) < (rhs.endLine - rhs.startLine, rhs.startLine) }?
            .summary
    }

    private func normalizedScopePaths(from paths: [URL]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let relative = relativeScopePath(for: path.standardizedFileURL), seen.insert(relative).inserted else { continue }
            normalized.append(relative)
        }
        return normalized.sorted()
    }

    private func relativeScopePath(for url: URL) -> String? {
        let rootPath = projectRoot.path
        let normalizedPath = url.standardizedFileURL.path
        guard normalizedPath == rootPath || normalizedPath.hasPrefix(rootPath + "/") else { return nil }
        if normalizedPath == rootPath { return "" }
        return String(normalizedPath.dropFirst(rootPath.count + 1))
    }

    private func workspaceRelativePath(for absolutePath: String) -> String? {
        let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let root = projectRoot.path
        guard normalized.hasPrefix(root + "/") else { return nil }
        return String(normalized.dropFirst(root.count + 1))
    }

    private func pathMatchesScopes(_ relativePath: String, scopes: [String]) -> Bool {
        guard !scopes.isEmpty else { return true }
        return scopes.contains { scope in
            scope.isEmpty || relativePath == scope || relativePath.hasPrefix(scope + "/")
        }
    }

    private func candidateScore(for symbolName: String, query: String) -> Int {
        let normalizedName = symbolName.lowercased()
        let normalizedQuery = query.lowercased()
        if normalizedName == normalizedQuery { return 0 }
        if normalizedName.hasPrefix(normalizedQuery) { return 1 }
        if normalizedName.contains(normalizedQuery) { return 2 }
        return 3
    }

    private func kindLabel(_ kind: IndexSymbolKind) -> String {
        switch kind {
        case .unknown: return "unknown"
        case .module: return "module"
        case .namespace: return "namespace"
        case .namespaceAlias: return "namespace_alias"
        case .macro: return "macro"
        case .enum: return "enum"
        case .struct: return "struct"
        case .class: return "class"
        case .protocol: return "protocol"
        case .extension: return "extension"
        case .union: return "union"
        case .typealias: return "typealias"
        case .function: return "function"
        case .variable: return "variable"
        case .field: return "field"
        case .enumConstant: return "enum_constant"
        case .instanceMethod: return "instance_method"
        case .classMethod: return "class_method"
        case .staticMethod: return "static_method"
        case .instanceProperty: return "instance_property"
        case .classProperty: return "class_property"
        case .staticProperty: return "static_property"
        case .constructor: return "constructor"
        case .destructor: return "destructor"
        case .conversionFunction: return "conversion_function"
        case .parameter: return "parameter"
        case .using: return "using"
        case .concept: return "concept"
        case .commentTag: return "comment_tag"
        }
    }

    private func languageLabel(_ language: Language) -> String {
        switch language {
        case .c: return "c"
        case .cxx: return "cxx"
        case .objc: return "objc"
        case .swift: return "swift"
        }
    }

    private func roleLabel(for roles: SymbolRole) -> String {
        if roles.contains(.definition) { return "definition" }
        if roles.contains(.declaration) { return "declaration" }
        if roles.contains(.call) { return "call" }
        if roles.contains(.write) { return "write" }
        if roles.contains(.read) { return "read" }
        if roles.contains(.reference) { return "reference" }
        return "occurrence"
    }

    private static func runTool(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SymbolIntelligenceError.unsupportedSourceKit(
                error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Failed to run xcrun \(arguments.joined(separator: " "))."
                : error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}

private struct CandidateSymbol {
    let usr: String
    let name: String
    let kind: IndexSymbolKind
    let language: Language
    let relativePath: String
    let absolutePath: String
    let line: Int
    let column: Int
    let score: Int

    var sortKey: (Int, String, String, Int, Int, String) {
        (score, name.lowercased(), relativePath, line, column, usr)
    }
}

private struct UsageOccurrence: Hashable {
    let relativePath: String
    let absolutePath: String
    let line: Int
    let column: Int
    let role: String
    let kind: String
    let language: String

    var sortKey: (Int, String, Int, Int, String) {
        (roleRank, relativePath, line, column, role)
    }

    private var roleRank: Int {
        switch role {
        case "definition": return 0
        case "declaration": return 1
        case "call": return 2
        case "write": return 3
        case "read": return 4
        case "reference": return 5
        default: return 6
        }
    }
}

private struct ResolvedSymbol {
    let usr: String
    let name: String
    let kind: String
    let language: String
    let path: String
    let absolutePath: String
    let line: Int
    let column: Int
    let sourceKitPlaceholder: String?
    let chunkSummary: String?

    var sortKey: (String, Int, Int, String) {
        (path, line, column, usr)
    }

    func withSourceKitPlaceholder(_ placeholder: String?) -> ResolvedSymbol {
        ResolvedSymbol(
            usr: usr,
            name: name,
            kind: kind,
            language: language,
            path: path,
            absolutePath: absolutePath,
            line: line,
            column: column,
            sourceKitPlaceholder: placeholder,
            chunkSummary: chunkSummary
        )
    }
}

private struct OpenedIndex {
    let descriptor: IndexStoreDescriptor
    let db: IndexStoreDB
}

private struct IndexStoreDescriptor {
    enum Kind: Int {
        case xcode = 0
        case swiftPM = 1
    }

    let kind: Kind
    let storeURL: URL
    let databaseURL: URL

    var sortKey: (Int, String) {
        (kind.rawValue, storeURL.path)
    }
}

private enum IndexStoreLocator {

    static func discover(projectRoot: URL) -> [IndexStoreDescriptor] {
        let buildRoot = projectRoot.appendingPathComponent(".build", isDirectory: true)
        let derivedDataRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let xcodeProjectNames = projectNames(in: projectRoot)

        var descriptors: [IndexStoreDescriptor] = []
        descriptors.append(contentsOf: swiftPMDescriptors(projectRoot: projectRoot, buildRoot: buildRoot))
        descriptors.append(contentsOf: xcodeDescriptors(projectRoot: projectRoot, derivedDataRoot: derivedDataRoot, projectNames: xcodeProjectNames))

        var seen = Set<String>()
        return descriptors
            .filter { seen.insert($0.storeURL.path).inserted }
            .sorted { $0.sortKey < $1.sortKey }
    }

    private static func swiftPMDescriptors(projectRoot: URL, buildRoot: URL) -> [IndexStoreDescriptor] {
        guard FileManager.default.fileExists(atPath: buildRoot.path),
              let enumerator = FileManager.default.enumerator(
                at: buildRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [IndexStoreDescriptor] = []
        for case let url as URL in enumerator {
            guard url.path.hasSuffix("/index/store") else { continue }
            let hash = hashPath(url.path)
            let databaseURL = projectRoot
                .appendingPathComponent(".studio92/index/indexstoredb", isDirectory: true)
                .appendingPathComponent("swiftpm-\(hash)", isDirectory: false)
            results.append(IndexStoreDescriptor(kind: .swiftPM, storeURL: url, databaseURL: databaseURL))
        }
        return results
    }

    private static func xcodeDescriptors(projectRoot: URL, derivedDataRoot: URL, projectNames: [String]) -> [IndexStoreDescriptor] {
        guard FileManager.default.fileExists(atPath: derivedDataRoot.path),
              let children = try? FileManager.default.contentsOfDirectory(
                at: derivedDataRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return children
            .filter { directory in
                projectNames.contains { projectName in
                    directory.lastPathComponent.hasPrefix(projectName + "-")
                }
            }
            .compactMap { directory in
                let storeURL = directory
                    .appendingPathComponent("Index.noindex", isDirectory: true)
                    .appendingPathComponent("DataStore", isDirectory: true)
                guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
                let hash = hashPath(storeURL.path)
                let databaseURL = projectRoot
                    .appendingPathComponent(".studio92/index/indexstoredb", isDirectory: true)
                    .appendingPathComponent("xcode-\(hash)", isDirectory: false)
                return IndexStoreDescriptor(kind: .xcode, storeURL: storeURL, databaseURL: databaseURL)
            }
    }

    private static func projectNames(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var names = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "xcodeproj" {
            names.insert(url.deletingPathExtension().lastPathComponent)
        }
        return names.sorted()
    }

    private static func hashPath(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}