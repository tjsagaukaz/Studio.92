import Foundation
import Observation

enum AmbientContextInfluenceLevel: String, Codable, Sendable {
    case minimal
    case standard
    case full
}

enum AmbientContextSubsystem: String, Sendable {
    case modelRouting
    case taskPlanning
    case toolDispatch
    case promptAssembly
}

enum AmbientContextFocusSource: String, Codable, Sendable {
    case selection
    case currentFile
    case diagnostics
    case recentEdits
}

enum AmbientContextConflictReason: String, Codable, Sendable {
    case selectionOverridesOtherSignals
    case ambiguousNonSelectionSignals
}

enum AmbientDiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
    case note
}

struct CurrentFileContext: Equatable, Sendable {
    let path: String
    let language: String?
    let cursorLine: Int?
    let cursorColumn: Int?
    let nearbyLineRange: ClosedRange<Int>?
    let nearbySnippet: String?
    let isDirty: Bool
    let observedAt: Date

    func withoutCursor() -> CurrentFileContext {
        CurrentFileContext(
            path: path,
            language: language,
            cursorLine: nil,
            cursorColumn: nil,
            nearbyLineRange: nil,
            nearbySnippet: nil,
            isDirty: isDirty,
            observedAt: observedAt
        )
    }
}

struct SelectedRangeContext: Equatable, Sendable {
    let path: String
    let startLine: Int
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
    let selectedText: String
    let isTruncated: Bool
    let observedAt: Date

    var summary: String {
        let collapsed = selectedText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(collapsed.prefix(160))
        return "lines \(startLine)-\(endLine), \(selectedText.count) chars: \(preview)"
    }
}

struct OpenFileContext: Equatable, Sendable {
    let path: String
    let language: String?
    let isDirty: Bool
    let lastFocusedAt: Date
}

struct OpenFilesContext: Equatable, Sendable {
    let files: [OpenFileContext]
    let observedAt: Date?

    static let empty = OpenFilesContext(files: [], observedAt: nil)
}

struct RecentEditContext: Equatable, Sendable {
    let path: String
    let changedLineRange: ClosedRange<Int>?
    let timestamp: Date
    let source: String
}

struct EditorDiagnosticContext: Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?
    let severity: AmbientDiagnosticSeverity
    let message: String
    let source: String
    let observedAt: Date
}

struct DiagnosticsContext: Equatable, Sendable {
    let items: [EditorDiagnosticContext]
    let observedAt: Date?

    static let empty = DiagnosticsContext(items: [], observedAt: nil)

    var errorCount: Int {
        items.filter { $0.severity == .error }.count
    }
}

struct GitContext: Equatable, Sendable {
    let branchName: String?
    let aheadCount: Int
    let behindCount: Int
    let stagedCount: Int
    let unstagedCount: Int
    let conflictedCount: Int
    let observedAt: Date
}

struct AmbientContextConflict: Equatable, Sendable {
    let reason: AmbientContextConflictReason
    let preferredSource: AmbientContextFocusSource?
    let preferredPath: String?
    let conflictingPaths: [String]
}

struct AmbientContextFocus: Equatable, Sendable {
    let source: AmbientContextFocusSource
    let path: String
}

struct AmbientEditorContext: Equatable, Sendable {
    let contextID: UUID
    let capturedAt: Date
    let lastUpdatedAt: Date?
    let influenceLevel: AmbientContextInfluenceLevel
    let selectionFreshnessMs: Int?
    let currentFile: CurrentFileContext?
    let selectedRange: SelectedRangeContext?
    let openFiles: OpenFilesContext
    let recentEdits: [RecentEditContext]
    let diagnostics: DiagnosticsContext
    let gitContext: GitContext?
    let conflict: AmbientContextConflict?

    static let selectionStalenessThreshold: TimeInterval = 30

    static var selectionStalenessThresholdMs: Int {
        Int(selectionStalenessThreshold * 1_000)
    }

    var age: TimeInterval {
        capturedAt.timeIntervalSince(lastUpdatedAt ?? capturedAt)
    }

    var hasFreshSelection: Bool {
        guard selectedRange != nil, let selectionFreshnessMs else { return false }
        return selectionFreshnessMs <= Self.selectionStalenessThresholdMs
    }

