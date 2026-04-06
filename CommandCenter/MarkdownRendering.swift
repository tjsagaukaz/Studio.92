// MarkdownRendering.swift
// Studio.92 — Command Center

import SwiftUI
import AppKit

struct MessageTimestampLabel: View {

    let timestamp: Date

    var body: some View {
        Text(timestamp.formatted(date: .omitted, time: .shortened))
            .font(StudioTypography.monoDigitsSmall)
            .foregroundStyle(StudioTextColor.tertiary)
    }
}

struct ReferenceBadge: View {

    enum Style {
        case standard
        case tinted

        var fillColor: Color {
            switch self {
            case .standard:
                return StudioSurfaceElevated.level1
            case .tinted:
                return StudioSurfaceElevated.level2
            }
        }

        var strokeColor: Color {
            switch self {
            case .standard:
                return StudioSeparator.subtle
            case .tinted:
                return StudioSeparator.subtle
            }
        }
    }

    let title: String
    let systemImage: String
    var style: Style = .standard
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
        }
        .font(StudioTypography.footnote)
        .foregroundStyle(StudioTextColor.secondary)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(style.fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(style.strokeColor, lineWidth: 1)
        )
    }
}

struct MarkdownListItem: Identifiable {

    enum Marker {
        case unordered
        case ordered(Int)

        var labelText: String {
            switch self {
            case .unordered:
                return "\u{2022}"
            case .ordered(let number):
                return "\(number)."
            }
        }
    }

    let id: String
    let text: String
    let marker: Marker
    var children: [MarkdownListItem]
}

struct MarkdownListView: View {

    let items: [MarkdownListItem]
    var tone: MarkdownMessageContent.Tone = .body

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                    HStack(alignment: .top, spacing: StudioSpacing.lg) {
                        Text(item.marker.labelText)
                            .font(markerFont(for: item.marker))
                            .foregroundStyle(StudioTextColor.tertiary)
                            .frame(minWidth: 24, alignment: .trailing)

                        MarkdownInlineText(text: item.text, tone: tone)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !item.children.isEmpty {
                        MarkdownListView(items: item.children, tone: tone)
                            .padding(.leading, StudioSpacing.columnPad)
                    }
                }
            }
        }
    }

    private func markerFont(for marker: MarkdownListItem.Marker) -> Font {
        switch marker {
        case .unordered:
            return .system(size: tone == .meta ? StudioChatLayout.metaFontSize : StudioChatLayout.bodyFontSize, weight: .regular)
        case .ordered:
            return .system(size: tone == .meta ? StudioChatLayout.metaFontSize : StudioChatLayout.bodyFontSize, weight: .medium, design: .monospaced)
        }
    }
}

struct MarkdownTableView: View {

    let headers: [String]
    let rows: [[String]]
    var tone: MarkdownMessageContent.Tone = .body

    var body: some View {
        let columnCount = headers.count

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { colIndex, header in
                    MarkdownInlineText(text: header, tone: tone)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(StudioTextColor.primary)
                        .frame(maxWidth: .infinity, alignment: alignment(for: colIndex))
                        .padding(.horizontal, StudioSpacing.lg)
                        .padding(.vertical, StudioSpacing.md)
                }
            }
            .background(StudioSurfaceGrouped.secondary)

            // Divider
            Rectangle()
                .fill(StudioSeparator.subtle)
                .frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cellText = colIndex < row.count ? row[colIndex] : ""
                        MarkdownInlineText(text: cellText, tone: tone)
                            .frame(maxWidth: .infinity, alignment: alignment(for: colIndex))
                            .padding(.horizontal, StudioSpacing.lg)
                            .padding(.vertical, StudioSpacing.md)
                    }
                }

                if rowIndex < rows.count - 1 {
                    Rectangle()
                        .fill(StudioSeparator.subtle.opacity(0.5))
                        .frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioSurfaceGrouped.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fontSize: CGFloat {
        switch tone {
        case .meta:
            return StudioChatLayout.metaFontSize
        case .body, .assistant, .user:
            return StudioChatLayout.bodyFontSize
        }
    }

    private func alignment(for columnIndex: Int) -> Alignment {
        // First column left, rest leading
        columnIndex == 0 ? .leading : .leading
    }
}

struct MarkdownMessageContent: View, Equatable {

    enum Tone: Equatable {
        case body
        case assistant
        case user
        case meta
    }

