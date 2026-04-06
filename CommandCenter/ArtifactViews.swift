// ArtifactViews.swift
// Studio.92 — Command Center

import SwiftUI
import AppKit

struct InlineScreenshotView: View {

    let path: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                            .stroke(StudioSeparator.subtle, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(StudioSurfaceGrouped.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .overlay {
                        Text("Screenshot unavailable")
                            .font(StudioTypography.footnote)
                            .foregroundStyle(StudioTextColor.tertiary)
                    }
            }
        }
        .onAppear(perform: loadImage)
        .onChange(of: path) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        guard FileManager.default.fileExists(atPath: path) else {
            image = nil
            return
        }

        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: path)
            }.value
            image = loaded
        }
    }
}

struct ArtifactCanvasView: View {

    private enum CanvasTab: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case deployment = "Deploy"

        var id: String { rawValue }
    }

    private enum InspectorMode: String, CaseIterable, Identifiable {
        case files = "Files"
        case preview = "Preview"
        case codeDiff = "Code Diff"

        var id: String { rawValue }
    }

    struct InspectorFileRecord: Identifiable, Equatable {
        let path: String
        let displayName: String
        let kind: ToolTrace.Kind
        let linesAdded: Int?
        let linesRemoved: Int?
        let timestamp: Date

        var id: String { path }
    }

    let epoch: Epoch?
    let turns: [ConversationTurn]
    let deploymentState: DeploymentState
    let packageRoot: String
    let initialMode: ArtifactCanvasLaunchMode
    let onClose: () -> Void

    @State private var canvasTab: CanvasTab
    @State private var inspectorMode: InspectorMode
    @State private var image: NSImage?
    @State private var isImageLoaded = false
    @State private var isLoadingImage = false
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var selectedInspectorFilePath: String?
    @State private var selectedInspectorContent: AttributedString?
    @State private var isLoadingInspectorContent = false
    @State private var inspectorLoadTask: Task<Void, Never>?

    init(
        epoch: Epoch?,
        turns: [ConversationTurn],
        deploymentState: DeploymentState,
        packageRoot: String,
        initialMode: ArtifactCanvasLaunchMode = .preview,
        onClose: @escaping () -> Void
    ) {
        self.epoch = epoch
        self.turns = turns
        self.deploymentState = deploymentState
        self.packageRoot = packageRoot
        self.initialMode = initialMode
        self.onClose = onClose
        _canvasTab = State(initialValue: Self.canvasTab(for: initialMode))
        _inspectorMode = State(initialValue: Self.inspectorMode(for: initialMode))
    }

    private var selectedTurn: ConversationTurn? {
        if let epoch,
           let matchedTurn = turns.last(where: { $0.epochID == epoch.id }) {
            return matchedTurn
        }

        return turns.last(where: { $0.toolTraces.contains(where: { $0.filePath != nil }) })
            ?? turns.last(where: { !$0.isHistorical })
            ?? turns.last
    }

    private var title: String {
        if let epoch {
            return "Epoch \(epoch.index)"
        }
        if deploymentState.isVisible {
            return "Deployment"
        }
        return "Inspector"
    }

    private var subtitle: String {
        if canvasTab == .deployment {
            return deploymentState.targetDirectory ?? packageRoot
        }
        if let selectedInspectorFile {
            return selectedInspectorFile.displayName
        }
        if let epoch {
            return (epoch.targetFile as NSString).lastPathComponent
        }
        return selectedTurn?.userGoal ?? "Current turn"
    }

    private var screenshotPath: String? {
        epoch?.screenshotPath
    }

    private var inspectorFiles: [InspectorFileRecord] {
        var records: [InspectorFileRecord] = []
        var seenPaths = Set<String>()

        if let selectedTurn {
            for trace in selectedTurn.toolTraces.sorted(by: isHigherPriorityTrace) {
                let rawPaths = !trace.relatedFilePaths.isEmpty
                    ? trace.relatedFilePaths
                    : [trace.filePath].compactMap { $0 }

                for rawPath in rawPaths {
                    guard let absolutePath = normalizedInspectorPath(rawPath) else { continue }
                    guard !seenPaths.contains(absolutePath) else { continue }
                    seenPaths.insert(absolutePath)
                    records.append(
                        InspectorFileRecord(
                            path: absolutePath,
                            displayName: CodeTargetResolver.displayName(
                                for: URL(fileURLWithPath: absolutePath),
                                packageRoot: packageRoot
                            ),
                            kind: trace.kind,
                            linesAdded: trace.linesAdded,
                            linesRemoved: trace.linesRemoved,
                            timestamp: trace.timestamp
                        )
                    )
                }
            }
        }

        if records.isEmpty,
           let epoch,
           let fallbackPath = normalizedInspectorPath(epoch.targetFile),
           FileManager.default.fileExists(atPath: fallbackPath) {
            records.append(
                InspectorFileRecord(
                    path: fallbackPath,
                    displayName: CodeTargetResolver.displayName(
                        for: URL(fileURLWithPath: fallbackPath),
                        packageRoot: packageRoot
                    ),
                    kind: .write,
                    linesAdded: nil,
                    linesRemoved: nil,
                    timestamp: epoch.mergedAt
                )
            )
        }

        return records
    }

    private var availableInspectorModes: [InspectorMode] {
        var modes: [InspectorMode] = []
        if !inspectorFiles.isEmpty {
            modes.append(.files)
        }
        if epoch != nil {
            modes.append(.preview)
            if let diffText = epoch?.diffText,
               !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modes.append(.codeDiff)
            }
        }
        return modes.isEmpty ? [.files] : modes
    }

    private var selectedInspectorFile: InspectorFileRecord? {
        if let selectedInspectorFilePath,
           let matched = inspectorFiles.first(where: { $0.path == selectedInspectorFilePath }) {
            return matched
        }
        return inspectorFiles.first
    }

    private var deploymentConsoleToolCall: ToolCall {
        ToolCall(
            toolType: .terminal,
            command: deploymentState.command ?? "fastlane \(deploymentState.lane)",
            status: deploymentStepStatus,
            liveOutput: deploymentState.lines
        )
    }

    private var deploymentStepStatus: StepStatus {
        switch deploymentState.phase {
        case .idle:
            return .pending
        case .running:
            return .active
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    private var deploymentDurationText: String? {
        guard let startedAt = deploymentState.startedAt else { return nil }
        let finishedAt = deploymentState.finishedAt ?? Date()
        let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt).rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch canvasTab {
                case .inspector:
                    inspectorContent
                case .deployment:
                    deploymentContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            StudioSurface.viewport
        )
        .onAppear {
            normalizeInspectorMode()
            synchronizeSelectedFile(resetSelection: false)
            loadImage()
            loadSelectedInspectorFile()
        }
        .onChange(of: initialMode) { _, newMode in
            withAnimation(StudioMotion.panelSpring) {
                canvasTab = Self.canvasTab(for: newMode)
                inspectorMode = Self.inspectorMode(for: newMode)
            }
            normalizeInspectorMode()
        }
        .onChange(of: epoch?.id) { _, _ in
            normalizeInspectorMode()
            loadImage()
        }
        .onChange(of: inspectorFiles.map(\.id)) { _, _ in
            synchronizeSelectedFile(resetSelection: false)
            normalizeInspectorMode()
        }
        .onChange(of: selectedInspectorFilePath) { _, _ in
            loadSelectedInspectorFile()
        }
        .onChange(of: canvasTab) { _, _ in
            normalizeInspectorMode()
        }
        .onDisappear {
            imageLoadTask?.cancel()
            inspectorLoadTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: StudioSpacing.xl) {
            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text(title)
                    .font(StudioTypography.titleSmall)
                    .foregroundStyle(StudioTextColor.primary)

                Text(subtitle)
                    .font(StudioTypography.dataCaption)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: StudioSpacing.lg) {
                Picker("Canvas", selection: $canvasTab) {
                    ForEach(CanvasTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if canvasTab == .inspector, availableInspectorModes.count > 1 {
                    Picker("Inspector Mode", selection: $inspectorMode) {
                        ForEach(availableInspectorModes) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(StudioTypography.headline)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close Artifact Canvas")
        }
        .padding(.horizontal, StudioSpacing.panel)
        .padding(.vertical, StudioSpacing.section)
        .background(StudioSurfaceGrouped.primary)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorMode {
        case .files:
            ArtifactInspectorFilesView(
                files: inspectorFiles,
                selectedFilePath: $selectedInspectorFilePath,
                selectedFileContent: selectedInspectorContent,
                isLoadingContent: isLoadingInspectorContent,
                packageRoot: packageRoot
            )
        case .preview:
            artifactPreview
        case .codeDiff:
            ArtifactCodeDiffView(diffText: epoch?.diffText)
        }
    }

    private var deploymentContent: some View {
        DeploymentDashboardView(
            deploymentState: deploymentState,
            toolCall: deploymentConsoleToolCall,
            durationText: deploymentDurationText
        )
    }

    private static func canvasTab(for launchMode: ArtifactCanvasLaunchMode) -> CanvasTab {
        switch launchMode {
        case .deployment:
            return .deployment
        case .inspector, .preview, .codeDiff:
            return .inspector
        }
    }

    private static func inspectorMode(for launchMode: ArtifactCanvasLaunchMode) -> InspectorMode {
        switch launchMode {
        case .inspector:
            return .files
        case .preview:
            return .preview
        case .codeDiff:
            return .codeDiff
        case .deployment:
            return .files
        }
    }

    private func normalizeInspectorMode() {
        let modes = availableInspectorModes
        guard canvasTab == .inspector else { return }
        if !modes.contains(inspectorMode) {
            inspectorMode = modes.first ?? .files
        }
    }

    private func synchronizeSelectedFile(resetSelection: Bool) {
        let preferredPath = inspectorFiles.first?.path

        if resetSelection {
            selectedInspectorFilePath = preferredPath
            return
        }

        if let preferredPath {
            selectedInspectorFilePath = preferredPath
            return
        }

        selectedInspectorFilePath = nil
    }

    private var artifactPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioSpacing.section) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudioRadius.hero, style: .continuous)
                        .fill(StudioSurface.viewport)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous))
                            .padding(StudioSpacing.xxl)
                            .opacity(isImageLoaded ? 1 : 0)
                            .animation(StudioMotion.emphasisFade, value: isImageLoaded)
                    } else if isLoadingImage {
                        VStack(spacing: StudioSpacing.lg) {
                            ProcessingGearsView()
                            Text("Mounting Viewport...")
                                .font(StudioTypography.dataCaption)
                                .foregroundStyle(StudioTextColor.tertiary)
                        }
                    } else {
                        VStack(spacing: StudioSpacing.lg) {
                            Image(systemName: "photo")
                                .font(StudioTypography.largeTitle)
                                .foregroundStyle(StudioTextColor.tertiary)
                            Text("Simulator screenshot unavailable")
                                .font(StudioTypography.footnote)
                                .foregroundStyle(StudioTextColor.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.hero, style: .continuous)
                        .stroke(StudioSeparator.subtle, lineWidth: 1)
                )

                if let epoch {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 120), spacing: StudioSpacing.lg),
                            GridItem(.flexible(minimum: 120), spacing: StudioSpacing.lg)
                        ],
                        spacing: 10
                    ) {
                        ArtifactMetricPill(label: "HIG Score", value: "\(Int((epoch.higScore * 100).rounded()))%")
                        ArtifactMetricPill(label: "Components Built", value: componentsBuiltValue(for: epoch))
                        ArtifactMetricPill(label: "Deviation Cost", value: "\(Int((epoch.deviationCost * 100).rounded()))")
                        ArtifactMetricPill(label: "Drift", value: "\(Int((epoch.driftScore * 100).rounded()))")
                    }

                    VStack(alignment: .leading, spacing: StudioSpacing.md) {
                            Text("Summary")
                                .font(StudioTypography.footnoteSemibold)
                                .foregroundStyle(StudioTextColor.secondary)

                        Text(epoch.summary)
                            .font(StudioTypography.subheadline)
                            .foregroundStyle(StudioTextColor.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(StudioSpacing.xxl)
                    .background(
                        RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                            .fill(StudioSurface.viewport)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                            .stroke(StudioSeparator.subtle, lineWidth: 1)
                    )
                }
            }
            .padding(StudioSpacing.panel)
        }
        .background(StudioSurface.viewport)
    }

    private func componentsBuiltValue(for epoch: Epoch) -> String {
        if let componentsBuilt = epoch.componentsBuilt {
            return "\(componentsBuilt)"
        }
        if let diffText = epoch.diffText, !diffText.isEmpty {
            return "1"
        }
        return "0"
    }

    private func loadImage() {
        imageLoadTask?.cancel()
        image = nil
        isImageLoaded = false

        guard let screenshotPath,
              FileManager.default.fileExists(atPath: screenshotPath) else {
            isLoadingImage = false
            return
        }

        isLoadingImage = true
        imageLoadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: screenshotPath)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                image = loaded
                isLoadingImage = false
                isImageLoaded = loaded != nil
            }
        }
    }

    private func loadSelectedInspectorFile() {
        inspectorLoadTask?.cancel()
        selectedInspectorContent = nil

        guard let selectedInspectorFile else {
            isLoadingInspectorContent = false
            return
        }

        isLoadingInspectorContent = true
        inspectorLoadTask = Task {
            let content = await Task.detached(priority: .userInitiated) { () -> AttributedString? in
                guard let source = try? String(contentsOfFile: selectedInspectorFile.path, encoding: .utf8) else {
                    return nil
                }
                return CodeSyntaxHighlighter.highlight(
                    code: source,
                    language: selectedInspectorFile.path.components(separatedBy: ".").last
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                selectedInspectorContent = content
                isLoadingInspectorContent = false
            }
        }
    }

    private func normalizedInspectorPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = URL(fileURLWithPath: packageRoot, isDirectory: true).appendingPathComponent(trimmed)
        }

        let standardizedPath = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: standardizedPath) ? standardizedPath : nil
    }

    private func isHigherPriorityTrace(_ lhs: ToolTrace, _ rhs: ToolTrace) -> Bool {
        let lhsPriority = inspectorPriority(for: lhs)
        let rhsPriority = inspectorPriority(for: rhs)

        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }

        return lhs.id < rhs.id
    }

    private func inspectorPriority(for trace: ToolTrace) -> Int {
        if trace.sourceName == "delegate_to_reviewer" && trace.isLive {
            return 4
        }

        if (trace.sourceName == "file_write" || trace.sourceName == "file_patch") && trace.isLive {
            return 3
        }

        if trace.sourceName == "file_write" || trace.sourceName == "file_patch" {
            return 2
        }

        if trace.sourceName == "delegate_to_reviewer" {
            return 1
        }

        return 0
    }
}