    var traceAttributes: [String: String] {
        var attributes: [String: String] = [
            "ambient.context_id": contextID.uuidString,
            "ambient.selection_freshness_ms": selectionFreshnessMs.map(String.init) ?? "none",
            "ambient.has_fresh_selection": hasFreshSelection ? "true" : "false"
        ]
        if let currentFile {
            attributes["ambient.current_file"] = currentFile.path
        }
        if let selectedRange {
            attributes["ambient.selection_path"] = selectedRange.path
        }
        return attributes
    }

    var toolDispatchPath: String? {
        if let selectedRange, hasFreshSelection {
            return selectedRange.path
        }
        return currentFile?.path
    }

    var toolDispatchCursor: (line: Int, column: Int)? {
        if let selectedRange, hasFreshSelection {
            return (selectedRange.startLine, selectedRange.startColumn)
        }
        guard let currentFile,
              let cursorLine = currentFile.cursorLine,
              let cursorColumn = currentFile.cursorColumn else {
            return nil
        }
        return (cursorLine, cursorColumn)
    }

    func scoped(
        for subsystem: AmbientContextSubsystem,
        influenceLevel: AmbientContextInfluenceLevel
    ) -> AmbientEditorContext {
        let selectionIsFresh = hasFreshSelection
        let currentFileValue = selectionIsFresh ? currentFile : currentFile?.withoutCursor()
        let selectionValue = selectionIsFresh ? selectedRange : nil

        let currentFileScoped: CurrentFileContext?
        let openFilesScoped: OpenFilesContext
        let recentEditsScoped: [RecentEditContext]
        let diagnosticsScoped: DiagnosticsContext
        let gitScoped: GitContext?

        switch subsystem {
        case .modelRouting:
            currentFileScoped = nil
            openFilesScoped = .empty
            recentEditsScoped = limitedRecentEdits(for: influenceLevel)
            diagnosticsScoped = limitedDiagnostics(for: influenceLevel)
            gitScoped = nil
        case .taskPlanning:
            currentFileScoped = currentFileValue
            openFilesScoped = limitedOpenFiles(for: influenceLevel)
            recentEditsScoped = []
            diagnosticsScoped = .empty
            gitScoped = nil
        case .toolDispatch:
            currentFileScoped = currentFileValue
            openFilesScoped = .empty
            recentEditsScoped = []
            diagnosticsScoped = .empty
            gitScoped = nil
        case .promptAssembly:
            currentFileScoped = currentFileValue
            openFilesScoped = influenceLevel == .full ? limitedOpenFiles(for: influenceLevel) : .empty
            recentEditsScoped = []
            diagnosticsScoped = .empty
            gitScoped = nil
        }

        return AmbientEditorContext(
            contextID: contextID,
            capturedAt: capturedAt,
            lastUpdatedAt: lastUpdatedAt,
            influenceLevel: influenceLevel,
            selectionFreshnessMs: selectionFreshnessMs,
            currentFile: currentFileScoped,
            selectedRange: selectionValue,
            openFiles: openFilesScoped,
            recentEdits: recentEditsScoped,
            diagnostics: diagnosticsScoped,
            gitContext: gitScoped,
            conflict: scopedConflict(for: subsystem, selectionIsFresh: selectionIsFresh)
        )
    }

    func routingFocus() -> AmbientContextFocus? {
        if let selectedRange, hasFreshSelection {
            return AmbientContextFocus(source: .selection, path: selectedRange.path)
        }

        let diagnosticPaths = Set(diagnostics.items.map(\.path))
        if diagnosticPaths.count == 1, let path = diagnosticPaths.first {
            return AmbientContextFocus(source: .diagnostics, path: path)
        }

        let recentEditPaths = Set(recentEdits.map(\.path))
        if recentEditPaths.count == 1, let path = recentEditPaths.first {
            return AmbientContextFocus(source: .recentEdits, path: path)
        }

        return nil
    }

    func planningFocus() -> AmbientContextFocus? {
        if let selectedRange, hasFreshSelection {
            return AmbientContextFocus(source: .selection, path: selectedRange.path)
        }
        if let currentFile {
            return AmbientContextFocus(source: .currentFile, path: currentFile.path)
        }
        if openFiles.files.count == 1, let onlyFile = openFiles.files.first {
            return AmbientContextFocus(source: .currentFile, path: onlyFile.path)
        }
        return nil
    }