    let text: String
    var isStreaming = false
    var isPipelineRunning = false
    var tone: Tone = .body

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                let isLeadParagraph = index == 0 && tone == .assistant
                switch block.kind {
                case .heading(let level, let value):
                    MarkdownInlineText(text: value, tone: tone)
                        .font(headingFont(for: level))
                        .foregroundStyle(StudioTextColor.primary)
                        .padding(.top, StudioChatLayout.headingTopSpacing)
                        .padding(.bottom, StudioChatLayout.headingBottomSpacing)
                case .paragraph(let value):
                    MarkdownInlineText(text: value, tone: tone)
                        .opacity(isLeadParagraph ? 1.0 : 0.97)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .list(let items):
                    MarkdownListView(items: items, tone: tone)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .checklist(let tasks):
                    if isStreaming || isPipelineRunning {
                        BlueprintCompactView(tasks: tasks, isPipelineRunning: isPipelineRunning)
                            .padding(.bottom, StudioChatLayout.messageInternalSpacing)
                    } else {
                        BlueprintCardView(tasks: tasks, isPipelineRunning: isPipelineRunning)
                            .padding(.bottom, StudioChatLayout.messageInternalSpacing)
                    }
                case .quote(let value):
                    HStack(alignment: .top, spacing: StudioSpacing.md) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(StudioAccentColor.muted.opacity(0.6))
                            .frame(width: 3)
                        MarkdownInlineText(text: value, tone: tone)
                            .foregroundStyle(StudioTextColor.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.adaptive(light: Color.black.opacity(0.025), dark: Color.white.opacity(0.03)))
                    )
                    .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .code(let language, let code, let targetHint):
                    CodeBlockCard(
                        language: language,
                        code: code,
                        targetHint: targetHint,
                        isStreaming: isStreaming
                    )
                    .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, tone: tone)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .thematicBreak:
                    Rectangle()
                        .fill(StudioSeparator.subtle)
                        .frame(height: 1)
                        .padding(.vertical, StudioChatLayout.paragraphSpacing)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(for level: Int) -> Font {
        switch tone {
        case .body, .assistant, .user:
            let size: CGFloat
            let weight: Font.Weight
            switch level {
            case 1:
                size = StudioChatLayout.h1FontSize
                weight = .bold
            case 2:
                size = StudioChatLayout.h2FontSize
                weight = .semibold
            case 3:
                size = StudioChatLayout.h3FontSize
                weight = .semibold
            default:
                size = StudioChatLayout.h4FontSize
                weight = .medium
            }
            return .system(size: size, weight: weight, design: .default)
        case .meta:
            return .system(size: StudioChatLayout.metaFontSize, weight: .semibold, design: .monospaced)
        }
    }
}

struct MarkdownInlineText: View {

    let text: String
    var tone: MarkdownMessageContent.Tone = .body

    var body: some View {
        if var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            let _ = Self.refineAttributes(&attributed, tone: tone)
            Text(attributed)
                .font(font)
                .tracking(StudioChatLayout.bodyLetterSpacing)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(font)
                .tracking(StudioChatLayout.bodyLetterSpacing)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Refine inline styles: bold → medium, inline code → monospaced with background,
    /// links → accent color.
    private static func refineAttributes(_ attributed: inout AttributedString, tone: MarkdownMessageContent.Tone) {
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    let size: CGFloat = tone == .meta ? StudioChatLayout.metaFontSize : StudioChatLayout.bodyFontSize - 1
                    attributed[run.range].font = .system(size: size, weight: .medium, design: .monospaced)
                    // Inline code: dark graphite pill on canvas, white-tinted pill in user bubble
                    let bg: Color = tone == .user
                        ? Color.white.opacity(0.12)
                        : Color(hex: "#1A1E24")
                    attributed[run.range].backgroundColor = bg
                    if tone != .user {
                        // Cool-tone icy text for inline code on canvas
                        attributed[run.range].foregroundColor = Color(hex: "#C8D0E0")
                    }
                } else if intent.contains(.stronglyEmphasized) {
                    attributed[run.range].font = .system(.body, weight: .bold)
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = StudioAccentColor.primary
            }
        }
    }

    private var font: Font {
        switch tone {
        case .body:
            return .system(size: StudioChatLayout.bodyFontSize, weight: .regular)
        case .assistant:
            return .system(size: StudioChatLayout.assistantFontSize, weight: .regular)
        case .user:
            return .system(size: StudioChatLayout.userFontSize, weight: .regular)
        case .meta:
            return .system(size: StudioChatLayout.metaFontSize, weight: .regular, design: .monospaced)
        }
    }

    private var foregroundStyle: Color {
        switch tone {
        case .body, .assistant:
            return StudioTextColor.primary
        case .user:
            return .white
        case .meta:
            return StudioTextColor.secondary
        }
    }

    private var lineSpacing: CGFloat {
        switch tone {
        case .body, .assistant, .user:
            return StudioChatLayout.bodyLineSpacing
        case .meta:
            return 4
        }
    }
}

