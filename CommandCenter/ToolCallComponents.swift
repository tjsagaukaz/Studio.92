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

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.3),
                            .clear
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
                    phase = -1.2
                }
            }
    }

    private func startAnimationIfNeeded() {
        guard isActive else { return }
        phase = -1.2
        DispatchQueue.main.async {
            guard isActive else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 2.2
            }
        }
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
                tint: StudioTheme.secondaryText.opacity(0.94),
                shadowOpacity: 0.16
            )
            .zIndex(1)

            gear(
                size: .title3,
                baseRotation: 18,
                animatedRotation: isSpinning ? -360 : 0,
                tint: StudioTheme.tertiaryText.opacity(0.96),
                shadowOpacity: 0.12
            )
            .offset(x: -2, y: 8)
        }
        .padding(.vertical, 2)
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
            .padding(6)
            .background(
                Circle()
                    .fill(StudioTheme.surfaceFill)
            )
            .overlay(
                Circle()
                    .stroke(StudioTheme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: 6, y: 2)
            .rotationEffect(.degrees(baseRotation + animatedRotation))
            .animation(
                .linear(duration: 3.0).repeatForever(autoreverses: false),
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
        case .terminal, .fileRead, .fileWrite, .filePatch, .listFiles:
            ArtifactConsoleBlock(toolCall: toolCall)
        }
    }
}

struct PhantomToolLogView: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)
            Text(toolCall.command)
                .lineLimit(1)
        }
        .font(.system(.caption, design: .monospaced))
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
            return .secondary.opacity(0.96)
        case .completed:
            return StudioTheme.tertiaryText
        case .failed, .warning:
            return .secondary
        case .pending:
            return .secondary.opacity(0.72)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(progressLabel, systemImage: "list.bullet.rectangle.portrait")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    row(for: task, state: displayState(for: task, at: index))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: state))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor(for: state))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .active)

            Text(task.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(textColor(for: state))
                .fixedSize(horizontal: false, vertical: true)
                .shimmer(isActive: state == .active)

            Spacer(minLength: 0)
        }
    }

    private func iconName(for state: DisplayState) -> String {
        switch state {
        case .completed:
            return "checkmark.circle.fill"
        case .active:
            return "circle.dashed"
        case .pending:
            return "circle"
        }
    }

    private func iconColor(for state: DisplayState) -> Color {
        switch state {
        case .completed:
            return StudioTheme.success
        case .active:
            return StudioTheme.accent
        case .pending:
            return StudioTheme.tertiaryText
        }
    }

    private func textColor(for state: DisplayState) -> Color {
        switch state {
        case .completed:
            return StudioTheme.primaryText
        case .active:
            return StudioTheme.primaryText.opacity(0.96)
        case .pending:
            return StudioTheme.secondaryText
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isPipelineRunning ? "list.bullet.clipboard" : "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.secondaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text("Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)

                if let activeTaskTitle, !activeTaskTitle.isEmpty {
                    Text(activeTaskTitle)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(1)
                        .shimmer(isActive: isPipelineRunning)
                }
            }

            Spacer(minLength: 0)

            Text("\(completedCount)/\(tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioTheme.tertiaryText)
        }
        .padding(.vertical, 2)
    }
}

struct WebToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)

                Text(toolCall.command)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shimmer(isActive: toolCall.status == .active)
    }

    private var title: String {
        switch toolCall.toolType {
        case .webSearch:
            return "Web Search"
        case .webFetch:
            return "Web Fetch"
        case .terminal:
            return "Terminal"
        case .fileRead:
            return "File Read"
        case .fileWrite:
            return "File Write"
        case .filePatch:
            return "File Patch"
        case .listFiles:
            return "List Files"
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
            case .webSearch:
                return "magnifyingglass"
            case .webFetch:
                return "globe"
            case .terminal:
                return "terminal"
            case .fileRead:
                return "doc.text.magnifyingglass"
            case .fileWrite:
                return "square.and.pencil"
            case .filePatch:
                return "square.and.pencil.circle.fill"
            case .listFiles:
                return "folder"
            }
        }
    }

    private var iconColor: Color {
        switch toolCall.status {
        case .completed:
            return StudioTheme.success
        case .failed:
            return StudioTheme.danger
        case .active:
            return StudioTheme.accent
        case .pending, .warning:
            return StudioTheme.secondaryText
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
            return StudioTheme.success
        case .failed:
            return StudioTheme.danger
        case .active:
            return StudioTheme.accent
        case .pending, .warning:
            return StudioTheme.secondaryText
        }
    }

    private var borderColor: Color {
        switch toolCall.status {
        case .completed:
            return StudioTheme.success.opacity(0.28)
        case .failed:
            return StudioTheme.danger.opacity(0.28)
        case .active:
            return StudioTheme.accentStroke
        case .pending, .warning:
            return StudioTheme.stroke
        }
    }
}

struct TerminalToolCard: View {

    let toolCall: ToolCall

    var body: some View {
        ArtifactConsoleBlock(toolCall: toolCall)
    }
}

struct ArtifactConsoleBlock: View {

    let toolCall: ToolCall

    @State private var isExpanded: Bool

    init(toolCall: ToolCall) {
        self.toolCall = toolCall
        _isExpanded = State(initialValue: toolCall.status == .active || toolCall.status == .failed)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: headerIconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(headerAccentColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: toolCall.status == .active)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(toolStatusLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(StudioTheme.secondaryText)

                        Text(toolCall.command)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(StudioTheme.primaryText.opacity(0.94))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if !toolCall.liveOutput.isEmpty {
                        Text(outputCountLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(StudioTheme.secondaryText)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(StudioTheme.divider)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
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
                        .padding(14)
                    }
                    .frame(minHeight: 118, maxHeight: 240)
                    .background(StudioTheme.terminalBackground)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.liftedSurface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: toolCall.status)
        .onChange(of: toolCall.status) { _, newStatus in
            if newStatus == .active || newStatus == .failed {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isExpanded = true
                }
            }
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

    private var borderColor: Color {
        switch toolCall.status {
        case .pending:
            return StudioTheme.stroke
        case .active:
            return StudioTheme.accentStroke
        case .completed:
            return StudioTheme.success.opacity(0.34)
        case .warning:
            return StudioTheme.warning.opacity(0.34)
        case .failed:
            return StudioTheme.danger.opacity(0.34)
        }
    }

    private var headerAccentColor: Color {
        switch toolCall.status {
        case .pending:
            return StudioTheme.secondaryText
        case .active:
            return StudioTheme.accent
        case .completed:
            return StudioTheme.success
        case .warning:
            return StudioTheme.warning
        case .failed:
            return StudioTheme.danger
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        let anchor = toolCall.liveOutput.isEmpty ? -1 : toolCall.liveOutput.count - 1
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
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
        HStack(alignment: .top, spacing: 10) {
            Text(prefix)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 12, alignment: .center)

            Text(text.isEmpty ? " " : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var prefixColor: Color {
        switch tone {
        case .neutral:
            return StudioTheme.tertiaryText
        case .success:
            return StudioTheme.success
        case .error:
            return StudioTheme.danger
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral:
            return StudioTheme.primaryText.opacity(0.72)
        case .success:
            return StudioTheme.success.opacity(0.96)
        case .error:
            return StudioTheme.danger.opacity(0.96)
        }
    }
}