struct ArtifactInspectorFilesView: View {

    let files: [ArtifactCanvasView.InspectorFileRecord]
    @Binding var selectedFilePath: String?
    let selectedFileContent: AttributedString?
    let isLoadingContent: Bool
    let packageRoot: String

    var body: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                ContentUnavailableView(
                    "No Modified Files",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("When the current turn reads or writes files, they’ll appear here for inspection.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioSurface.viewport)
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: StudioSpacing.md) {
                            ForEach(files) { file in
                                ArtifactInspectorFileChip(
                                    file: file,
                                    isSelected: selectedFilePath == file.path
                                ) {
                                    withAnimation(StudioMotion.panelSpring) {
                                        selectedFilePath = file.path
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, StudioSpacing.panel)
                        .padding(.vertical, StudioSpacing.xxl)
                    }

                    Divider()

                    Group {
                        if isLoadingContent {
                            VStack(spacing: StudioSpacing.lg) {
                                ProcessingGearsView()
                                Text("Loading file...")
                                    .font(StudioTypography.dataCaption)
                                    .foregroundStyle(StudioTextColor.tertiary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let selectedFileContent {
                            ScrollView([.vertical, .horizontal]) {
                                Text(selectedFileContent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(StudioSpacing.panel)
                                    .textSelection(.enabled)
                            }
                        } else {
                            ContentUnavailableView(
                                "File Unavailable",
                                systemImage: "doc.badge.xmark",
                                description: Text("The selected file could not be loaded from the current project root.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background(StudioSurface.viewport)
                }
                .background(StudioSurface.viewport)
            }
        }
    }
}

struct ArtifactInspectorFileChip: View {

    let file: ArtifactCanvasView.InspectorFileRecord
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: symbolName)
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(isSelected ? StudioTextColor.primary : StudioTextColor.secondary)

                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    Text(file.displayName)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)

                    if let diffSummary {
                        Text(diffSummary)
                            .font(StudioTypography.monoDigitsSmall)
                            .foregroundStyle(StudioTextColor.secondary)
                    }
                }
            }
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, StudioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.fastSpring, value: isHovering)
        .animation(StudioMotion.fastSpring, value: isSelected)
    }

    private var symbolName: String {
        switch file.kind {
        case .read:
            return "doc.text"
        case .edit:
            return "square.and.pencil"
        case .write:
            return "doc.badge.plus"
        case .search:
            return "magnifyingglass"
        case .build:
            return "hammer.fill"
        case .terminal:
            return "terminal.fill"
        case .screenshot:
            return "camera.viewfinder"
        case .artifact:
            return "rectangle.split.3x1"
        }
    }

    private var diffSummary: String? {
        guard file.linesAdded != nil || file.linesRemoved != nil else { return nil }
        let added = file.linesAdded ?? 0
        let removed = file.linesRemoved ?? 0
        return "+\(added) -\(removed)"
    }

    private var backgroundColor: Color {
        if isSelected {
            return StudioSurfaceElevated.level2
        }
        if isHovering {
            return StudioSurfaceElevated.level2
        }
        return StudioSurfaceElevated.level1
    }

    private var borderColor: Color {
        isSelected ? StudioTextColor.primary.opacity(0.10) : Color.clear
    }
}

struct DeploymentDashboardView: View {