// MARK: - Code Block Action Button

private struct CodeBlockActionButton: View {
    let icon: String
    let title: String
    let disabled: Bool
    var isAccent: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: icon)
                    .symbolEffect(.pulse, isActive: disabled && !isAccent)
                Text(title)
            }
            .padding(.horizontal, StudioSpacing.md)
            .padding(.vertical, StudioSpacing.xs)
            .foregroundStyle(
                isAccent
                    ? StudioAccentColor.primary
                    : (isHovered ? StudioAccentColor.primary : Color.white.opacity(0.65))
            )
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered && !isAccent ? StudioAccentColor.primary.opacity(0.10) : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isAccent
                            ? StudioAccentColor.primary.opacity(0.5)
                            : (isHovered ? StudioAccentColor.primary.opacity(0.35) : Color.white.opacity(0.12)),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: isHovered ? StudioAccentColor.primary.opacity(0.20) : .clear, radius: 6)
            .animation(StudioMotion.softFade, value: isHovered)
            .animation(StudioMotion.softFade, value: isAccent)
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
    }
}

struct CodeBlockCard: View {

    let language: String?
    let code: String
    let targetHint: String?
    let isStreaming: Bool

    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @Environment(\.viewportActionContext) private var viewportActions
    @State private var isPreparingDiff = false
    @State private var isApplyingToFile = false
    @State private var hasApplied = false
    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language?.isEmpty == false ? language!.lowercased() : "code")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.tertiary)
                if let resolvedTarget = resolvedTargetHint {
                    Text("·")
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.tertiary.opacity(0.4))
                    Text(resolvedTarget)
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                CodeBlockCopyButton(code: code, hasCopied: $hasCopied)
            }
            .padding(.horizontal, StudioChatLayout.codeBlockPadding)
            .padding(.top, StudioSpacing.lg)
            .padding(.bottom, StudioSpacing.sm)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedCode)
                    .font(StudioTypography.code)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, StudioChatLayout.codeBlockPadding)
                    .padding(.bottom, StudioChatLayout.codeBlockPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: StudioChatLayout.codeBlockRadius, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioChatLayout.codeBlockRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
                HStack(spacing: StudioSpacing.md) {
                    CodeBlockActionButton(
                        icon: viewDiffButtonIcon,
                        title: viewDiffButtonTitle,
                        disabled: isPreparingDiff || isApplyingToFile || isStreaming,
                        action: viewDiff
                    )

                    CodeBlockActionButton(
                        icon: applyButtonIcon,
                        title: applyButtonTitle,
                        disabled: isPreparingDiff || isApplyingToFile || isStreaming,
                        isAccent: hasApplied,
                        action: applyToFile
                    )
                    .animation(.snappy(duration: 0.24), value: applyButtonStateKey)
                }
                .font(StudioTypography.footnoteSemibold)
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.85))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .padding(StudioSpacing.lg)
            }
        }
        .onChange(of: applyStateSignature) { _, _ in
            withAnimation(.snappy(duration: 0.2)) {
                hasApplied = false
            }
        }
    }

    private var highlightedCode: AttributedString {
        CodeSyntaxHighlighter.highlight(code: code, language: language)
    }

    /// Cached package root — resolved once per process since it never changes at runtime.
    private static var _cachedPackageRoot: String?

    private var resolvedPackageRoot: String {
        if let cached = Self._cachedPackageRoot { return cached }

        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            Self._cachedPackageRoot = storedPackageRoot
            return storedPackageRoot
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                Self._cachedPackageRoot = url.path
                return url.path
            }
        }

        let fallback = FileManager.default.currentDirectoryPath
        Self._cachedPackageRoot = fallback
        return fallback
    }

    private var resolvedTargetHint: String? {
        CodeTargetResolver.extractTargetHint(explicitHint: targetHint, code: code)
    }

    private var viewDiffButtonTitle: String {
        isPreparingDiff ? "Loading Diff..." : "View Diff"
    }

    private var viewDiffButtonIcon: String {
        isPreparingDiff ? "clock.arrow.circlepath" : "arrow.left.and.right.square"
    }

    private var applyButtonTitle: String {
        if hasApplied {
            return "Applied"
        }
        if isApplyingToFile {
            return "Applying to File..."
        }
        if isStreaming {
            return "Streaming"
        }
        return "Apply to File"
    }

    private var applyButtonIcon: String {
        if hasApplied {
            return "checkmark.circle.fill"
        }
        if isApplyingToFile {
            return "square.and.arrow.down.fill"
        }
        if isStreaming {
            return "waveform"
        }
        return "square.and.arrow.down"
    }

    private var applyButtonForeground: Color {
        hasApplied ? StudioStatusColor.success : StudioTextColor.primary
    }

    private var applyButtonFill: Color {
        if hasApplied {
            return StudioStatusColor.successSurface
        }
        if isApplyingToFile {
            return StudioSurfaceGrouped.secondary
        }
        return Color.clear
    }

    private var applyButtonStroke: Color {
        if hasApplied {
            return Color.clear
        }
        return StudioSeparator.subtle
    }

    private var applyButtonStateKey: String {
        "\(applyButtonTitle)-\(applyButtonIcon)-\(hasApplied)-\(isApplyingToFile)-\(isStreaming)"
    }

    private var applyStateSignature: String {
        [language ?? "", targetHint ?? "", code].joined(separator: "|")
    }

    private func viewDiff() {
        guard !isPreparingDiff, !isApplyingToFile, !isStreaming else { return }
        isPreparingDiff = true
        viewportActions.showDiffPreview(
            ViewportDiffModel(title: "Diff Preview", state: .loading, canApply: false),
            nil
        )

        prepareDiffState { state in
            viewportActions.showDiffPreview(
                ViewportDiffModel(title: "Diff Preview", state: state),
                state.supportsApply ? acceptDiffWrite : nil
            )
            isPreparingDiff = false
        }
    }

    private func applyToFile() {
        guard !isPreparingDiff, !isApplyingToFile, !isStreaming else { return }
        isApplyingToFile = true

        prepareDiffState { state in
            switch state {
            case .ready(let session):
                writeDiff(session)
            case .archived(let diffText):
                viewportActions.showDiffPreview(
                    ViewportDiffModel(title: "Diff Preview", state: .archived(diffText), canApply: false),
                    nil
                )
                isApplyingToFile = false
            case .failed(let message):
                viewportActions.showDiffPreview(
                    ViewportDiffModel(title: "Diff Preview", state: .failed(message), canApply: false),
                    nil
                )
                isApplyingToFile = false
            case .idle, .loading:
                isApplyingToFile = false
            }
        }
    }

    private func prepareDiffState(_ completion: @escaping (CodeDiffPreviewState) -> Void) {
        let packageRoot = resolvedPackageRoot
        let code = self.code
        let targetHint = resolvedTargetHint

        Task {
            let state = await Task.detached(priority: .userInitiated) {
                CodeDiffPreviewState.prepare(
                    code: code,
                    targetHint: targetHint,
                    packageRoot: packageRoot
                )
            }.value

            await MainActor.run {
                completion(state)
            }
        }
    }

    private func acceptDiffWrite(_ session: CodeDiffSession) {
        guard !isApplyingToFile else { return }
        isApplyingToFile = true
        writeDiff(session)
    }

    private func writeDiff(_ session: CodeDiffSession) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CodeDiffWriter.write(session: session)
            }.value

            await MainActor.run {
                isApplyingToFile = false
                switch result {
                case .success:
                    withAnimation(.snappy(duration: 0.24)) {
                        hasApplied = true
                    }
                    viewportActions.showDiffPreview(
                        ViewportDiffModel(title: "Diff Preview", state: .ready(session), canApply: false),
                        nil
                    )
                    CodeApplyFeedback.performSuccess()
                case .failure(let error):
                    viewportActions.showDiffPreview(
                        ViewportDiffModel(title: "Diff Preview", state: .failed(error.localizedDescription), canApply: false),
                        nil
                    )
                }
            }
        }
    }
}

