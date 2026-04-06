// ChatDetailViews.swift
// Studio.92 — CommandCenter
//
// Artifact cards, completion metrics, message detail panel, security gate, and approval audit.

import SwiftUI
import AppKit

struct ArtifactCardView: View {

    let message: ChatMessage
    let isHighlighted: Bool
    let onOpenArtifact: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            MarkdownMessageContent(text: message.text)

            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                HStack(alignment: .center) {
                    Label("Artifact", systemImage: "checkmark.seal.fill")
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.secondary)

                    Spacer()

                    Button {
                        onOpenArtifact(message.epochID)
                    } label: {
                        Label("Show in Viewport", systemImage: "sidebar.right")
                            .font(StudioTypography.footnoteSemibold)
                            .foregroundStyle(StudioTextColor.primary)
                    }
                    .buttonStyle(.plain)
                }

                if let metrics = message.metrics {
                    CompletionMetricsRow(metrics: metrics)
                }

                CompletionSourcesRow(message: message)

                if let screenshotPath = message.screenshotPath {
                    InlineScreenshotView(path: screenshotPath)
                        .frame(maxHeight: 220)
                }

                if let detailText = message.detailText,
                   !detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MessageDetailPanel(text: detailText)
                }
            }
            .padding(StudioSpacing.section)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                    .fill(StudioSurfaceGrouped.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                    .stroke(
                        isHighlighted ? StudioTextColor.primary.opacity(0.12) : StudioSeparator.subtle,
                        lineWidth: isHighlighted ? 1.3 : 1
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous))
        .onTapGesture {
            onOpenArtifact(message.epochID)
        }
    }
}

struct CompletionMetricsRow: View {

    let metrics: MessageMetrics

    var body: some View {
        HStack(spacing: StudioSpacing.md) {
            CompletionMetricChip(label: "File", value: (metrics.targetFile as NSString).lastPathComponent)
            CompletionMetricChip(label: "Direction", value: metrics.archetype.isEmpty ? "Native" : metrics.archetype)
            if let elapsedString {
                CompletionMetricChip(label: "Time", value: elapsedString)
            }
        }
    }

    private var elapsedString: String? {
        guard let elapsedSeconds = metrics.elapsedSeconds else { return nil }
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes == 0 {
            return "\(seconds)s"
        }
        return "\(minutes)m \(seconds)s"
    }
}

struct CompletionMetricChip: View {

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: StudioSpacing.sm) {
            Text(label)
                .font(StudioTypography.captionSemibold)
                .tracking(0.3)
                .foregroundStyle(StudioTextColor.secondary)
            Text(value)
                .font(StudioTypography.dataCaption)
                .foregroundStyle(StudioTextColor.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
    }
}

struct MessageDetailPanel: View {

    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownMessageContent(text: text)
                .padding(.top, StudioSpacing.md)
        } label: {
            Label("Design Rationale", systemImage: "text.document")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColor.secondary)
        }
        .padding(StudioSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioSurfaceElevated.level2.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct CompletionSourcesRow: View {

    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @Environment(\.viewportActionContext) private var viewportActions

    let message: ChatMessage

    private var resolvedTargetFilePath: String? {
        guard let targetFile = message.metrics?.targetFile, !targetFile.isEmpty else { return nil }
        if targetFile.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: targetFile) ? targetFile : nil
        }

        let candidates = [
            resolvedPackageRoot,
            FileManager.default.currentDirectoryPath
        ].filter { !$0.isEmpty }

        for root in candidates {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(targetFile).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudioSpacing.md) {
                if let targetFile = message.metrics?.targetFile, !targetFile.isEmpty {
                    ReferenceBadge(
                        title: (targetFile as NSString).lastPathComponent,
                        systemImage: "doc.text"
                    ) {
                        if let resolvedTargetFilePath {
                            viewportActions.showFilePreview(resolvedTargetFilePath)
                        } else {
                            copyToPasteboard(targetFile)
                        }
                    }
                }

                if let packetID = message.packetID {
                    ReferenceBadge(
                        title: "Packet \(packetID.uuidString.prefix(8))",
                        systemImage: "shippingbox"
                    ) {
                        copyToPasteboard(packetID.uuidString)
                    }
                }

                if let epochID = message.epochID {
                    ReferenceBadge(
                        title: "Epoch \(epochID.uuidString.prefix(6))",
                        systemImage: "clock.arrow.circlepath"
                    ) {
                        copyToPasteboard(epochID.uuidString)
                    }
                }

                if let screenshotPath = message.screenshotPath {
                    ReferenceBadge(
                        title: "Screenshot",
                        systemImage: "photo"
                    ) {
                        revealInFinder(path: screenshotPath)
                    }
                }
            }
            .padding(.vertical, StudioSpacing.xxs)
        }
    }

    private var resolvedPackageRoot: String {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return storedPackageRoot
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.path
            }
        }

        return ""
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyToPasteboard(_ text: String) {
        writeTextToPasteboard(text)
    }
}

// MARK: - Sent Reference Pill (message bubble)

struct SentReferencePill: View {

    let attachment: ChatAttachment