    func promptInjectionBlock(workspaceRoot: String?) -> String? {
        guard currentFile != nil || selectedRange != nil else { return nil }

        var lines = ["### AMBIENT EDITOR CONTEXT ###"]
        lines.append("context_id: \(contextID.uuidString)")
        if let currentFile {
            lines.append("current_file: \(displayPath(currentFile.path, workspaceRoot: workspaceRoot))")
            if let cursorLine = currentFile.cursorLine, let cursorColumn = currentFile.cursorColumn {
                lines.append("cursor: \(cursorLine):\(cursorColumn)")
            }
        }
        if let selectionFreshnessMs {
            lines.append("selection_freshness_ms: \(selectionFreshnessMs)")
        }
        if let selectedRange {
            lines.append("selection: \(selectedRange.summary)")
        } else {
            lines.append("selection: none")
        }
        if let conflict {
            lines.append("focus_conflict: \(conflict.reason.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    private func limitedOpenFiles(for influenceLevel: AmbientContextInfluenceLevel) -> OpenFilesContext {
        let count: Int
        switch influenceLevel {
        case .minimal: count = 1
        case .standard: count = 5
        case .full: count = openFiles.files.count
        }
        let files = Array(openFiles.files.prefix(count))
        return OpenFilesContext(files: files, observedAt: openFiles.observedAt)
    }

    private func limitedRecentEdits(for influenceLevel: AmbientContextInfluenceLevel) -> [RecentEditContext] {
        let count: Int
        switch influenceLevel {
        case .minimal: count = 0
        case .standard: count = 5
        case .full: count = recentEdits.count
        }
        return Array(recentEdits.prefix(count))
    }

    private func limitedDiagnostics(for influenceLevel: AmbientContextInfluenceLevel) -> DiagnosticsContext {
        let count: Int
        switch influenceLevel {
        case .minimal: count = 1
        case .standard: count = 6
        case .full: count = diagnostics.items.count
        }
        return DiagnosticsContext(items: Array(diagnostics.items.prefix(count)), observedAt: diagnostics.observedAt)
    }

    private func scopedConflict(for subsystem: AmbientContextSubsystem, selectionIsFresh: Bool) -> AmbientContextConflict? {
        guard let conflict else { return nil }
        switch subsystem {
        case .modelRouting, .taskPlanning, .promptAssembly:
            if conflict.reason == .selectionOverridesOtherSignals && !selectionIsFresh {
                return nil
            }
            return conflict
        case .toolDispatch:
            return nil
        }
    }

    private func displayPath(_ path: String, workspaceRoot: String?) -> String {
        guard let workspaceRoot, path.hasPrefix(workspaceRoot) else { return path }
        let trimmed = path.dropFirst(workspaceRoot.count)
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : String(trimmed)
    }
}

@MainActor
@Observable
final class AmbientEditorContextCoordinator {

    private static let maxRecentEdits = 20
    private static let maxDiagnostics = 40

    private(set) var workspaceRoot: String
    private(set) var currentFile: CurrentFileContext?
    private(set) var selectedRange: SelectedRangeContext?
    private(set) var openFiles = OpenFilesContext.empty
    private(set) var recentEdits: [RecentEditContext] = []
    private(set) var diagnostics = DiagnosticsContext.empty
    private(set) var gitContext: GitContext?
    private(set) var lastUpdatedAt: Date?

    init(workspaceURL: URL) {
        self.workspaceRoot = workspaceURL.standardizedFileURL.path
    }

    func updateWorkspaceRoot(_ workspaceURL: URL) {
        workspaceRoot = workspaceURL.standardizedFileURL.path
        reset()
    }

    func reset() {
        currentFile = nil
        selectedRange = nil
        openFiles = .empty
        recentEdits = []
        diagnostics = .empty
        gitContext = nil
        lastUpdatedAt = nil
    }

    func notePresentedFile(
        path: String,
        language: String?,
        isDirty: Bool,
        content: String?,
        observedAt: Date = Date(),
        openFiles: [OpenFileContext] = []
    ) {
        guard let normalizedPath = normalize(path) else { return }

        currentFile = CurrentFileContext(
            path: normalizedPath,
            language: language,
            cursorLine: currentFile?.path == normalizedPath ? currentFile?.cursorLine : nil,
            cursorColumn: currentFile?.path == normalizedPath ? currentFile?.cursorColumn : nil,
            nearbyLineRange: currentFile?.path == normalizedPath ? currentFile?.nearbyLineRange : nil,
            nearbySnippet: currentFile?.path == normalizedPath ? currentFile?.nearbySnippet : nil,
            isDirty: isDirty,
            observedAt: observedAt
        )

        if !openFiles.isEmpty {
            self.openFiles = OpenFilesContext(
                files: deduplicatedOpenFiles(openFiles, currentPath: normalizedPath),
                observedAt: observedAt
            )
        } else {
            self.openFiles = OpenFilesContext(
                files: [OpenFileContext(path: normalizedPath, language: language, isDirty: isDirty, lastFocusedAt: observedAt)],
                observedAt: observedAt
            )
        }

        if let content, currentFile?.cursorLine == nil {
            currentFile = CurrentFileContext(
                path: normalizedPath,
                language: language,
                cursorLine: nil,
                cursorColumn: nil,
                nearbyLineRange: snippetRange(aroundLine: 1, in: content),
                nearbySnippet: snippet(aroundLine: 1, in: content),
                isDirty: isDirty,
                observedAt: observedAt
            )
        }

        bumpUpdatedAt(observedAt)
    }

    func noteSelection(
        path: String,
        content: String,
        selection: NSRange,
        language: String?,
        isDirty: Bool,
        observedAt: Date = Date(),
        openFiles: [OpenFileContext] = []
    ) {
        guard let normalizedPath = normalize(path) else { return }

        notePresentedFile(
            path: normalizedPath,
            language: language,
            isDirty: isDirty,
            content: content,
            observedAt: observedAt,
            openFiles: openFiles
        )

        let cursorLocation = min(selection.location, (content as NSString).length)
        let cursor = lineColumn(atUTF16Offset: cursorLocation, in: content)
        currentFile = CurrentFileContext(
            path: normalizedPath,
            language: language,
            cursorLine: cursor.line,
            cursorColumn: cursor.column,
            nearbyLineRange: snippetRange(aroundLine: cursor.line, in: content),
            nearbySnippet: snippet(aroundLine: cursor.line, in: content),
            isDirty: isDirty,
            observedAt: observedAt
        )

        if selection.length > 0,
           let selectedText = substring(in: content, range: selection) {
            let start = lineColumn(atUTF16Offset: selection.location, in: content)
            let end = lineColumn(atUTF16Offset: selection.location + selection.length, in: content)
            let truncatedText = String(selectedText.prefix(4_000))
            selectedRange = SelectedRangeContext(
                path: normalizedPath,
                startLine: start.line,
                startColumn: start.column,
                endLine: end.line,
                endColumn: end.column,
                selectedText: truncatedText,
                isTruncated: selectedText.count > truncatedText.count,
                observedAt: observedAt
            )
        } else {
            selectedRange = nil
        }

        bumpUpdatedAt(observedAt)
    }

    func clearSelection(observedAt: Date = Date()) {
        selectedRange = nil
        bumpUpdatedAt(observedAt)
    }

    func noteOpenFiles(_ files: [OpenFileContext], observedAt: Date = Date()) {
        openFiles = OpenFilesContext(
            files: deduplicatedOpenFiles(files, currentPath: currentFile?.path),
            observedAt: observedAt
        )
        bumpUpdatedAt(observedAt)
    }

    func ingestExternalEditorContext(
        currentFile: CurrentFileContext?,
        selectedRange: SelectedRangeContext?,
        openFiles: [OpenFileContext],
        diagnostics: [EditorDiagnosticContext],
        observedAt: Date = Date()
    ) {
        if let currentFile, let normalized = normalize(currentFile.path) {
            self.currentFile = CurrentFileContext(
                path: normalized,
                language: currentFile.language,
                cursorLine: currentFile.cursorLine,
                cursorColumn: currentFile.cursorColumn,
                nearbyLineRange: currentFile.nearbyLineRange,
                nearbySnippet: currentFile.nearbySnippet,
                isDirty: currentFile.isDirty,
                observedAt: currentFile.observedAt
            )
        }

        if let selectedRange, let normalized = normalize(selectedRange.path) {
            self.selectedRange = SelectedRangeContext(
                path: normalized,
                startLine: selectedRange.startLine,
                startColumn: selectedRange.startColumn,
                endLine: selectedRange.endLine,
                endColumn: selectedRange.endColumn,
                selectedText: selectedRange.selectedText,
                isTruncated: selectedRange.isTruncated,
                observedAt: selectedRange.observedAt
            )
        }

        noteOpenFiles(openFiles, observedAt: observedAt)
        replaceDiagnostics(diagnostics, observedAt: observedAt)
        bumpUpdatedAt(observedAt)
    }

    func noteRecentWorkspaceEdits(_ paths: [String], source: String = "workspace", observedAt: Date = Date()) {
        let normalizedPaths = paths.compactMap(normalize)
        guard !normalizedPaths.isEmpty else { return }

        for path in normalizedPaths.reversed() {
            recentEdits.removeAll { $0.path == path }
            recentEdits.insert(
                RecentEditContext(path: path, changedLineRange: nil, timestamp: observedAt, source: source),
                at: 0
            )
        }

        if recentEdits.count > Self.maxRecentEdits {
            recentEdits = Array(recentEdits.prefix(Self.maxRecentEdits))
        }
        bumpUpdatedAt(observedAt)
    }

    func replaceDiagnostics(_ diagnostics: [EditorDiagnosticContext], observedAt: Date = Date()) {
        let normalized = diagnostics.compactMap { diagnostic -> EditorDiagnosticContext? in
            guard let path = normalize(diagnostic.path) else { return nil }
            return EditorDiagnosticContext(
                path: path,
                line: diagnostic.line,
                column: diagnostic.column,
                severity: diagnostic.severity,
                message: diagnostic.message,
                source: diagnostic.source,
                observedAt: diagnostic.observedAt
            )
        }
        self.diagnostics = DiagnosticsContext(items: Array(normalized.prefix(Self.maxDiagnostics)), observedAt: observedAt)
        bumpUpdatedAt(observedAt)
    }

    func replaceDiagnostics(from report: BuildReport, source: String, observedAt: Date = Date()) {
        let items = report.issues.compactMap { issue -> EditorDiagnosticContext? in
            guard let file = issue.file else { return nil }
            let severity: AmbientDiagnosticSeverity
            switch issue.severity {
            case .error: severity = .error
            case .warning: severity = .warning
            case .note: severity = .note
            }
            return EditorDiagnosticContext(
                path: file,
                line: issue.line,
                column: issue.column,
                severity: severity,
                message: issue.message,
                source: source,
                observedAt: observedAt
            )
        }
        replaceDiagnostics(items, observedAt: observedAt)
    }

    func noteGitState(_ state: GitRepositoryState, observedAt: Date = Date()) {
        let summary = GitChangeSummary(changes: state.changes)
        gitContext = GitContext(
            branchName: state.currentBranchName,
            aheadCount: state.aheadCount,
            behindCount: state.behindCount,
            stagedCount: summary.stagedCount,
            unstagedCount: summary.unstagedCount,
            conflictedCount: summary.conflictedCount,
            observedAt: observedAt
        )
        bumpUpdatedAt(observedAt)
    }

    func snapshot(
        for subsystem: AmbientContextSubsystem,
        influenceLevel: AmbientContextInfluenceLevel,
        now: Date = Date()
    ) -> AmbientEditorContext {
        baseSnapshot(now: now, influenceLevel: influenceLevel)
            .scoped(for: subsystem, influenceLevel: influenceLevel)
    }

    func executionSnapshot(now: Date = Date()) -> AmbientEditorContext {
        baseSnapshot(now: now, influenceLevel: .full)
    }

    private func baseSnapshot(
        now: Date,
        influenceLevel: AmbientContextInfluenceLevel
    ) -> AmbientEditorContext {
        let selectionIsFresh = selectedRange.map {
            now.timeIntervalSince($0.observedAt) <= AmbientEditorContext.selectionStalenessThreshold
        } ?? false
        let selectionFreshnessMs = selectedRange.map {
            max(0, Int(now.timeIntervalSince($0.observedAt) * 1_000.0))
        }

        return AmbientEditorContext(
            contextID: UUID(),
            capturedAt: now,
            lastUpdatedAt: lastUpdatedAt,
            influenceLevel: influenceLevel,
            selectionFreshnessMs: selectionFreshnessMs,
            currentFile: selectionIsFresh ? currentFile : currentFile?.withoutCursor(),
            selectedRange: selectionIsFresh ? selectedRange : nil,
            openFiles: openFiles,
            recentEdits: recentEdits,
            diagnostics: diagnostics,
            gitContext: gitContext,
            conflict: conflictState(capturedAt: now)
        )
    }

    private func conflictState(capturedAt: Date) -> AmbientContextConflict? {
        let selectionIsFresh = selectedRange.map { capturedAt.timeIntervalSince($0.observedAt) <= AmbientEditorContext.selectionStalenessThreshold } ?? false
        let diagnosticPaths = Set(diagnostics.items.map(\.path))
        let recentEditPaths = Set(recentEdits.map(\.path))

        if selectionIsFresh,
           let selectedRange,
           (diagnosticPaths.subtracting([selectedRange.path]).isEmpty == false
            || recentEditPaths.subtracting([selectedRange.path]).isEmpty == false) {
            let conflicts = Array(diagnosticPaths.union(recentEditPaths).subtracting([selectedRange.path])).sorted()
            return AmbientContextConflict(
                reason: .selectionOverridesOtherSignals,
                preferredSource: .selection,
                preferredPath: selectedRange.path,
                conflictingPaths: conflicts
            )
        }

        if !selectionIsFresh {
            let candidates = diagnosticPaths.union(recentEditPaths)
            if candidates.count > 1 {
                return AmbientContextConflict(
                    reason: .ambiguousNonSelectionSignals,
                    preferredSource: nil,
                    preferredPath: nil,
                    conflictingPaths: Array(candidates).sorted()
                )
            }
        }

        return nil
    }

    private func normalize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
                .appendingPathComponent(trimmed)
                .standardizedFileURL
        }
        let normalized = url.path
        guard normalized.hasPrefix(workspaceRoot) else { return nil }
        return normalized
    }

