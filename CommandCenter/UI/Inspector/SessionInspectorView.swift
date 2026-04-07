// SessionInspectorView.swift
// Studio.92 — Command Center
// Glass Engine: interactive trace timeline for agent session inspection.
// Anchored as a bottom sheet inside ExecutionPaneView.

import SwiftUI
import AgentCouncil

// MARK: - Session Inspector View

struct SessionInspectorView: View {

    @Bindable var model: SessionInspectorModel
    let traceHistory: [TraceSummary]
    let onRerun: ((_ spanID: UUID, _ inputPayload: Data, _ elevateToReview: Bool) -> Void)?
    let onDismiss: () -> Void
    var latencyRunID: String? = nil

    @State private var isSessionPickerExpanded = false
    @State private var percentileReport: LatencyPercentileReport?

    var body: some View {
        VStack(spacing: 0) {
            inspectorHandle
            sessionPickerBar
            if let summary = model.summary {
                summaryStrip(summary)
            }
            if let report = percentileReport, !report.distributions.isEmpty {
                percentileStrip(report)
            }
            spanTimeline
        }
        .task(id: latencyRunID) {
            guard let runID = latencyRunID else {
                percentileReport = nil
                return
            }
            percentileReport = await LatencyDiagnostics.shared.percentiles(for: runID)
        }
        .background(StudioSurfaceElevated.level2)
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .strokeBorder(StudioSeparator.subtle, lineWidth: 0.5)
        )
    }

    // MARK: - Handle

    private var inspectorHandle: some View {
        HStack {
            Capsule()
                .fill(StudioTextColor.tertiary.opacity(0.4))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StudioMotion.standardSpring) {
                onDismiss()
            }
        }
    }

    // MARK: - Session Picker

    private var sessionPickerBar: some View {
        HStack(spacing: StudioSpacing.md) {
            Image(systemName: "timeline.selection")
                .font(StudioTypography.captionMedium)
                .foregroundStyle(StudioTextColor.secondary)

            Text("Session Log")
                .font(StudioTypography.codeSmallMedium)
                .foregroundStyle(StudioTextColor.primary)

            Spacer()

            // Source picker
            Menu {
                Button {
                    model.source = .live
                } label: {
                    Label("Live", systemImage: "antenna.radiowaves.left.and.right")
                }

                if !traceHistory.isEmpty {
                    Divider()
                    ForEach(traceHistory.indices.reversed(), id: \.self) { idx in
                        let summary = traceHistory[idx]
                        Button {
                            // Historical sessions need persisted spans loaded externally.
                            model.source = .historical(traceID: summary.traceID)
                        } label: {
                            Label(
                                "Session \(idx + 1) — \(summary.spanCount) spans",
                                systemImage: "clock"
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: StudioSpacing.xs) {
                    if model.isLive {
                        Circle()
                            .fill(StudioStatusColor.success)
                            .frame(width: 6, height: 6)
                        Text("Live")
                            .font(StudioTypography.dataMicro)
                            .foregroundStyle(StudioStatusColor.success)
                    } else {
                        Image(systemName: "clock")
                            .font(StudioTypography.micro)
                            .foregroundStyle(StudioTextColor.secondary)
                        Text("Historical")
                            .font(StudioTypography.dataMicro)
                            .foregroundStyle(StudioTextColor.secondary)
                    }
                }
                .padding(.horizontal, StudioSpacing.md)
                .padding(.vertical, StudioSpacing.xs)
                .background(StudioSurfaceGrouped.primary.opacity(0.6))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                copyEntireLog()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .buttonStyle(.plain)
            .help("Copy entire log")

            Button {
                withAnimation(StudioMotion.standardSpring) { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, StudioSpacing.section)
        .padding(.bottom, StudioSpacing.md)
    }

    // MARK: - Copy All Log

    private func copyEntireLog() {
        let nodes = model.timelineNodes
        guard !nodes.isEmpty else { return }

        var lines: [String] = []
        if let summary = model.summary {
            lines.append("Session Log")
            lines.append("Spans: \(summary.spanCount)  LLM: \(summary.llmCallCount)  Tools: \(summary.toolExecutionCount)  Errors: \(summary.errorCount)")
            if summary.totalDurationSeconds > 0 {
                lines.append("Duration: \(formatDuration(summary.totalDurationSeconds))")
            }
            if let contextID = summary.ambientContextID {
                lines.append("Ambient Context: \(contextID)")
            }
            if let freshnessMs = summary.ambientSelectionFreshnessMs {
                lines.append("Selection Freshness: \(freshnessMs)ms")
            }
            if let currentFile = summary.ambientCurrentFile {
                lines.append("Ambient File: \(currentFile)")
            }
            lines.append("")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for entry in nodes {
            let indent = String(repeating: "  ", count: entry.depth)
            var line = "\(indent)[\(formatter.string(from: entry.span.startedAt))] \(entry.span.kind): \(entry.span.displayName)"
            if let duration = entry.span.durationSeconds {
                line += " (\(formatDuration(duration)))"
            }
            if entry.span.isError, let msg = entry.span.statusText {
                line += " ERROR: \(msg)"
            }
            lines.append(line)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Percentile Strip

    private func percentileStrip(_ report: LatencyPercentileReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudioSpacing.xl) {
                ForEach(report.distributions, id: \.label) { dist in
                    VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                        Text(dist.label)
                            .font(StudioTypography.badgeSmall)
                            .foregroundStyle(StudioTextColor.tertiary)
                        HStack(spacing: StudioSpacing.lg) {
                            percentileValue("P50", dist.p50)
                            percentileValue("P95", dist.p95)
                            percentileValue("P99", dist.p99)
                        }
                    }
                }
            }
            .padding(.horizontal, StudioSpacing.section)
            .padding(.vertical, StudioSpacing.xs)
        }
        .background(StudioSurfaceGrouped.primary.opacity(0.3))
    }

    private func percentileValue(_ label: String, _ ms: Double) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(StudioTypography.badgeSmall)
                .foregroundStyle(StudioTextColor.tertiary)
            Text(formatMilliseconds(ms))
                .font(StudioTypography.codeSmallMedium)
                .foregroundStyle(percentileColor(ms))
        }
    }

    private func percentileColor(_ ms: Double) -> Color {
        if ms < 500 { return StudioStatusColor.success }
        if ms < 2000 { return StudioStatusColor.warning }
        return StudioStatusColor.danger
    }

    private func formatMilliseconds(_ ms: Double) -> String {
        if ms < 1000 {
            return "\(Int(ms))ms"
        } else {
            return String(format: "%.1fs", ms / 1000)
        }
    }

    // MARK: - Summary Strip

    private func summaryStrip(_ summary: InspectorSummary) -> some View {
        HStack(spacing: StudioSpacing.section) {
            summaryPill(
                label: "Spans",
                value: "\(summary.spanCount)",
                color: StudioTextColor.secondary
            )
            summaryPill(
                label: "LLM",
                value: "\(summary.llmCallCount)",
                color: StudioAccentColor.muted
            )
            summaryPill(
                label: "Tools",
                value: "\(summary.toolExecutionCount)",
                color: StudioTextColor.secondary
            )
            if summary.errorCount > 0 {
                summaryPill(
                    label: "Errors",
                    value: "\(summary.errorCount)",
                    color: StudioStatusColor.danger
                )
            }
            if let contextID = summary.ambientContextID {
                summaryPill(
                    label: "Context",
                    value: compactContextID(contextID),
                    color: StudioTextColor.secondary
                )
            }
            if let freshnessMs = summary.ambientSelectionFreshnessMs {
                summaryPill(
                    label: "Selection",
                    value: "\(freshnessMs)ms",
                    color: freshnessMs <= 30_000 ? StudioStatusColor.success : StudioTextColor.tertiary
                )
            }
            Spacer()
            if let currentFile = summary.ambientCurrentFile {
                Text(displayAmbientFile(currentFile))
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioTextColor.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if summary.totalDurationSeconds > 0 {
                Text(formatDuration(summary.totalDurationSeconds))
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            if summary.inputTokens + summary.outputTokens > 0 {
                Text("\(formatTokenCount(summary.inputTokens))↑ \(formatTokenCount(summary.outputTokens))↓")
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
        }
        .padding(.horizontal, StudioSpacing.section)
        .padding(.vertical, StudioSpacing.sm)
        .background(StudioSurfaceGrouped.primary.opacity(0.4))
    }

    private func summaryPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: StudioSpacing.xxsPlus) {
            Text(value)
                .font(StudioTypography.codeSmallMedium)
                .foregroundStyle(color)
            Text(label)
                .font(StudioTypography.badgeSmall)
                .foregroundStyle(StudioTextColor.tertiary)
        }
    }

    // MARK: - Span Timeline

    private var spanTimeline: some View {
        let nodes = model.timelineNodes
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if nodes.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(nodes.enumerated()), id: \.element.span.id) { _, entry in
                            SpanTimelineRow(
                                span: entry.span,
                                depth: entry.depth,
                                isExpanded: model.isExpanded(entry.span.id),
                                isFocused: model.focusedSpanID == entry.span.id,
                                hasChildren: model.spans.contains(where: { $0.parentID == entry.span.id }),
                                onToggle: { model.toggleExpanded(entry.span.id) },
                                onRerun: onRerun
                            )
                            .id(entry.span.id)
                        }
                    }
                }
                .padding(.vertical, StudioSpacing.md)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.focusedSpanID) { _, newValue in
                guard let newValue else { return }
                withAnimation(StudioMotion.standardSpring) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: StudioSpacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .font(StudioTypography.largeTitle)
                    .foregroundStyle(StudioTextColor.tertiary)
                Text(model.isLive ? "Waiting for spans…" : "No spans recorded")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .padding(.vertical, StudioSpacing.pagePad)
            Spacer()
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private func compactContextID(_ contextID: String) -> String {
        guard contextID.count > 12 else { return contextID }
        let prefix = contextID.prefix(8)
        let suffix = contextID.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private func displayAmbientFile(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Span Timeline Row

private struct SpanTimelineRow: View {

    let span: InspectorSpan
    let depth: Int
    let isExpanded: Bool
    let isFocused: Bool
    let hasChildren: Bool
    let onToggle: () -> Void
    let onRerun: ((_ spanID: UUID, _ inputPayload: Data, _ elevateToReview: Bool) -> Void)?

    @State private var isDetailExpanded = false
    @State private var showCopied = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 0) {
                // Indentation + timeline connector
                timelineConnector

                // Expand/collapse chevron for children
                if hasChildren {
                    Button {
                        withAnimation(StudioMotion.fastSpring) { onToggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(StudioTypography.badge)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }

                // Timestamp
                Text(Self.timestampFormatter.string(from: span.startedAt))
                    .font(StudioTypography.badgeSmallMono)
                    .foregroundStyle(StudioTextColor.tertiary.opacity(0.7))
                    .padding(.trailing, StudioSpacing.sm)

                // Kind icon
                Image(systemName: span.kindSymbol)
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(kindColor)
                    .frame(width: 16)

                // Name
                Text(span.displayName)
                    .font(StudioTypography.codeSmallMedium)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(1)
                    .padding(.leading, StudioSpacing.sm)

                // File path hint (from attributes)
                if let path = span.attributes["path"] ?? span.attributes["file"] {
                    Text(abbreviatePath(path))
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .lineLimit(1)
                        .padding(.leading, StudioSpacing.xs)
                }

                Spacer()

                // Copy button
                Button {
                    copySpanSummary()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(StudioTypography.badgeSmall)
                        .foregroundStyle(showCopied ? StudioStatusColor.success : StudioTextColor.tertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy span info")

                // TTFMO badge (tool spans only)
                if let ttfmo = span.ttfmoMs {
                    Text("⚡\(ttfmo)ms")
                        .font(StudioTypography.badgeSmallMono)
                        .foregroundStyle(ttfmo < 500 ? StudioStatusColor.success : StudioStatusColor.warning)
                        .padding(.horizontal, StudioSpacing.xs)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill((ttfmo < 500 ? StudioStatusColor.success : StudioStatusColor.warning).opacity(0.12))
                        )
                }

                // Duration
                if let duration = span.durationSeconds {
                    Text(formatDuration(duration))
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .padding(.trailing, StudioSpacing.sm)
                }

                // Status indicator
                statusDot
            }
            .padding(.vertical, 5)
            .padding(.horizontal, StudioSpacing.xl)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(StudioMotion.standardSpring) {
                    isDetailExpanded.toggle()
                }
            }
            .background(
                isFocused
                    ? StudioAccentColor.primary.opacity(0.12)
                    : isDetailExpanded
                    ? StudioSurfaceGrouped.primary.opacity(0.3)
                    : Color.clear
            )
            .contextMenu {
                Button("Copy Span Info") {
                    copySpanSummary()
                }
                if span.isError, let msg = span.statusText {
                    Button("Copy Error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg, forType: .string)
                    }
                }
                if let input = span.inputPayloadString {
                    Button("Copy Input Payload") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(input, forType: .string)
                    }
                }
                if let output = span.outputPayloadString {
                    Button("Copy Output Payload") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    }
                }
            }

            // Expanded detail card
            if isDetailExpanded {
                SpanDetailCard(span: span, onRerun: onRerun)
                    .padding(.leading, CGFloat(depth * 16) + 40)
                    .padding(.trailing, StudioSpacing.xl)
                    .padding(.bottom, StudioSpacing.md)
                    .transition(.studioCollapse)
            }
        }
        .onAppear {
            if isFocused {
                isDetailExpanded = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else { return }
            withAnimation(StudioMotion.standardSpring) {
                isDetailExpanded = true
            }
        }
    }

    // MARK: - Timeline Connector

    private var timelineConnector: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(StudioTextColor.tertiary.opacity(0.15))
                    .frame(width: 1)
                    .padding(.horizontal, 7)
            }
            // Node dot on the timeline
            Circle()
                .fill(kindColor.opacity(0.6))
                .frame(width: 5, height: 5)
        }
        .frame(width: CGFloat(depth * 16) + 8)
    }

    // MARK: - Status Dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
            .padding(.trailing, StudioSpacing.xs)
    }

    private var statusColor: Color {
        if span.isError { return StudioStatusColor.danger }
        if span.endedAt == nil { return StudioStatusColor.warning }
        if span.kind == "retry" { return StudioStatusColor.warning }
        return StudioStatusColor.success
    }

    private var kindColor: Color {
        switch span.kind {
        case "llmCall": return StudioAccentColor.muted
        case "toolExecution": return StudioTextColor.primary
        case "subagent": return StudioAccentColor.primary
        case "permissionCheck": return StudioStatusColor.warning
        case "retry": return StudioStatusColor.warning
        case "session": return StudioAccentColor.muted
        default: return StudioTextColor.secondary
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.01 {
            return "<10ms"
        } else if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        }
    }

    private func copySpanSummary() {
        var lines: [String] = []
        lines.append("[\(Self.timestampFormatter.string(from: span.startedAt))] \(span.kind): \(span.name)")
        if let duration = span.durationSeconds {
            lines.append("Duration: \(formatDuration(duration))")
        }
        if let ttfmo = span.ttfmoMs {
            lines.append("TTFMO: \(ttfmo)ms")
        }
        if let total = span.totalMs {
            lines.append("Total: \(total)ms")
        }
        if span.isError, let status = span.statusText {
            lines.append("Error: \(status)")
        }
        for (key, value) in span.attributes.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): \(value)")
        }
        if let input = span.inputPayloadString {
            lines.append("Input: \(input.prefix(500))")
        }
        if let output = span.outputPayloadString {
            lines.append("Output: \(output.prefix(500))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showCopied = false
        }
    }
}

