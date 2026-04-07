import SwiftUI
import AppKit

struct BlueprintTask: Identifiable, Equatable {
    let id: String
    let title: String
    let isCompleted: Bool
}

struct ShimmerEffect: ViewModifier {

    let isActive: Bool

    @State private var phase: CGFloat = -1.2
    @State private var animationTask: Task<Void, Never>?
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear, location: 0),
                            .init(color: StudioColorTokens.ThermalGlow.cool.opacity(0.18), location: 0.3),
                            .init(color: StudioColorTokens.ThermalGlow.neutral.opacity(0.14), location: 0.5),
                            .init(color: StudioColorTokens.ThermalGlow.warm.opacity(0.18), location: 0.7),
                            .init(color: Color.clear, location: 1)
                        ],
                        startPoint: UnitPoint(x: phase - 1.0, y: 0.5),
                        endPoint: UnitPoint(x: phase, y: 0.5)
                    )
                    .blendMode(.screen)
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                startAnimationIfNeeded()
            }
            .onChange(of: isActive) { _, active in
                if active {
                    startAnimationIfNeeded()
                } else {
                    stopAnimation()
                }
            }
            .onDisappear {
                stopAnimation()
            }
    }

    private func startAnimationIfNeeded() {
        guard isActive, !isAnimating else { return }

        animationTask?.cancel()
        isAnimating = true
        phase = -1.2

        animationTask = Task { @MainActor in
            defer {
                animationTask = nil
                isAnimating = false
            }

            while !Task.isCancelled {
                phase = -1.2
                await Task.yield()
                guard !Task.isCancelled else { break }

                withAnimation(StudioMotion.shimmer) {
                    phase = 2.2
                }

                do {
                    try await Task.sleep(for: .seconds(4.0))
                } catch {
                    break
                }
            }

            phase = -1.2
        }
    }

    private func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil
        isAnimating = false
        phase = -1.2
    }
}

extension View {
    func shimmer(isActive: Bool) -> some View {
        modifier(ShimmerEffect(isActive: isActive))
    }
}

struct ProcessingGearsView: View {

    @State private var isSpinning = false

    var body: some View {
        HStack(alignment: .center, spacing: -8) {
            gear(
                size: .title2,
                baseRotation: 0,
                animatedRotation: isSpinning ? 360 : 0,
                tint: StudioTextColor.secondary.opacity(0.94),
                shadowOpacity: 0.16
            )
            .zIndex(1)

            gear(
                size: .title3,
                baseRotation: 18,
                animatedRotation: isSpinning ? -360 : 0,
                tint: StudioTextColor.tertiary.opacity(0.96),
                shadowOpacity: 0.12
            )
            .offset(x: -2, y: 8)
        }
        .padding(.vertical, StudioSpacing.xxs)
        .drawingGroup()
        .onAppear {
            guard !isSpinning else { return }
            isSpinning = true
        }
    }

    private func gear(
        size: Font,
        baseRotation: Double,
        animatedRotation: Double,
        tint: Color,
        shadowOpacity: Double
    ) -> some View {
        Image(systemName: "gearshape.fill")
            .font(size)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .padding(StudioSpacing.md)
            .background(
                Circle()
                    .fill(StudioSurfaceElevated.level2)
            )
            .rotationEffect(.degrees(baseRotation + animatedRotation))
            .animation(
                StudioMotion.rotation,
                value: isSpinning
            )
    }
}

struct ToolCallCard: View {

    let toolCall: ToolCall

    var body: some View {
        switch toolCall.toolType {
        case .webSearch, .webFetch:
            WebToolCard(toolCall: toolCall)
        case .screenshotSimulator, .xcodePreview:
            ScreenshotToolCard(toolCall: toolCall)
        case .xcodeBuild, .xcodeTest:
            BuildToolCard(toolCall: toolCall)
        case .gitStatus, .gitDiff, .gitCommit:
            GitToolCard(toolCall: toolCall)
        case .multimodalAnalyze:
            MultimodalToolCard(toolCall: toolCall)
        case .simulatorLaunchApp:
            SimulatorToolCard(toolCall: toolCall)
        case .terminal, .fileRead, .fileWrite, .filePatch, .listFiles:
            ArtifactConsoleBlock(toolCall: toolCall)
        }
    }
}