    private func deduplicatedOpenFiles(_ files: [OpenFileContext], currentPath: String?) -> [OpenFileContext] {
        var seen = Set<String>()
        var normalizedFiles: [OpenFileContext] = []

        if let currentPath, let currentFile {
            normalizedFiles.append(OpenFileContext(
                path: currentPath,
                language: currentFile.language,
                isDirty: currentFile.isDirty,
                lastFocusedAt: currentFile.observedAt
            ))
            seen.insert(currentPath)
        }

        for file in files {
            guard let normalizedPath = normalize(file.path) else { continue }
            guard seen.insert(normalizedPath).inserted else { continue }
            normalizedFiles.append(OpenFileContext(
                path: normalizedPath,
                language: file.language,
                isDirty: file.isDirty,
                lastFocusedAt: file.lastFocusedAt
            ))
        }

        return normalizedFiles
    }

    private func bumpUpdatedAt(_ observedAt: Date) {
        if let lastUpdatedAt {
            self.lastUpdatedAt = max(lastUpdatedAt, observedAt)
        } else {
            self.lastUpdatedAt = observedAt
        }
    }

    private func substring(in content: String, range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    private func lineColumn(atUTF16Offset offset: Int, in content: String) -> (line: Int, column: Int) {
        let ns = content as NSString
        let safeOffset = max(0, min(offset, ns.length))
        let prefix = ns.substring(to: safeOffset)
        let components = prefix.components(separatedBy: .newlines)
        let line = max(1, components.count)
        let column = (components.last?.count ?? 0) + 1
        return (line, column)
    }

    private func snippetRange(aroundLine line: Int, in content: String) -> ClosedRange<Int>? {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }
        let lower = max(1, line - 3)
        let upper = min(lines.count, line + 3)
        return lower...upper
    }

    private func snippet(aroundLine line: Int, in content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        guard let range = snippetRange(aroundLine: line, in: content) else { return nil }
        return lines[(range.lowerBound - 1)...(range.upperBound - 1)].joined(separator: "\n")
    }
}