// MARK: - Span Detail Card

private struct SpanDetailCard: View {

    let span: InspectorSpan
    let onRerun: ((_ spanID: UUID, _ inputPayload: Data, _ elevateToReview: Bool) -> Void)?

    @State private var showingRerunConfirm = false
    @State private var elevateToReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            // Attributes
            if !span.attributes.isEmpty {
                attributesSection
            }

            // Input payload
            if let input = span.inputPayloadString {
                payloadSection(title: "Input", content: input)
            }

            // Output payload
            if let output = span.outputPayloadString {
                payloadSection(title: "Output", content: output)
            }

            // Error message
            if span.isError, let errorMsg = span.statusText, errorMsg != "ok" {
                errorSection(errorMsg)
            }

            // Rerun button
            if span.isRerunnable {
                rerunSection
            }
        }
        .padding(StudioSpacing.lg)
        .background(StudioSurface.viewport.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .strokeBorder(StudioSeparator.subtle, lineWidth: 0.5)
        )
    }

    // MARK: - Sections

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
            sectionHeader("Attributes")
            ForEach(
                span.attributes.sorted(by: { $0.key < $1.key }),
                id: \.key
            ) { key, value in
                HStack(alignment: .top, spacing: StudioSpacing.sm) {
                    Text(key)
                        .font(StudioTypography.dataMicroSemibold)
                        .foregroundStyle(StudioColorTokens.Syntax.typeColor)
                    Text(value)
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private func payloadSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioColorTokens.Syntax.plainColor)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
    }

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(StudioTypography.micro)
                .foregroundStyle(StudioStatusColor.danger)
            Text(message)
                .font(StudioTypography.dataMicro)
                .foregroundStyle(StudioStatusColor.danger)
                .lineLimit(4)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(StudioTypography.badgeSmall)
                    .foregroundStyle(StudioStatusColor.danger.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Copy error")
        }
        .padding(StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStatusColor.dangerSurface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.sm, style: .continuous))
        .contextMenu {
            Button("Copy Error") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }

    private var rerunSection: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            Divider().opacity(0.3)

            HStack(spacing: StudioSpacing.lg) {
                Button {
                    if elevateToReview {
                        showingRerunConfirm = true
                    } else if let payload = span.inputPayload {
                        onRerun?(span.id, payload, false)
                    }
                } label: {
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(StudioTypography.microMedium)
                        Text("Rerun")
                            .font(StudioTypography.microSemibold)
                    }
                    .foregroundStyle(StudioAccentColor.primary)
                    .padding(.horizontal, StudioSpacing.lg)
                    .padding(.vertical, 5)
                    .background(StudioAccentColor.muted.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Toggle(isOn: $elevateToReview) {
                    Text("Promote to Review")
                        .font(StudioTypography.badgeSmall)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()
            }
        }
        .alert("Confirm Elevated Rerun", isPresented: $showingRerunConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Rerun in Review Mode") {
                if let payload = span.inputPayload {
                    onRerun?(span.id, payload, true)
                }
            }
        } message: {
            Text("This will re-execute the tool with Review permissions, allowing file writes that require your approval.")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(StudioTypography.badgeSmallMono)
            .foregroundStyle(StudioTextColor.tertiary)
            .tracking(1.2)
    }
}