struct PhantomToolLogView: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: iconName)
                .font(StudioTypography.captionSemibold)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)
            Text(toolCall.command)
                .lineLimit(1)
        }
        .font(StudioTypography.dataCaption)
        .foregroundStyle(foregroundColor)
        .shimmer(isActive: toolCall.status == .active)
    }

    private var iconName: String {
        switch toolCall.status {
        case .active:
            return "circle.dashed"
        case .completed:
            return "checkmark.circle"
        case .failed, .warning:
            return "xmark.circle"
        case .pending:
            return "circle"
        }
    }

    private var foregroundColor: Color {
        switch toolCall.status {
        case .active:
            return StudioTextColor.secondary.opacity(0.96)
        case .completed:
            return StudioTextColor.tertiary
        case .failed, .warning:
            return StudioTextColor.secondary
        case .pending:
            return StudioTextColor.secondary.opacity(0.72)
        }
    }
}

struct BlueprintCardView: View {

    let tasks: [BlueprintTask]
    let isPipelineRunning: Bool

    private enum DisplayState {
        case completed
        case active
        case pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack {
                Label(progressLabel, systemImage: "list.bullet.rectangle")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColor.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    row(for: task, state: displayState(for: task, at: index))
                }
            }
        }
        .padding(.vertical, StudioSpacing.xxs)
    }

    private var progressLabel: String {
        "\(tasks.filter { $0.isCompleted }.count) of \(tasks.count) tasks completed"
    }

    private func displayState(for task: BlueprintTask, at index: Int) -> DisplayState {
        if task.isCompleted {
            return .completed
        }

        if isPipelineRunning,
           index == tasks.firstIndex(where: { !$0.isCompleted }) {
            return .active
        }

        return .pending
    }

    @ViewBuilder
    private func row(for task: BlueprintTask, state: DisplayState) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            Image(systemName: iconName(for: state))
                .font(StudioTypography.captionSemibold)
                .foregroundStyle(iconColor(for: state))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .active)

            Text(task.title)
                .font(StudioTypography.footnoteMedium)
                .foregroundStyle(textColor(for: state))
                .fixedSize(horizontal: false, vertical: true)
                .shimmer(isActive: state == .active)

            Spacer(minLength: 0)
        }
    }

    private func iconName(for state: DisplayState) -> String {
        switch state {
        case .completed:
            return "checkmark.circle"
        case .active:
            return "circle.dashed"
        case .pending:
            return "circle"
        }
    }

    private func iconColor(for state: DisplayState) -> Color {
        switch state {
        case .completed:
            return StudioTextColor.tertiary
        case .active:
            return StudioTextColor.secondary
        case .pending:
            return StudioTextColor.tertiary
        }
    }

    private func textColor(for state: DisplayState) -> Color {
        switch state {
        case .completed:
            return StudioTextColor.primary
        case .active:
            return StudioTextColor.primary.opacity(0.96)
        case .pending:
            return StudioTextColor.secondary
        }
    }
}

struct BlueprintCompactView: View {

    let tasks: [BlueprintTask]
    let isPipelineRunning: Bool

    private var completedCount: Int {
        tasks.filter(\.isCompleted).count
    }

    private var activeTaskTitle: String? {
        if let firstUnchecked = tasks.first(where: { !$0.isCompleted }) {
            return firstUnchecked.title
        }
        return tasks.last?.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: StudioSpacing.lg) {
            Image(systemName: isPipelineRunning ? "list.bullet.clipboard" : "checklist")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColor.secondary)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text("Plan")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.secondary)

                if let activeTaskTitle, !activeTaskTitle.isEmpty {
                    Text(activeTaskTitle)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(1)
                        .shimmer(isActive: isPipelineRunning)
                }
            }

            Spacer(minLength: 0)

            Text("\(completedCount)/\(tasks.count)")
                .font(StudioTypography.monoDigits)
                .foregroundStyle(StudioTextColor.tertiary)
        }
        .padding(.vertical, StudioSpacing.xxs)
    }
}