    private var fileSymbol: String {
        if attachment.isImage { return "photo" }
        switch attachment.url.pathExtension.lowercased() {
        case "swift":                  return "doc.text"
        case "py":                     return "doc.plaintext"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json":                   return "curly.braces"
        case "md":                     return "doc.richtext"
        case "yaml", "yml", "toml":    return "list.bullet.rectangle"
        case "sh", "bash":             return "terminal"
        case "pdf":                    return "doc.richtext.fill"
        default:                       return "doc"
        }
    }

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
        } label: {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: fileSymbol)
                    .font(.system(size: 10, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white.opacity(0.32))

                Text(attachment.displayName)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)

                Circle()
                    .fill(StudioAccentColor.primary.opacity(0.70))
                    .frame(width: 4, height: 4)
            }
            .padding(.horizontal, StudioSpacing.md)
            .padding(.vertical, StudioSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.sm, style: .continuous)
                    .fill(Color(hex: "#14181D"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.sm, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Strategy Gate Card

/// A monochrome plan-confirmation card that slides into the right dead space of
/// the center pane when DAG mode is triggered. The user reviews the proposed steps
/// and either approves, refines via the composer, or lets auto-execute bypass it.
struct StrategyGateCard: View {

    let request: StrategyGateRequest
    let onApprove: () -> Void
    let onRefine: () -> Void

    @State private var appeared = false

    private static let surface = Color(hex: "#14181D")
    private static let cyan = StudioAccentColor.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gateHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.07))

            stepList
                .padding(.top, 8)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.07))

            gateActions
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(Self.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .strokeBorder(Self.cyan.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 8)
        .offset(y: appeared ? 0 : 10)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82).delay(0.06)) {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var gateHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Self.cyan.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                Text("STRATEGY")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(Self.cyan.opacity(0.45))
                    .tracking(1.6)

                Text("\(request.steps.count)-Step Plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)

            // Model badge
            Text(request.modelName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
        }
    }

    // MARK: - Step List

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(request.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.2))
                        .frame(width: 14, alignment: .center)

                    Text(step.title)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: - Actions

    private var gateActions: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(StudioMotion.fastSpring) {
                    onRefine()
                }
            } label: {
                Text("Refine Plan")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(StudioMotion.fastSpring) {
                    onApprove()
                }
            } label: {
                Text("Approve & Execute")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Self.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .shadow(color: Self.cyan.opacity(0.35), radius: 10, x: 0, y: 2)
        }
    }
}

// MARK: - Security Gate Card

struct SecurityGateCard: View {

    let request: ToolApprovalRequest
    let onAuthorize: () -> Void
    let onReject: () -> Void

    @State private var appeared = false

    private static let amber = Color(hex: "#FFB340")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            gateHeader

            Text(request.intentDescription)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = request.actionPreview, !preview.isEmpty {
                if isTerminal {
                    GateTerminalCommandBlock(command: preview)
                } else {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.amber.opacity(0.85))
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Self.amber.opacity(0.15), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            gateActions
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: "#0B0D10"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Self.amber.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: Self.amber.opacity(0.10), radius: 20, x: 0, y: 3)
        .offset(y: appeared ? 0 : 10)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72).delay(0.04)) {
                appeared = true
            }
        }
    }

    private var isTerminal: Bool {
        let n = request.toolName.lowercased()
        return n.contains("terminal") || n.contains("shell") || n.contains("bash") || n.contains("run_command")
    }

    private var gateHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.exclamationmark.fill")
                .foregroundStyle(Self.amber)
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text("SECURITY GATE")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Self.amber.opacity(0.6))
                    .tracking(1.4)

                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            AmberGateDot()
        }
    }

    private var gateActions: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    onReject()
                }
            } label: {
                Text("Reject")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    onAuthorize()
                }
            } label: {
                Text("Authorize")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Self.amber)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .shadow(color: Self.amber.opacity(0.4), radius: 10, x: 0, y: 2)
        }
    }
}

// MARK: - Gate Terminal Command Block

private struct GateTerminalCommandBlock: View {

    let command: String

    private static let destructiveTokens: Set<String> = [
        "rm", "-rf", "-r", "-f", "--force", "-fR", "sudo", "dd",
        "mkfs", "shred", "truncate", ">", ">>", "chmod", "chown",
        "rmdir", "--no-preserve-root", "format", "wipe", "pkill", "kill"
    ]

    private static let amber = Color(hex: "#FFB340")

    private var tokens: [String] {
        command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    Text(token)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(
                            Self.destructiveTokens.contains(token)
                                ? Self.amber
                                : Color.white.opacity(0.72)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.black)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Self.amber.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Amber Gate Dot

private struct AmberGateDot: View {

    @State private var isPulsing = false

    private static let amber = Color(hex: "#FFB340")

    var body: some View {
        Circle()
            .fill(Self.amber)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Approval Audit Row

struct ApprovalAuditRow: View {

    let entry: ApprovalAuditEntry
    var onShowRevert: ((ApprovalAuditEntry) -> Void)?

    @State private var isHovered = false

    private static let amber = Color(hex: "#FFB340")

    private var iconName: String {
        entry.outcome == .authorized ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var outcomeLabel: String {
        entry.outcome == .authorized ? "Authorized" : "Rejected"
    }

    private var iconColor: Color {
        entry.outcome == .authorized
            ? Self.amber
            : Color.white.opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Self.amber.opacity(entry.outcome == .authorized ? 0.35 : 0.12))
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)

            Text(outcomeLabel + " · " + entry.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(entry.outcome == .authorized ? 0.45 : 0.28))
                .lineLimit(1)

            Spacer()

            if isHovered && entry.outcome == .authorized && onShowRevert != nil {
                Button {
                    onShowRevert?(entry)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .frame(width: 20, height: 20)
                        .help("Revert workspace to this point")
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                Text(entry.timestamp, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.hoverEase, value: isHovered)
    }
}

