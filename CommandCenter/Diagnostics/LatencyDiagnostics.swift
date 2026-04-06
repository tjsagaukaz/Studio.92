import Foundation

struct LatencyStageRecord: Codable {
    let index: Int
    let name: String
    let file: String
    let function: String
    let thread: String
    let startedMs: Double
    let endedMs: Double
    let durationMs: Double
    let notes: String?
}

struct LatencyPointRecord: Codable {
    let index: Int
    let name: String
    let file: String
    let function: String
    let thread: String
    let atMs: Double
    let notes: String?
}

struct LatencyLLMCallRecord: Codable {
    let index: Int
    let key: String
    let provider: String
    let model: String
    let iteration: Int
    let file: String
    let function: String
    let thread: String
    let startedMs: Double
    let endedMs: Double
    let totalMs: Double
    let requestTTFBMs: Double?
    let responseStartMs: Double?
    let responseEndMs: Double?
    let responseTransferMs: Double?
    let firstEventMs: Double?
    let firstEventType: String?
    let firstTextDeltaMs: Double?
    let firstVisibleTextMs: Double?
    let modelThinkBeforeFirstEventMs: Double?
    let modelThinkBeforeFirstTextMs: Double?
    let renderDelayAfterFirstTextMs: Double?
    let streamingDurationMs: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let stopReason: String?
    let notes: String?
}

struct LatencyToolLoopRecord: Codable {
    let index: Int
    let key: String
    let loopIndex: Int
    let action: String
    let file: String
    let function: String
    let thread: String
    let startedMs: Double
    let endedMs: Double
    let durationMs: Double
    let notes: String?
}

struct LatencyRunReport: Codable {
    let runID: String
    let goalPreview: String
    let startedAtISO8601: String
    let endedAtISO8601: String?
    let totalMs: Double?
    let metadata: [String: String]
    let stages: [LatencyStageRecord]
    let points: [LatencyPointRecord]
    let llmCalls: [LatencyLLMCallRecord]
    let toolLoops: [LatencyToolLoopRecord]
    let unknowns: [String]
}