struct WebToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Image(systemName: iconName)
                .font(StudioTypography.titleSmall)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text(title)
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.secondary)

                Text(toolCall.command)
                    .font(StudioTypography.bodyMedium)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Text(statusLabel)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(statusColor)
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .shimmer(isActive: toolCall.status == .active)
    }

    private var title: String {
        switch toolCall.toolType {
        case .webSearch:         return "Web Search"
        case .webFetch:          return "Web Fetch"
        case .terminal:          return "Terminal"
        case .fileRead:          return "File Read"
        case .fileWrite:         return "File Write"
        case .filePatch:         return "File Patch"
        case .listFiles:         return "List Files"
        case .screenshotSimulator: return "Screenshot"
        case .xcodeBuild:        return "Build"
        case .xcodeTest:         return "Test"
        case .xcodePreview:      return "Preview"
        case .multimodalAnalyze: return "Vision"
        case .gitStatus:         return "Git Status"
        case .gitDiff:           return "Git Diff"
        case .gitCommit:         return "Git Commit"
        case .simulatorLaunchApp: return "Simulator"
        }
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        default:
            switch toolCall.toolType {
            case .webSearch:            return "magnifyingglass"
            case .webFetch:             return "globe"
            case .terminal:             return "terminal"
            case .fileRead:             return "doc.text.magnifyingglass"
            case .fileWrite:            return "square.and.pencil"
            case .filePatch:            return "square.and.pencil.circle.fill"
            case .listFiles:            return "folder"
            case .screenshotSimulator:  return "camera.viewfinder"
            case .xcodeBuild:           return "hammer"
            case .xcodeTest:            return "testtube.2"
            case .xcodePreview:         return "play.rectangle"
            case .multimodalAnalyze:    return "eye.trianglebadge.exclamationmark"
            case .gitStatus:            return "arrow.triangle.branch"
            case .gitDiff:              return "doc.text.magnifyingglass"
            case .gitCommit:            return "arrow.up.doc"
            case .simulatorLaunchApp:   return "iphone.gen3"
            }
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed:
            return StudioStatusColor.success
        case .failed:
            return StudioStatusColor.danger
        case .active:
            return StudioAccentColor.primary
        case .pending, .warning:
            return StudioTextColor.secondary
        }
    }

    private var statusLabel: String {
        switch toolCall.status {
        case .pending:
            return "Pending"
        case .active:
            return "Running"
        case .completed:
            return "Done"
        case .warning:
            return "Warning"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .completed:
            return StudioStatusColor.success
        case .failed:
            return StudioStatusColor.danger
        case .active:
            return StudioAccentColor.primary
        case .pending, .warning:
            return StudioTextColor.secondary
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed:
            return StudioStatusColor.success.opacity(0.06)
        case .failed:
            return StudioStatusColor.danger.opacity(0.06)
        case .active:
            return StudioSurfaceElevated.level2
        case .pending, .warning:
            return StudioSurfaceElevated.level1
        }
    }
}

struct TerminalToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        ArtifactConsoleBlock(toolCall: toolCall)
    }
}

// MARK: - Screenshot Tool Card

struct ScreenshotToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioSpacing.xl) {
                Image(systemName: iconName)
                    .font(StudioTypography.titleSmall)
                    .foregroundStyle(iconColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text(toolCall.toolType == .xcodePreview ? "Preview" : "Screenshot")
                        .font(StudioTypography.captionSemibold)
                        .foregroundStyle(StudioTextColor.secondary)

                    Text(toolCall.command)
                        .font(StudioTypography.bodyMedium)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                statusBadge
            }
            .padding(StudioSpacing.section)

            if toolCall.status == .completed, let screenshotPath = extractScreenshotPath() {
                screenshotPreview(path: screenshotPath)
                    .padding(.horizontal, StudioSpacing.section)
                    .padding(.bottom, StudioSpacing.section)
            }

            if !toolCall.liveOutput.isEmpty, toolCall.status != .completed {
                outputLines
                    .padding(.horizontal, StudioSpacing.section)
                    .padding(.bottom, StudioSpacing.lg)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
        .shimmer(isActive: toolCall.status == .active)
    }

