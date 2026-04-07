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
        VStack(alignment: .leading, spacing: StudioChatLayout.listItemSpacing) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: StudioChatLayout.listMarkerSpacing) {
                        ListMarkerView(marker: item.marker, tone: tone)

                        MarkdownInlineText(text: item.text, tone: tone)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !item.children.isEmpty {
                        MarkdownListView(items: item.children, tone: tone)
                            .padding(.leading, StudioChatLayout.listIndent)
                    }
                }
            }
        }
    }
}

/// Renders the list marker: bullet dot for unordered, .ultraThinMaterial
/// circular badge with centred monospaced-digit number for ordered lists.
private struct ListMarkerView: View {

    let marker: MarkdownListItem.Marker
    let tone: MarkdownMessageContent.Tone

    var body: some View {
        switch marker {
        case .unordered:
            Circle()
                .fill(StudioTextColor.tertiary.opacity(StudioChatLayout.assistantTertiaryTextOpacity))
                .frame(width: 4, height: 4)
                .padding(.top, 7)
                .frame(width: StudioChatLayout.listMarkerWidth, alignment: .center)

        case .ordered(let n):
            Text("\(n).")
                .font(.system(size: tone == .meta ? 12 : 13, weight: .medium).monospacedDigit())
                .foregroundStyle(StudioTextColor.tertiary.opacity(0.68))
                .frame(width: StudioChatLayout.listMarkerWidth, alignment: .leading)
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

// MARK: - Insight Card (blockquote upgrade)

/// A blockquote rendered as a spatial object: #14181D card, 2pt Electric Cyan
/// left rail, secondary text. Architectural insights read as cards, not annotations.
private struct InsightCard: View {

    let text: String
    let tone: MarkdownMessageContent.Tone

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 3pt cyan rail — flush with card edge
            Rectangle()
                .fill(StudioAccentColor.primary.opacity(0.70))
                .frame(width: 3)

            MarkdownInlineText(text: text, tone: tone)
                .foregroundStyle(StudioTextColor.secondary)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
        }
        .background(Color(hex: "#14181D"))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
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
                        .fontOverride(headingFont(for: level))
                        .foregroundStyleOverride(headingColor)
                        .lineSpacingOverride(6)
                        .padding(.top, index == 0 ? 0 : StudioChatLayout.headingTopSpacing)
                        .padding(.bottom, StudioChatLayout.headingBottomSpacing)
                case .paragraph(let value):
                    MarkdownInlineText(text: value, tone: tone)
                        .opacity(isLeadParagraph ? StudioChatLayout.assistantLeadBlockOpacity : paragraphOpacity)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .list(let items):
                    MarkdownListView(items: items, tone: tone)
                        .opacity(paragraphOpacity)
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
                    InsightCard(text: value, tone: tone)
                        .opacity(paragraphOpacity)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .code(let language, let code, let targetHint):
                    CodeBlockCard(
                        language: language,
                        code: code,
                        targetHint: targetHint,
                        isStreaming: isStreaming
                    )
                    .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .liveDiff(let diffBlock):
                    LiveDiffCard(block: diffBlock, isStreaming: isStreaming)
                        .padding(.bottom, StudioChatLayout.paragraphSpacing)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, tone: tone)
                        .opacity(paragraphOpacity)
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

    private var paragraphOpacity: Double {
        tone == .assistant ? StudioChatLayout.assistantBodyBlockOpacity : 1.0
    }

    private var headingColor: Color {
        switch tone {
        case .assistant:
            return StudioTextColor.primary.opacity(0.98)
        case .user:
            return .white
        case .meta:
            return StudioTextColor.secondary
        case .body:
            return StudioTextColor.primary
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch tone {
        case .assistant:
            return .system(size: StudioChatLayout.headingFontSize, weight: .semibold, design: .default)
        case .body, .user:
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
    var fontOverrideValue: Font? = nil
    var foregroundStyleOverrideValue: Color? = nil
    var lineSpacingOverrideValue: CGFloat? = nil

    init(text: String, tone: MarkdownMessageContent.Tone = .body) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        if var attributed = Self.cachedAttributedString(text: text, tone: tone) {
            let _ = Self.refineAttributes(&attributed, tone: tone)
            Text(attributed)
                .font(resolvedFont)
                .tracking(StudioChatLayout.bodyLetterSpacing)
                .foregroundStyle(resolvedForegroundStyle)
                .lineSpacing(resolvedLineSpacing)
                .tint(linkTint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(resolvedFont)
                .tracking(StudioChatLayout.bodyLetterSpacing)
                .foregroundStyle(resolvedForegroundStyle)
                .lineSpacing(resolvedLineSpacing)
                .tint(linkTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func fontOverride(_ font: Font) -> MarkdownInlineText {
        var copy = self
        copy.fontOverrideValue = font
        return copy
    }

    func foregroundStyleOverride(_ color: Color) -> MarkdownInlineText {
        var copy = self
        copy.foregroundStyleOverrideValue = color
        return copy
    }

    func lineSpacingOverride(_ spacing: CGFloat) -> MarkdownInlineText {
        var copy = self
        copy.lineSpacingOverrideValue = spacing
        return copy
    }

    // MARK: - AttributedString Cache

    private static let cacheQueue = DispatchQueue(label: "studio92.markdown.inline-cache")
    private static var cache: [String: AttributedString] = [:]
    private static let cacheCapacity = 256

    private static func cachedAttributedString(text: String, tone: MarkdownMessageContent.Tone) -> AttributedString? {
        let key = "\(tone)-\(text)"
        return cacheQueue.sync {
            if let hit = cache[key] { return hit }
            guard let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) else { return nil }
            if cache.count >= cacheCapacity {
                // Evict ~25% on capacity — simple but effective for streaming where
                // older blocks are rarely revisited.
                let keysToRemove = Array(cache.keys.prefix(cacheCapacity / 4))
                for k in keysToRemove { cache.removeValue(forKey: k) }
            }
            cache[key] = parsed
            return parsed
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
                } else if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) {
                    let size = baseFontSize(for: tone)
                    attributed[run.range].font = .system(size: size, weight: .semibold, design: .default)
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = linkColor(for: tone)
            }
        }
    }

    private static func baseFontSize(for tone: MarkdownMessageContent.Tone) -> CGFloat {
        switch tone {
        case .body:
            return StudioChatLayout.bodyFontSize
        case .assistant:
            return StudioChatLayout.assistantFontSize
        case .user:
            return StudioChatLayout.userFontSize
        case .meta:
            return StudioChatLayout.metaFontSize
        }
    }

    private static func linkColor(for tone: MarkdownMessageContent.Tone) -> Color {
        switch tone {
        case .assistant, .body:
            return StudioTextColor.primary.opacity(StudioChatLayout.assistantLinkOpacity)
        case .user:
            return .white.opacity(0.9)
        case .meta:
            return StudioTextColor.secondary.opacity(0.86)
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

    private var resolvedFont: Font {
        fontOverrideValue ?? font
    }

    private var foregroundStyle: Color {
        switch tone {
        case .body:
            return StudioTextColor.primary.opacity(0.95)
        case .assistant:
            return StudioTextColor.primary.opacity(StudioChatLayout.assistantPrimaryTextOpacity)
        case .user:
            return .white
        case .meta:
            return StudioTextColor.secondary.opacity(StudioChatLayout.assistantSecondaryTextOpacity)
        }
    }

    private var resolvedForegroundStyle: Color {
        foregroundStyleOverrideValue ?? foregroundStyle
    }

    private var lineSpacing: CGFloat {
        switch tone {
        case .body, .assistant, .user:
            return StudioChatLayout.bodyLineSpacing
        case .meta:
            return 4
        }
    }

    private var resolvedLineSpacing: CGFloat {
        lineSpacingOverrideValue ?? lineSpacing
    }

    private var linkTint: Color {
        Self.linkColor(for: tone)
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

// MARK: - LiveDiff Models

/// A single rendered line inside a live diff block.
struct LiveDiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, addition, deletion, hunkHeader }
    /// Ordinal index from the raw diff codeLines array — stable across incremental parses.
    let id: Int
    let kind: Kind
    /// Line text without the leading +/-/space sigil.
    let text: String
}

/// Incrementally-built unified diff block. Emitted while the fence is still open.
struct LiveDiffBlock: Equatable {
    let id: String
    /// Last path component, e.g. "NetworkManager.swift"
    let filename: String
    /// Full path for viewport deep-link, e.g. "Sources/Network/NetworkManager.swift"
    let filePath: String
    var lines: [LiveDiffLine]
    var additionCount: Int
    var deletionCount: Int
    /// True once the closing ``` has been seen. Triggers the 1.5s collapse timer.
    var isComplete: Bool

    // Performance: only compare shape — avoid deep array comparison on every re-render.
    static func == (lhs: LiveDiffBlock, rhs: LiveDiffBlock) -> Bool {
        lhs.id == rhs.id
            && lhs.isComplete == rhs.isComplete
            && lhs.lines.count == rhs.lines.count
            && lhs.additionCount == rhs.additionCount
            && lhs.deletionCount == rhs.deletionCount
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
        /// A unified diff block — emitted incrementally while the fence is still open.
        case liveDiff(LiveDiffBlock)
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
                let isCompleteFence = index < lines.count
                if isCompleteFence { index += 1 }

                // ── Live diff block ──────────────────────────────────────────────────────
                // Intercept ```diff fences and build a LiveDiffBlock instead of a .code block.
                // Partial blocks (incomplete fence) are still emitted so the card renders
                // while the stream is still open.
                if language.lowercased() == "diff" {
                    var diffLines: [LiveDiffLine] = []
                    var filename = ""
                    var filePath = ""
                    var addCount = 0
                    var delCount = 0
                    for (i, rawLine) in codeLines.enumerated() {
                        if rawLine.hasPrefix("--- ") || rawLine.hasPrefix("+++ ") {
                            let rest = String(rawLine.dropFirst(4))
                            // Strip git a/ b/ prefixes
                            let path = (rest.hasPrefix("a/") || rest.hasPrefix("b/"))
                                ? String(rest.dropFirst(2))
                                : rest
                            if rawLine.hasPrefix("+++ ") && !path.isEmpty && path != "/dev/null" {
                                filePath = path
                                filename = (path as NSString).lastPathComponent
                            }
                            continue // header lines are not display lines
                        }
                        if rawLine.hasPrefix("@@") {
                            diffLines.append(LiveDiffLine(id: i, kind: .hunkHeader, text: rawLine))
                        } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
                            addCount += 1
                            diffLines.append(LiveDiffLine(id: i, kind: .addition, text: String(rawLine.dropFirst())))
                        } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
                            delCount += 1
                            diffLines.append(LiveDiffLine(id: i, kind: .deletion, text: String(rawLine.dropFirst())))
                        } else {
                            let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                            diffLines.append(LiveDiffLine(id: i, kind: .context, text: text))
                        }
                    }
                    let diffBlockID = "diff-\(codeBlockOrdinal)"
                    codeBlockOrdinal += 1
                    blocks.append(MarkdownBlock(
                        id: diffBlockID,
                        kind: .liveDiff(LiveDiffBlock(
                            id: diffBlockID,
                            filename: filename,
                            filePath: filePath,
                            lines: diffLines,
                            additionCount: addCount,
                            deletionCount: delCount,
                            isComplete: isCompleteFence
                        ))
                    ))
                    continue
                }

                // ── Regular code block ───────────────────────────────────────────────────
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

    private static let checklistRegex = try! NSRegularExpression(pattern: #"^[-*]\s+\[( |x|X)\]\s+"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\d+)\.\s+"#)

    private static func checklistItem(in line: String) -> (title: String, isCompleted: Bool)? {
        let nsLine = line as NSString
        guard let result = checklistRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        let match = Range(result.range, in: line)!

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

        let nsTrimmed = trimmed as NSString
        guard let result = orderedListRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsTrimmed.length)),
              let match = Range(result.range, in: trimmed) else {
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

    private static let blockCounter = AtomicBlockCounter()

    private static func stableID(prefix: String, content: String) -> String {
        let ordinal = blockCounter.next()
        return "\(prefix)-\(ordinal)"
    }
}

/// Thread-safe monotonic counter for generating unique block IDs within a parse pass.
/// Uses `OSAtomicIncrement64` semantics via `os_unfair_lock` for minimal overhead.
private final class AtomicBlockCounter: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        value += 1
        let v = value
        lock.unlock()
        return v
    }
}

// MARK: - LiveDiffCard

/// The "Light Block" — a holographic inline diff card that streams code mutations
/// in real-time, then collapses into a compact pill once the write completes.
struct LiveDiffCard: View {

    let block: LiveDiffBlock
    let isStreaming: Bool

    @Environment(\.viewportActionContext) private var viewportActions
    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @State private var isCollapsed = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var didFireViewportSync = false
    @State private var dotPulse = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedPill
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    ))
            } else {
                expandedCard
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    ))
            }
        }
        .animation(.spring(duration: 0.40, bounce: 0.06), value: isCollapsed)
        // Viewport sync: switch to the file as soon as the filename token is parsed.
        .onChange(of: block.filename) { _, newName in
            guard !newName.isEmpty, !didFireViewportSync else { return }
            didFireViewportSync = true
            viewportActions.showFilePreview(resolvedPath(for: block.filePath.isEmpty ? newName : block.filePath))
        }
        .onAppear {
            if !block.filename.isEmpty, !didFireViewportSync {
                didFireViewportSync = true
                viewportActions.showFilePreview(resolvedPath(for: block.filePath.isEmpty ? block.filename : block.filePath))
            }
        }
        // Collapse timer: 1.5s after stream closes.
        .onChange(of: block.isComplete) { _, complete in
            guard complete else { return }
            collapseTask?.cancel()
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.48, bounce: 0.04)) {
                    isCollapsed = true
                }
            }
        }
    }

    // MARK: - Path resolution

    /// Resolve a diff-header relative path (e.g. "Sources/Foo/Bar.swift") to an
    /// absolute path using the stored package root, mirroring CodeBlockCard's logic.
    private func resolvedPath(for diffPath: String) -> String {
        guard !diffPath.hasPrefix("/") else { return diffPath }
        let root = packageRoot
        return root.isEmpty ? diffPath : "\(root)/\(diffPath)"
    }

    private var packageRoot: String {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return storedPackageRoot
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }
        return FileManager.default.currentDirectoryPath
    }

    // MARK: - Expanded Card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(StudioAccentColor.primary.opacity(0.18))
                .frame(height: 0.5)
            diffLines
        }
        .background(Color(hex: "#0B0D10"))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StudioAccentColor.primary.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Header bar

    private var header: some View {
        HStack(spacing: StudioSpacing.sm) {
            liveIndicator

            Text(block.filename.isEmpty ? "diff" : block.filename)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTextColor.secondary)
                .lineLimit(1)

            Spacer()

            if block.additionCount > 0 || block.deletionCount > 0 {
                HStack(spacing: 5) {
                    Text("+\(block.additionCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioColorTokens.Syntax.diffAddition.opacity(0.85))
                    Text("-\(block.deletionCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioColorTokens.Syntax.diffRemoval.opacity(0.70))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var liveIndicator: some View {
        if !block.isComplete {
            Circle()
                .fill(StudioColorTokens.Syntax.diffAddition)
                .frame(width: 6, height: 6)
                .scaleEffect(dotPulse ? 1.4 : 1.0)
                .opacity(dotPulse ? 0.70 : 1.0)
                .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: dotPulse)
                .onAppear { dotPulse = true }
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioColorTokens.Syntax.diffAddition)
                .transition(.opacity)
        }
    }

    // MARK: - Diff Lines

    private var diffLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(windowedLines) { line in
                LiveDiffLineRow(line: line)
                    .transition(line.kind == .addition
                        ? AnyTransition.modifier(
                            active: DiffBlurModifier(radius: 3.5, opacity: 0),
                            identity: DiffBlurModifier(radius: 0, opacity: 1)
                          )
                        : AnyTransition.identity
                    )
            }
        }
        .animation(.easeOut(duration: 0.18), value: block.lines.count)
        .padding(.vertical, 4)
    }

    /// Context windowing: 3 context lines above first change, all changes, 3 below last change.
    private var windowedLines: [LiveDiffLine] {
        let visible = block.lines.filter { $0.kind != .hunkHeader }
        let changeIndices = visible.indices.filter {
            visible[$0].kind == .addition || visible[$0].kind == .deletion
        }
        guard let firstCI = changeIndices.first, let lastCI = changeIndices.last else {
            // No changes yet (still streaming header) — show up to 6 context lines
            return Array(visible.prefix(6))
        }
        let start = max(0, firstCI - 3)
        let end = min(visible.count - 1, lastCI + 3)
        return Array(visible[start...end])
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        HStack(spacing: StudioSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(StudioColorTokens.Syntax.diffAddition)

            Text("Updated \(block.filename.isEmpty ? "file" : block.filename)")
                .font(StudioTypography.footnote)
                .foregroundStyle(StudioTextColor.secondary)

            if block.additionCount > 0 || block.deletionCount > 0 {
                Text("+\(block.additionCount), -\(block.deletionCount)")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(StudioColorTokens.Syntax.diffAddition.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioColorTokens.Syntax.diffAddition.opacity(0.28), lineWidth: 0.5)
        )
    }
}