// MARK: - Code Block Copy Button

struct CodeBlockCopyButton: View {

    let code: String
    @Binding var hasCopied: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            withAnimation(StudioMotion.hoverEase) {
                hasCopied = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                await MainActor.run {
                    withAnimation(StudioMotion.hoverEase) {
                        hasCopied = false
                    }
                }
            }
        } label: {
            HStack(spacing: StudioSpacing.xs) {
                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(hasCopied ? "Copied" : "Copy")
                    .font(StudioTypography.captionMedium)
            }
            .foregroundStyle(hasCopied ? StudioStatusColor.success : StudioTextColor.tertiary)
            .padding(.horizontal, StudioSpacing.md)
            .padding(.vertical, StudioSpacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? StudioSurfaceElevated.level2 : Color.clear)
            )
            .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hoverEase, value: isHovering)
        .animation(StudioMotion.hoverEase, value: hasCopied)
    }
}

struct MarkdownBlock: Identifiable {

    private struct ListEntry {
        let indent: Int
        let marker: MarkdownListItem.Marker
        let text: String
    }

    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case checklist([BlueprintTask])
        case quote(String)
        case code(language: String?, content: String, targetHint: String?)
        case table(headers: [String], rows: [[String]])
        case thematicBreak
    }

    let id: String
    let kind: Kind

    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var codeBlockOrdinal = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let inferredTargetHint = inferredCodeTargetHint(
                    previousBlock: blocks.last,
                    previousLine: index > 1 ? lines[index - codeLines.count - 2] : nil,
                    codeLines: codeLines
                )
                let codeBlockID = "code-\(codeBlockOrdinal)"
                codeBlockOrdinal += 1
                blocks.append(
                    MarkdownBlock(
                        id: codeBlockID,
                        kind: .code(
                            language: language.isEmpty ? nil : language,
                            content: codeLines.joined(separator: "\n"),
                            targetHint: inferredTargetHint
                        )
                    )
                )
                continue
            }

            if let heading = headingBlock(from: trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if checklistItem(in: trimmed) != nil {
                var tasks: [BlueprintTask] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = checklistItem(in: current) else { break }
                    tasks.append(
                        BlueprintTask(
                            id: stableID(prefix: "task", content: "\(tasks.count)-\(item.title)"),
                            title: item.title,
                            isCompleted: item.isCompleted
                        )
                    )
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        id: stableID(
                            prefix: "checklist",
                            content: tasks.map { "\($0.title)|\($0.isCompleted)" }.joined(separator: "|")
                        ),
                        kind: .checklist(tasks)
                    )
                )
                continue
            }

            if listEntry(in: line) != nil {
                var entries: [ListEntry] = []
                while index < lines.count {
                    guard let entry = listEntry(in: lines[index]) else { break }
                    entries.append(entry)
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        id: stableID(
                            prefix: "list",
                            content: entries.map { "\($0.indent)|\($0.marker.labelText)|\($0.text)" }.joined(separator: "|")
                        ),
                        kind: .list(buildListItems(from: entries))
                    )
                )
                continue
            }

            if trimmed.hasPrefix(">") {
                var quotes: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quotes.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let quoteText = quotes.joined(separator: " ")
                blocks.append(
                    MarkdownBlock(
                        id: stableID(prefix: "quote", content: quoteText),
                        kind: .quote(quoteText)
                    )
                )
                continue
            }

            // Thematic break: ---, ***, ___ (three or more, optionally with spaces)
            if isThematicBreak(trimmed) {
                blocks.append(
                    MarkdownBlock(
                        id: stableID(prefix: "hr", content: "\(index)"),
                        kind: .thematicBreak
                    )
                )
                index += 1
                continue
            }

            // Table: detect pipe-delimited header row followed by a divider row
            if let tableBlock = parseTable(lines: lines, startIndex: &index) {
                blocks.append(tableBlock)
                continue
            }

            var paragraphLines: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let current = lines[index].trimmingCharacters(in: .whitespaces)
                if current.isEmpty ||
                    current.hasPrefix("```") ||
                    headingBlock(from: current) != nil ||
                    checklistItem(in: current) != nil ||
                    listEntry(in: lines[index]) != nil ||
                    current.hasPrefix(">") ||
                    isThematicBreak(current) ||
                    isTableRow(current) {
                    break
                }
                paragraphLines.append(current)
                index += 1
            }
            let paragraphText = paragraphLines.joined(separator: " ")
            blocks.append(
                MarkdownBlock(
                    id: stableID(prefix: "paragraph", content: paragraphText),
                    kind: .paragraph(paragraphText)
                )
            )
        }

        return blocks
    }

    private static func headingBlock(from line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level > 0, level <= 6 else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownBlock(
            id: stableID(prefix: "heading\(level)", content: text),
            kind: .heading(level: level, text: text)
        )
    }

    private static func checklistItem(in line: String) -> (title: String, isCompleted: Bool)? {
        guard let match = line.range(
            of: #"^[-*]\s+\[( |x|X)\]\s+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let prefix = String(line[match])
        let title = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (title, prefix.localizedCaseInsensitiveContains("[x]"))
    }

    private static func listEntry(in line: String) -> ListEntry? {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leadingWhitespace.reduce(into: 0) { result, character in
            result += character == "\t" ? 4 : 1
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return ListEntry(
                indent: indent,
                marker: .unordered,
                text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            )
        }

        guard let match = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) else {
            return nil
        }

        let prefix = String(trimmed[..<match.upperBound])
        let numberText = prefix.components(separatedBy: ".").first ?? "1"
        let number = Int(numberText) ?? 1
        let text = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return ListEntry(indent: indent, marker: .ordered(number), text: text)
    }

    private static func buildListItems(from entries: [ListEntry]) -> [MarkdownListItem] {
        guard let firstIndent = entries.first?.indent else { return [] }
        var index = 0
        return parseListItems(entries, index: &index, indent: firstIndent)
    }

    private static func parseListItems(
        _ entries: [ListEntry],
        index: inout Int,
        indent: Int
    ) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []

        while index < entries.count {
            let entry = entries[index]

            if entry.indent < indent {
                break
            }

            if entry.indent > indent {
                if !items.isEmpty {
                    var lastItem = items.removeLast()
                    lastItem.children = parseListItems(entries, index: &index, indent: entry.indent)
                    items.append(lastItem)
                    continue
                }

                return parseListItems(entries, index: &index, indent: entry.indent)
            }

            var item = MarkdownListItem(
                id: stableID(
                    prefix: "list-item",
                    content: "\(entry.indent)|\(entry.marker.labelText)|\(entry.text)|\(index)"
                ),
                text: entry.text,
                marker: entry.marker,
                children: []
            )
            index += 1

            if index < entries.count, entries[index].indent > indent {
                item.children = parseListItems(entries, index: &index, indent: entries[index].indent)
            }

            items.append(item)
        }

        return items
    }

    private static func inferredCodeTargetHint(
        previousBlock: MarkdownBlock?,
        previousLine: String?,
        codeLines: [String]
    ) -> String? {
        if let previousBlock,
           case .paragraph(let text) = previousBlock.kind,
           let extracted = CodeTargetResolver.normalizedPathHint(from: text) {
            return extracted
        }

        if let previousLine,
           let extracted = CodeTargetResolver.normalizedPathHint(from: previousLine) {
            return extracted
        }

        for line in codeLines.prefix(4) {
            if let extracted = CodeTargetResolver.normalizedPathHint(from: line) {
                return extracted
            }
        }

        return nil
    }

    // MARK: - Thematic Break

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        if stripped.allSatisfy({ $0 == "-" }) { return true }
        if stripped.allSatisfy({ $0 == "*" }) { return true }
        if stripped.allSatisfy({ $0 == "_" }) { return true }
        return false
    }

    // MARK: - Table Parsing

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseTable(lines: [String], startIndex: inout Int) -> MarkdownBlock? {
        let savedIndex = startIndex
        let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)

        guard isTableRow(headerLine) else { return nil }

        // Need at least a divider row after the header
        guard startIndex + 1 < lines.count else { return nil }
        let dividerLine = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)
        guard isTableDivider(dividerLine) else {
            // Not a table — revert
            startIndex = savedIndex
            return nil
        }

        let headers = parseTableCells(headerLine)
        startIndex += 2 // skip header + divider

        var rows: [[String]] = []
        while startIndex < lines.count {
            let rowLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
            guard isTableRow(rowLine), !isTableDivider(rowLine) else { break }
            let cells = parseTableCells(rowLine)
            rows.append(cells)
            startIndex += 1
        }

        return MarkdownBlock(
            id: stableID(
                prefix: "table",
                content: headers.joined(separator: "|") + rows.map { $0.joined(separator: "|") }.joined(separator: "||")
            ),
            kind: .table(headers: headers, rows: rows)
        )
    }

    private static func stableID(prefix: String, content: String) -> String {
        let digest = String(content.hashValue, radix: 16, uppercase: false)
        return "\(prefix)-\(digest)"
    }
}