    @ViewBuilder
    private func screenshotPreview(path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                        .stroke(StudioTextColor.tertiary.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private var outputLines: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
            ForEach(Array(toolCall.liveOutput.suffix(5).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(StudioTypography.dataCaption)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func extractScreenshotPath() -> String? {
        toolCall.liveOutput.last(where: { $0.contains(".png") || $0.contains("Screenshot saved") })?
            .components(separatedBy: ": ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        default:         return "camera.viewfinder"
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch toolCall.status {
        case .active:
            Text("Capturing")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioAccentColor.primary)
        case .completed:
            Text("Captured")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioStatusColor.success)
        case .failed:
            Text("Failed")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioStatusColor.danger)
        default:
            Text("Pending")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColor.secondary)
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success.opacity(0.06)
        case .failed:    return StudioStatusColor.danger.opacity(0.06)
        case .active:    return StudioSurfaceElevated.level2
        default:         return StudioSurfaceElevated.level1
        }
    }
}

// MARK: - Build/Test Tool Card

struct BuildToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioSpacing.xl) {
                Image(systemName: iconName)
                    .font(StudioTypography.titleSmall)
                    .foregroundStyle(iconColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text(toolCall.toolType == .xcodeTest ? "Test" : "Build")
                        .font(StudioTypography.captionSemibold)
                        .foregroundStyle(StudioTextColor.secondary)

                    Text(toolCall.command)
                        .font(StudioTypography.codeSemibold)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                statusBadge
            }
            .padding(StudioSpacing.section)

            if !toolCall.liveOutput.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        ForEach(Array(toolCall.liveOutput.suffix(30).enumerated()), id: \.offset) { _, line in
                            buildLine(line)
                        }
                    }
                    .padding(StudioSpacing.section)
                }
                .frame(maxHeight: 180)
                .background(StudioSurface.viewport)
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.bottom, StudioSpacing.lg)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
        .shimmer(isActive: toolCall.status == .active)
    }

    @ViewBuilder
    private func buildLine(_ line: String) -> some View {
        let lower = line.lowercased()
        let isError = lower.contains("error") || lower.contains("fatal")
        let isWarning = lower.contains("warning")
        let isSuccess = lower.contains("succeeded") || lower.contains("passed") || lower.contains("build complete")

        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            Circle()
                .fill(isError ? StudioStatusColor.danger : isWarning ? StudioStatusColor.warning : isSuccess ? StudioStatusColor.success : StudioTextColor.tertiary)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            Text(line)
                .font(StudioTypography.dataCaption)
                .foregroundStyle(isError ? StudioStatusColor.danger.opacity(0.96) : isWarning ? StudioStatusColor.warning.opacity(0.96) : StudioTextColor.primary.opacity(0.72))
                .textSelection(.enabled)
        }
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        case .active:    return toolCall.toolType == .xcodeTest ? "testtube.2" : "hammer.fill"
        default:         return toolCall.toolType == .xcodeTest ? "testtube.2" : "hammer"
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let label: String = {
            switch toolCall.status {
            case .active:    return toolCall.toolType == .xcodeTest ? "Testing" : "Building"
            case .completed: return toolCall.toolType == .xcodeTest ? "Passed" : "Succeeded"
            case .failed:    return "Failed"
            default:         return "Pending"
            }
        }()
        Text(label)
            .font(StudioTypography.footnoteSemibold)
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success.opacity(0.06)
        case .failed:    return StudioStatusColor.danger.opacity(0.06)
        case .active:    return StudioSurfaceElevated.level2
        default:         return StudioSurfaceElevated.level1
        }
    }
}

// MARK: - Git Tool Card

struct GitToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Image(systemName: iconName)
                .font(StudioTypography.titleSmall)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text(title)
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColor.secondary)

                Text(toolCall.command)
                    .font(StudioTypography.codeSemibold)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Text(statusLabel)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(statusColor)
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .shimmer(isActive: toolCall.status == .active)
    }

    private var title: String {
        switch toolCall.toolType {
        case .gitStatus: return "Git Status"
        case .gitDiff:   return "Git Diff"
        case .gitCommit: return "Git Commit"
        default:         return "Git"
        }
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        default:
            switch toolCall.toolType {
            case .gitCommit: return "arrow.up.doc"
            case .gitDiff:   return "doc.text.magnifyingglass"
            default:         return "arrow.triangle.branch"
            }
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var statusLabel: String {
        switch toolCall.status {
        case .pending:   return "Pending"
        case .active:    return "Running"
        case .completed: return "Done"
        case .warning:   return "Warning"
        case .failed:    return "Failed"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success.opacity(0.06)
        case .failed:    return StudioStatusColor.danger.opacity(0.06)
        case .active:    return StudioSurfaceElevated.level2
        default:         return StudioSurfaceElevated.level1
        }
    }
}