// MARK: - Diff blur-materialize transition helpers

/// Single parameterized modifier so active/identity share the same type, as required
/// by `AnyTransition.modifier(active:identity:)`.
private struct DiffBlurModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

// MARK: - LiveDiffLineRow

private struct LiveDiffLineRow: View {

    let line: LiveDiffLine

    private var sigil: String {
        switch line.kind {
        case .addition:  return "+"
        case .deletion:  return "-"
        case .context:   return " "
        case .hunkHeader: return "@@"
        }
    }

    private var bgColor: Color {
        switch line.kind {
        case .addition:  return StudioColorTokens.Syntax.diffAddition.opacity(0.10) // sheer Volt Mint
        case .deletion:  return Color(hex: "#4A2B2B")                               // muted red
        case .context, .hunkHeader: return .clear
        }
    }

    private var fgColor: Color {
        switch line.kind {
        case .addition:  return StudioColorTokens.Syntax.diffAddition
        case .deletion:  return StudioColorTokens.Syntax.diffRemoval.opacity(0.60) // desaturated
        case .context:   return StudioTextColor.secondary.opacity(0.55)
        case .hunkHeader: return StudioColorTokens.Syntax.diffHeader
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sigil)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(fgColor.opacity(0.80))
                .frame(width: 10, alignment: .leading)

            Text(line.text)
                .font(StudioTypography.code)
                .foregroundStyle(fgColor)
                .strikethrough(line.kind == .deletion, color: fgColor.opacity(0.60))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(bgColor)
    }
}