    let deploymentState: DeploymentState
    let toolCall: ToolCall
    let durationText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioSpacing.panel) {
                VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                    HStack(alignment: .center, spacing: StudioSpacing.xl) {
                        ZStack {
                            Circle()
                                .fill(StudioSurfaceElevated.level2.opacity(0.85))
                                .frame(width: 44, height: 44)

                            if deploymentState.isActive {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(StudioAccentColor.primary)
                            } else {
                                Image(systemName: statusSymbolName)
                                    .font(StudioTypography.title)
                                    .foregroundStyle(StudioTextColor.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                            Text(headerTitle)
                                .font(StudioTypography.headline)
                                .foregroundStyle(StudioTextColor.primary)

                            Text(headerSubtitle)
                                .font(StudioTypography.footnote)
                                .foregroundStyle(StudioTextColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        if let durationText {
                            Text(durationText)
                                .font(StudioTypography.monoDigits)
                                .foregroundStyle(StudioTextColor.secondary)
                        }
                    }

                    if let targetDirectory = deploymentState.targetDirectory,
                       !targetDirectory.isEmpty {
                        Text(targetDirectory)
                            .font(StudioTypography.dataCaption)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .textSelection(.enabled)
                    }
                }
                        .padding(StudioSpacing.section)
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                                .fill(StudioSurface.viewport)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                                .stroke(StudioSeparator.subtle, lineWidth: 1)
                        )

                ArtifactConsoleBlock(toolCall: toolCall)
                    .animation(StudioMotion.panelSpring, value: toolCall.status)
            }
            .padding(StudioSpacing.panel)
        }
        .background(StudioSurface.viewport)
    }