// MARK: - Multimodal Tool Card

struct MultimodalToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Image(systemName: iconName)
                .font(StudioTypography.titleSmall)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text("Vision Analysis")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColor.secondary)

                Text(toolCall.command)
                    .font(StudioTypography.bodyMedium)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(statusLabel)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(statusColor)
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .shimmer(isActive: toolCall.status == .active)
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        default:         return "eye.trianglebadge.exclamationmark"
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var statusLabel: String {
        switch toolCall.status {
        case .pending:   return "Pending"
        case .active:    return "Analyzing"
        case .completed: return "Done"
        case .warning:   return "Warning"
        case .failed:    return "Failed"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success.opacity(0.06)
        case .failed:    return StudioStatusColor.danger.opacity(0.06)
        case .active:    return StudioSurfaceElevated.level2
        default:         return StudioSurfaceElevated.level1
        }
    }
}

// MARK: - Simulator Launch Card

struct SimulatorToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Image(systemName: iconName)
                .font(StudioTypography.titleSmall)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text("Simulator Launch")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColor.secondary)

                Text(toolCall.command)
                    .font(StudioTypography.bodyMedium)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(statusLabel)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(statusColor)
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(cardBackground)
        )
        .shimmer(isActive: toolCall.status == .active)
    }

    private var iconName: String {
        switch toolCall.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        default:         return "iphone.gen3"
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var statusLabel: String {
        switch toolCall.status {
        case .pending:   return "Pending"
        case .active:    return "Launching"
        case .completed: return "Launched"
        case .warning:   return "Warning"
        case .failed:    return "Failed"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success
        case .failed:    return StudioStatusColor.danger
        case .active:    return StudioAccentColor.primary
        default:         return StudioTextColor.secondary
        }
    }

    private var cardBackground: Color {
        switch toolCall.status {
        case .completed: return StudioStatusColor.success.opacity(0.06)
        case .failed:    return StudioStatusColor.danger.opacity(0.06)
        case .active:    return StudioSurfaceElevated.level2
        default:         return StudioSurfaceElevated.level1
        }
    }
}

struct ArtifactConsoleBlock: View {

    let toolCall: ToolCall

    @State private var isExpanded: Bool
    @State private var hasCopied = false