actor LatencyDiagnostics {

    static let shared = LatencyDiagnostics()

    nonisolated static func makeRunID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private struct ActiveLLMCallState {
        let index: Int
        let key: String
        let provider: String
        let model: String
        let iteration: Int
        let file: String
        let function: String
        let thread: String
        let startedAt: CFAbsoluteTime
        let startedMs: Double
        let notes: String?
        var requestTTFBMs: Double?
        var responseStartMs: Double?
        var responseEndMs: Double?
        var responseTransferMs: Double?
        var firstEventMs: Double?
        var firstEventType: String?
        var firstTextDeltaMs: Double?
        var firstVisibleTextMs: Double?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    private struct RunState {
        let runID: String
        let goalPreview: String
        let startedAtAbsolute: CFAbsoluteTime
        let startedAtDate: Date
        var endedAtDate: Date?
        var totalMs: Double?
        let metadata: [String: String]
        var nextIndex: Int = 1
        var stages: [LatencyStageRecord] = []
        var points: [LatencyPointRecord] = []
        var llmCalls: [LatencyLLMCallRecord] = []
        var toolLoops: [LatencyToolLoopRecord] = []
        var activeLLMCalls: [String: ActiveLLMCallState] = [:]
        var unknowns: [String] = []
        var exportedReportURL: URL?
    }

    private var runs: [String: RunState] = [:]
    private var currentRunID: String?
    private var runOrder: [String] = []
    private static let maxRetainedRuns = 10
    private static let maxPointsPerRun = 2000
    private static let maxStagesPerRun = 500
    private static let maxLLMCallsPerRun = 200
    private static let maxToolLoopsPerRun = 500
    private static let maxUnknownsPerRun = 200

    func beginRun(
        id runID: String,
        goalPreview: String,
        triggeredAt: CFAbsoluteTime,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        isMainThread: Bool = Thread.isMainThread
    ) {
        if runs[runID] == nil {
            runs[runID] = RunState(
                runID: runID,
                goalPreview: goalPreview,
                startedAtAbsolute: triggeredAt,
                startedAtDate: Date(),
                metadata: metadata
            )
            runOrder.append(runID)
        }
        currentRunID = runID
        markPoint(
            runID: runID,
            name: "Run Started",
            at: triggeredAt,
            file: file,
            function: function,
            notes: trimmed("goal=\"\(goalPreview)\""),
            isMainThread: isMainThread
        )
    }

    func activeRunID() -> String? {
        currentRunID
    }

    func latestReportURL(for runID: String) -> URL? {
        runs[runID]?.exportedReportURL
    }

    func markPoint(
        runID: String?,
        name: String,
        at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        file: String = #fileID,
        function: String = #function,
        notes: String? = nil,
        isMainThread: Bool = Thread.isMainThread
    ) {
        guard let runID, var run = runs[runID] else { return }
        let point = LatencyPointRecord(
            index: run.nextIndex,
            name: name,
            file: file,
            function: function,
            thread: Self.threadLabel(isMainThread),
            atMs: Self.relativeMilliseconds(at, from: run.startedAtAbsolute),
            notes: trimmed(notes)
        )
        run.nextIndex += 1
        run.points.append(point)
        if run.points.count > Self.maxPointsPerRun {
            run.points.removeFirst(run.points.count - Self.maxPointsPerRun)
        }
        runs[runID] = run
        log(runID: runID, index: point.index, message: "POINT \(name) t=\(Self.formatMilliseconds(point.atMs)) thread=\(point.thread)\(Self.notesSuffix(point.notes))")
    }

    func recordStage(
        runID: String?,
        name: String,
        startedAt: CFAbsoluteTime,
        endedAt: CFAbsoluteTime,
        file: String = #fileID,
        function: String = #function,
        notes: String? = nil,
        isMainThread: Bool = Thread.isMainThread
    ) {
        guard let runID, var run = runs[runID] else { return }
        let startMs = Self.relativeMilliseconds(startedAt, from: run.startedAtAbsolute)
        let endMs = Self.relativeMilliseconds(endedAt, from: run.startedAtAbsolute)
        let stage = LatencyStageRecord(
            index: run.nextIndex,
            name: name,
            file: file,
            function: function,
            thread: Self.threadLabel(isMainThread),
            startedMs: startMs,
            endedMs: endMs,
            durationMs: max(0, endMs - startMs),
            notes: trimmed(notes)
        )
        run.nextIndex += 1
        run.stages.append(stage)
        if run.stages.count > Self.maxStagesPerRun {
            run.stages.removeFirst(run.stages.count - Self.maxStagesPerRun)
        }
        runs[runID] = run
        log(
            runID: runID,
            index: stage.index,
            message: "STAGE \(name) start=\(Self.formatMilliseconds(stage.startedMs)) end=\(Self.formatMilliseconds(stage.endedMs)) duration=\(Self.formatMilliseconds(stage.durationMs)) thread=\(stage.thread)\(Self.notesSuffix(stage.notes))"
        )
    }

    func beginLLMCall(
        runID: String?,
        key: String,
        provider: String,
        model: String,
        iteration: Int,
        startedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        file: String = #fileID,
        function: String = #function,
        notes: String? = nil,
        isMainThread: Bool = Thread.isMainThread
    ) {
        guard let runID, var run = runs[runID] else { return }
        let state = ActiveLLMCallState(
            index: run.nextIndex,
            key: key,
            provider: provider,
            model: model,
            iteration: iteration,
            file: file,
            function: function,
            thread: Self.threadLabel(isMainThread),
            startedAt: startedAt,
            startedMs: Self.relativeMilliseconds(startedAt, from: run.startedAtAbsolute),
            notes: trimmed(notes)
        )
        run.nextIndex += 1
        run.activeLLMCalls[key] = state
        runs[runID] = run
        log(
            runID: runID,
            index: state.index,
            message: "LLM BEGIN key=\(key) provider=\(provider) model=\(model) iteration=\(iteration) start=\(Self.formatMilliseconds(state.startedMs)) thread=\(state.thread)\(Self.notesSuffix(state.notes))"
        )
    }

    func markLLMHeaders(
        runID: String?,
        key: String,
        at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        let relativeMs = Self.relativeMilliseconds(at, from: run.startedAtAbsolute)
        if state.responseStartMs == nil {
            state.responseStartMs = relativeMs
        }
        run.activeLLMCalls[key] = state
        runs[runID] = run
        log(runID: runID, index: state.index, message: "LLM HEADERS key=\(key) at=\(Self.formatMilliseconds(relativeMs))")
    }

    func markLLMFirstEvent(
        runID: String?,
        key: String,
        eventType: String,
        at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        let relativeMs = Self.relativeMilliseconds(at, from: run.startedAtAbsolute)
        if state.firstEventMs == nil {
            state.firstEventMs = relativeMs
            state.firstEventType = eventType
            run.activeLLMCalls[key] = state
            runs[runID] = run
            log(runID: runID, index: state.index, message: "LLM FIRST_EVENT key=\(key) type=\(eventType) at=\(Self.formatMilliseconds(relativeMs))")
        }
    }

    func markLLMFirstTextDelta(
        runID: String?,
        key: String,
        at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        let relativeMs = Self.relativeMilliseconds(at, from: run.startedAtAbsolute)
        if state.firstTextDeltaMs == nil {
            state.firstTextDeltaMs = relativeMs
            run.activeLLMCalls[key] = state
            runs[runID] = run
            log(runID: runID, index: state.index, message: "LLM FIRST_TEXT_DELTA key=\(key) at=\(Self.formatMilliseconds(relativeMs))")
        }
    }

    func markLLMFirstVisibleText(
        runID: String?,
        key: String,
        at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        let relativeMs = Self.relativeMilliseconds(at, from: run.startedAtAbsolute)
        if state.firstVisibleTextMs == nil {
            state.firstVisibleTextMs = relativeMs
            run.activeLLMCalls[key] = state
            runs[runID] = run
            log(runID: runID, index: state.index, message: "LLM FIRST_VISIBLE_TEXT key=\(key) at=\(Self.formatMilliseconds(relativeMs))")
        }
    }

    func updateLLMUsage(
        runID: String?,
        key: String,
        inputTokens: Int?,
        outputTokens: Int?
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        if let inputTokens {
            state.inputTokens = (state.inputTokens ?? 0) + inputTokens
        }
        if let outputTokens {
            state.outputTokens = (state.outputTokens ?? 0) + outputTokens
        }
        run.activeLLMCalls[key] = state
        runs[runID] = run
    }

    func attachLLMNetworkMetrics(
        runID: String?,
        key: String,
        requestTTFBMs: Double?,
        responseStartAt: CFAbsoluteTime?,
        responseEndAt: CFAbsoluteTime?,
        responseTransferMs: Double?
    ) {
        guard let runID, var run = runs[runID], var state = run.activeLLMCalls[key] else { return }
        if let requestTTFBMs {
            state.requestTTFBMs = requestTTFBMs
        }
        if let responseStartAt {
            state.responseStartMs = Self.relativeMilliseconds(responseStartAt, from: run.startedAtAbsolute)
        }
        if let responseEndAt {
            state.responseEndMs = Self.relativeMilliseconds(responseEndAt, from: run.startedAtAbsolute)
        }
        if let responseTransferMs {
            state.responseTransferMs = responseTransferMs
        }
        run.activeLLMCalls[key] = state
        runs[runID] = run
    }

    func endLLMCall(
        runID: String?,
        key: String,
        endedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        stopReason: String?,
        notes: String? = nil
    ) {
        guard let runID, var run = runs[runID], let state = run.activeLLMCalls.removeValue(forKey: key) else { return }
        let endedMs = Self.relativeMilliseconds(endedAt, from: run.startedAtAbsolute)
        let record = LatencyLLMCallRecord(
            index: state.index,
            key: state.key,
            provider: state.provider,
            model: state.model,
            iteration: state.iteration,
            file: state.file,
            function: state.function,
            thread: state.thread,
            startedMs: state.startedMs,
            endedMs: endedMs,
            totalMs: max(0, endedMs - state.startedMs),
            requestTTFBMs: state.requestTTFBMs,
            responseStartMs: state.responseStartMs,
            responseEndMs: state.responseEndMs,
            responseTransferMs: state.responseTransferMs,
            firstEventMs: state.firstEventMs,
            firstEventType: state.firstEventType,
            firstTextDeltaMs: state.firstTextDeltaMs,
            firstVisibleTextMs: state.firstVisibleTextMs,
            modelThinkBeforeFirstEventMs: Self.delta(from: state.responseStartMs, to: state.firstEventMs),
            modelThinkBeforeFirstTextMs: Self.delta(from: state.responseStartMs, to: state.firstTextDeltaMs),
            renderDelayAfterFirstTextMs: Self.delta(from: state.firstTextDeltaMs, to: state.firstVisibleTextMs),
            streamingDurationMs: Self.delta(from: state.firstTextDeltaMs, to: endedMs),
            inputTokens: state.inputTokens,
            outputTokens: state.outputTokens,
            stopReason: stopReason,
            notes: trimmed(notes ?? state.notes)
        )
        run.llmCalls.append(record)
        if run.llmCalls.count > Self.maxLLMCallsPerRun {
            run.llmCalls.removeFirst(run.llmCalls.count - Self.maxLLMCallsPerRun)
        }
        runs[runID] = run
        log(
            runID: runID,
            index: record.index,
            message: "LLM END key=\(key) total=\(Self.formatMilliseconds(record.totalMs)) ttfb=\(Self.optionalMilliseconds(record.requestTTFBMs)) first_event=\(Self.optionalMilliseconds(record.firstEventMs)) first_text=\(Self.optionalMilliseconds(record.firstTextDeltaMs)) first_visible=\(Self.optionalMilliseconds(record.firstVisibleTextMs)) stream=\(Self.optionalMilliseconds(record.streamingDurationMs)) stop=\(stopReason ?? "-") input_tokens=\(record.inputTokens.map(String.init) ?? "-") output_tokens=\(record.outputTokens.map(String.init) ?? "-")\(Self.notesSuffix(record.notes))"
        )
    }

    func recordToolLoop(
        runID: String?,
        key: String,
        loopIndex: Int,
        action: String,
        startedAt: CFAbsoluteTime,
        endedAt: CFAbsoluteTime,
        file: String = #fileID,
        function: String = #function,
        notes: String? = nil,
        isMainThread: Bool = Thread.isMainThread
    ) {
        guard let runID, var run = runs[runID] else { return }
        let startedMs = Self.relativeMilliseconds(startedAt, from: run.startedAtAbsolute)
        let endedMs = Self.relativeMilliseconds(endedAt, from: run.startedAtAbsolute)
        let record = LatencyToolLoopRecord(
            index: run.nextIndex,
            key: key,
            loopIndex: loopIndex,
            action: action,
            file: file,
            function: function,
            thread: Self.threadLabel(isMainThread),
            startedMs: startedMs,
            endedMs: endedMs,
            durationMs: max(0, endedMs - startedMs),
            notes: trimmed(notes)
        )
        run.nextIndex += 1
        run.toolLoops.append(record)
        if run.toolLoops.count > Self.maxToolLoopsPerRun {
            run.toolLoops.removeFirst(run.toolLoops.count - Self.maxToolLoopsPerRun)
        }
        runs[runID] = run
        log(
            runID: runID,
            index: record.index,
            message: "TOOL LOOP loop=\(loopIndex) action=\(action) start=\(Self.formatMilliseconds(startedMs)) end=\(Self.formatMilliseconds(endedMs)) duration=\(Self.formatMilliseconds(record.durationMs)) thread=\(record.thread)\(Self.notesSuffix(record.notes))"
        )
    }

    func addUnknown(
        runID: String?,
        message: String
    ) {
        guard let runID, var run = runs[runID] else { return }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        if !run.unknowns.contains(trimmedMessage) {
            run.unknowns.append(trimmedMessage)
            if run.unknowns.count > Self.maxUnknownsPerRun {
                run.unknowns.removeFirst(run.unknowns.count - Self.maxUnknownsPerRun)
            }
            runs[runID] = run
            log(runID: runID, index: run.nextIndex, message: "UNKNOWN \(trimmedMessage)")
        }
    }

    func finishRun(
        runID: String?,
        endedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        outcome: String,
        notes: String? = nil
    ) {
        guard let runID, var run = runs[runID] else { return }
        run.totalMs = Self.relativeMilliseconds(endedAt, from: run.startedAtAbsolute)
        run.endedAtDate = Date()
        runs[runID] = run
        markPoint(runID: runID, name: "Run Finished", at: endedAt, notes: trimmed("outcome=\(outcome) \(notes ?? "")"))
        export(runID: runID)
        log(
            runID: runID,
            index: 0,
            message: "SUMMARY total=\(Self.optionalMilliseconds(run.totalMs)) stages=\(run.stages.count) llm_calls=\(run.llmCalls.count) tool_loops=\(run.toolLoops.count) unknowns=\(run.unknowns.count)"
        )
        evictOldRuns()
    }

    private func export(runID: String) {
        guard var run = runs[runID] else { return }
        let report = LatencyRunReport(
            runID: run.runID,
            goalPreview: run.goalPreview,
            startedAtISO8601: Self.iso8601(run.startedAtDate),
            endedAtISO8601: run.endedAtDate.map(Self.iso8601),
            totalMs: run.totalMs,
            metadata: run.metadata,
            stages: run.stages.sorted(by: { $0.index < $1.index }),
            points: run.points.sorted(by: { $0.index < $1.index }),
            llmCalls: run.llmCalls.sorted(by: { $0.index < $1.index }),
            toolLoops: run.toolLoops.sorted(by: { $0.index < $1.index }),
            unknowns: run.unknowns
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let reportDir = cacheDir.appendingPathComponent("com.studio92.latency", isDirectory: true)
            try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
            let url = reportDir.appendingPathComponent("studio92-latency-\(runID).json")
            try data.write(to: url, options: .atomic)
            run.exportedReportURL = url
            runs[runID] = run
            log(runID: runID, index: 0, message: "REPORT \(url.path)")
        } catch {
            log(runID: runID, index: 0, message: "REPORT_FAILED \(error.localizedDescription)")
        }
    }

    private func evictOldRuns() {
        while runOrder.count > Self.maxRetainedRuns {
            let evictedID = runOrder.removeFirst()
            runs.removeValue(forKey: evictedID)
        }
    }

    private func log(runID: String, index: Int, message: String) {
        let prefix = index > 0 ? "[Latency][Run \(runID)][\(String(format: "%03d", index))]" : "[Latency][Run \(runID)]"
        print("\(prefix) \(message)")
    }

    private static func relativeMilliseconds(_ absolute: CFAbsoluteTime, from start: CFAbsoluteTime) -> Double {
        (absolute - start) * 1000
    }

    private static func delta(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }

    private static func threadLabel(_ isMainThread: Bool) -> String {
        isMainThread ? "main" : "background"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    private static func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return formatMilliseconds(value)
    }

    private static func notesSuffix(_ notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return "" }
        return " notes=\"\(notes)\""
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }

    // MARK: - Percentile Computation

    /// Percentile distribution for a set of latency measurements.
    struct PercentileDistribution: Sendable {
        let label: String
        let count: Int
        let p50: Double
        let p95: Double
        let p99: Double
        let min: Double
        let max: Double

        static func from(label: String, values: [Double]) -> PercentileDistribution? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return PercentileDistribution(
                label: label,
                count: sorted.count,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                p99: percentile(sorted, 0.99),
                min: sorted.first!,
                max: sorted.last!
            )
        }

        private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
            guard sorted.count > 1 else { return sorted[0] }
            let index = p * Double(sorted.count - 1)
            let lower = Int(index)
            let upper = Swift.min(lower + 1, sorted.count - 1)
            let fraction = index - Double(lower)
            return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
        }
    }

    /// Compute percentile distributions for the given run.
    func percentiles(for runID: String) -> LatencyPercentileReport? {
        guard let run = runs[runID] else { return nil }

        let llmTotals = run.llmCalls.map(\.totalMs)
        let ttfbValues = run.llmCalls.compactMap(\.requestTTFBMs)
        let firstTextValues = run.llmCalls.compactMap(\.firstTextDeltaMs).map { ms in
            // firstTextDeltaMs is relative to run start — convert to per-call by diff from start
            ms
        }
        let toolDurations = run.toolLoops.map(\.durationMs)
        let stageDurations = run.stages.map(\.durationMs)

        // Per-call time-to-first-text: compute from each LLM call's own start
        let perCallTTFT: [Double] = run.llmCalls.compactMap { call in
            guard let firstText = call.firstTextDeltaMs else { return nil }
            return firstText - call.startedMs
        }

        return LatencyPercentileReport(
            runID: runID,
            llmTotal: PercentileDistribution.from(label: "LLM Total", values: llmTotals),
            llmTTFB: PercentileDistribution.from(label: "LLM TTFB", values: ttfbValues),
            llmTimeToFirstText: PercentileDistribution.from(label: "Time to First Text", values: perCallTTFT),
            toolDuration: PercentileDistribution.from(label: "Tool Duration", values: toolDurations),
            stageDuration: PercentileDistribution.from(label: "Stage Duration", values: stageDurations)
        )
    }
}

// MARK: - Percentile Report

struct LatencyPercentileReport: Sendable {
    let runID: String
    let llmTotal: LatencyDiagnostics.PercentileDistribution?
    let llmTTFB: LatencyDiagnostics.PercentileDistribution?
    let llmTimeToFirstText: LatencyDiagnostics.PercentileDistribution?
    let toolDuration: LatencyDiagnostics.PercentileDistribution?
    let stageDuration: LatencyDiagnostics.PercentileDistribution?

    /// All non-nil distributions for display.
    var distributions: [LatencyDiagnostics.PercentileDistribution] {
        [llmTotal, llmTTFB, llmTimeToFirstText, toolDuration, stageDuration].compactMap { $0 }
    }
}