    private var headerTitle: String {
        switch deploymentState.phase {
        case .idle:
            return "Deployment idle"
        case .running:
            return "Shipping to TestFlight"
        case .completed:
            return "Deployment complete"
        case .failed:
            return "Deployment failed"
        }
    }

    private var headerSubtitle: String {
        deploymentState.summary ?? "Fastlane \(deploymentState.lane)"
    }

    private var statusSymbolName: String {
        switch deploymentState.phase {
        case .idle:
            return StudioSymbol.resolve("paperplane.circle", "paperplane")
        case .running:
            return StudioSymbol.resolve("paperplane.circle.fill", "paperplane.fill")
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        }
    }
}

struct ArtifactMetricPill: View {

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
            Text(label)
                .font(StudioTypography.captionSemibold)
                .tracking(0.3)
                .foregroundStyle(StudioTextColor.secondary)
            Text(value)
                .font(StudioTypography.codeSemibold)
                .foregroundStyle(StudioTextColor.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct ArtifactCodeDiffView: View {

    let diffText: String?

    private var lines: [String] {
        guard let diffText else { return [] }
        return diffText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView(
                    "No Grounded Diff",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This epoch was archived without a source delta, so there’s no exact code diff to render.")
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: StudioSpacing.xl) {
                                Text("\(index + 1)")
                                    .font(StudioTypography.codeSmall)
                                    .foregroundStyle(StudioTextColor.tertiary)
                                    .frame(width: 34, alignment: .trailing)

                                Text(line.isEmpty ? " " : line)
                                    .font(StudioTypography.code)
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, StudioSpacing.xxl)
                            .padding(.vertical, StudioSpacing.xxsPlus)
                            .background(backgroundColor(for: line))
                            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous))
                        }
                    }
                    .padding(StudioSpacing.panel)
                }
                .background(StudioSurface.viewport)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return StudioColorTokens.Syntax.diffAddition
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return StudioColorTokens.Syntax.diffRemoval
        }
        if line.hasPrefix("@@") {
            return StudioColorTokens.Syntax.diffHeader
        }
        return StudioColorTokens.Syntax.plainColor
    }

    private func backgroundColor(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return StudioColorTokens.Syntax.diffAddition.opacity(0.08)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return StudioColorTokens.Syntax.diffRemoval.opacity(0.08)
        }
        if line.hasPrefix("@@") {
            return StudioColorTokens.Syntax.diffHeader.opacity(0.08)
        }
        return Color.clear
    }
}