    init(toolCall: ToolCall) {
        self.toolCall = toolCall
        _isExpanded = State(initialValue: toolCall.status == .active || toolCall.status == .failed)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(StudioMotion.standardSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: StudioSpacing.lg) {
                    Image(systemName: headerIconName)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(headerAccentColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

                    VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                        Text(toolStatusLabel)
                            .font(StudioTypography.captionSemibold)
                            .tracking(0.3)
                            .foregroundStyle(StudioTextColor.secondary)

                        Text(toolCall.command)
                            .font(StudioTypography.codeSemibold)
                            .foregroundStyle(StudioTextColor.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if !toolCall.liveOutput.isEmpty {
                        Text(outputCountLabel)
                            .font(StudioTypography.monoDigitsSmall)
                            .foregroundStyle(StudioTextColor.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(StudioTypography.captionSemibold)
                        .foregroundStyle(StudioTextColor.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, StudioSpacing.xxl)
                .padding(.vertical, StudioSpacing.xl)
                .contentShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: StudioSpacing.sm) {
                            if toolCall.liveOutput.isEmpty {
                                ArtifactConsoleLine(
                                    prefix: "›",
                                    text: emptyStateText,
                                    tone: .neutral
                                )
                                .id(-1)
                            } else {
                                ForEach(Array(toolCall.liveOutput.enumerated()), id: \.offset) { index, line in
                                    ArtifactConsoleLine(
                                        prefix: prefix(for: line),
                                        text: line,
                                        tone: tone(for: line)
                                    )
                                    .id(index)
                                }
                            }
                        }
                        .padding(StudioSpacing.section)
                    }
                    .frame(minHeight: 118, maxHeight: 240)
                    .background(StudioSurface.viewport)
                    .overlay(alignment: .topTrailing) {
                        if !toolCall.liveOutput.isEmpty {
                            Button {
                                copyToClipboard()
                            } label: {
                                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                                    .font(StudioTypography.badge)
                                    .foregroundStyle(hasCopied ? StudioStatusColor.success : StudioTextColor.tertiary)
                                    .padding(StudioSpacing.sm)
                            }
                            .buttonStyle(.plain)
                            .padding(StudioSpacing.sm)
                        }
                    }
                    .padding(.horizontal, StudioSpacing.lg)
                    .padding(.bottom, StudioSpacing.lg)
                    .onAppear {
                        scrollToBottom(using: proxy, animated: false)
                    }
                    .onChange(of: toolCall.liveOutput.count) { _, _ in
                        scrollToBottom(using: proxy, animated: true)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(consoleBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
        .animation(StudioMotion.standardSpring, value: toolCall.status)
        .onChange(of: toolCall.status) { _, newStatus in
            if newStatus == .active || newStatus == .failed {
                withAnimation(StudioMotion.standardSpring) {
                    isExpanded = true
                }
            }
        }
    }

    private func copyToClipboard() {
        let text = toolCall.liveOutput.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hasCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            hasCopied = false
        }
    }

    private var emptyStateText: String {
        switch toolCall.status {
        case .active:
            return "Waiting for terminal output..."
        case .failed:
            return "Command exited without captured output."
        default:
            return "No terminal output."
        }
    }

    private var headerIconName: String {
        switch toolCall.status {
        case .pending:
            return "chevron.left.slash.chevron.right"
        case .active:
            return "terminal.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var toolStatusLabel: String {
        switch toolCall.status {
        case .pending:
            return "Queued Console"
        case .active:
            return "Live Console"
        case .completed:
            return "Console Complete"
        case .warning:
            return "Console Warning"
        case .failed:
            return "Console Error"
        }
    }

    private var outputCountLabel: String {
        "\(toolCall.liveOutput.count) lines"
    }

    private var consoleBackground: Color {
        switch toolCall.status {
        case .pending:
            return StudioSurfaceElevated.level1
        case .active:
            return StudioSurfaceElevated.level2
        case .completed:
            return StudioStatusColor.success.opacity(0.05)
        case .warning:
            return StudioStatusColor.warning.opacity(0.05)
        case .failed:
            return StudioStatusColor.danger.opacity(0.05)
        }
    }

    private var headerAccentColor: Color {
        switch toolCall.status {
        case .pending:
            return StudioTextColor.secondary
        case .active:
            return StudioAccentColor.primary
        case .completed:
            return StudioStatusColor.success
        case .warning:
            return StudioStatusColor.warning
        case .failed:
            return StudioStatusColor.danger
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        let anchor = toolCall.liveOutput.isEmpty ? -1 : toolCall.liveOutput.count - 1
        if animated {
            withAnimation(StudioMotion.softFade) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private func prefix(for line: String) -> String {
        let lowercased = line.lowercased()
        if lowercased.contains("[error]") || lowercased.contains("error") || lowercased.contains("fatal") {
            return "!"
        }
        if lowercased.contains("success") || lowercased.contains("succeeded") || lowercased.contains("passed") {
            return "✓"
        }
        return ">"
    }

    private func tone(for line: String) -> ArtifactConsoleLine.Tone {
        let lowercased = line.lowercased()
        if lowercased.contains("[error]") || lowercased.contains("error") || lowercased.contains("fatal") || lowercased.contains("failed") {
            return .error
        }
        if lowercased.contains("success") || lowercased.contains("succeeded") || lowercased.contains("passed") || lowercased.contains("complete") {
            return .success
        }
        return .neutral
    }
}

private struct ArtifactConsoleLine: View {

    enum Tone {
        case neutral
        case success
        case error
    }

    let prefix: String
    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            Text(prefix)
                .font(StudioTypography.dataCaption)
                .foregroundStyle(prefixColor)
                .frame(width: 12, alignment: .center)

            Text(text.isEmpty ? " " : text)
                .font(StudioTypography.dataCaption)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var prefixColor: Color {
        switch tone {
        case .neutral:
            return StudioTextColor.tertiary
        case .success:
            return StudioStatusColor.success
        case .error:
            return StudioStatusColor.danger
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral:
            return StudioTextColor.primary.opacity(0.72)
        case .success:
            return StudioStatusColor.success.opacity(0.96)
        case .error:
            return StudioStatusColor.danger.opacity(0.96)
        }
    }
}
