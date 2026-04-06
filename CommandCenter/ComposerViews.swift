// ComposerViews.swift
// Studio.92 — CommandCenter
//
// Command surface: policy strip, composer dock, text input, mentions, reference pills.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommandPolicyStrip: View {

    let runner: PipelineRunner
    @ObservedObject private var accessPreferences = CommandAccessPreferenceStore.shared

    private var activePolicy: CommandRuntimePolicy {
        accessPreferences.snapshot
    }

    private var policyNote: String {
        if runner.isRunning {
            return "Applies to next run."
        }
        if activePolicy.accessScope == .readOnly {
            return "Writes and terminal commands are blocked."
        }
        switch activePolicy.approvalMode {
        case .alwaysAsk:
            return "Every write will pause for approval."
        case .askOnRiskyActions:
            return "Risky actions pause for approval."
        case .neverAsk:
            return activePolicy.allowsMachineWideAccess
                ? "Full machine access is on."
                : "All workspace tools enabled."
        }
    }

    var body: some View {
        HStack(spacing: StudioSpacing.md) {
            // Access scope
            Menu {
                ForEach(CommandAccessScope.allCases) { scope in
                    Button {
                        accessPreferences.accessScope = scope
                    } label: {
                        Label(scope.displayName, systemImage: scope == accessPreferences.accessScope ? "checkmark" : scope.symbolName)
                    }
                }
            } label: {
                commandPolicyChip(
                    icon: activePolicy.accessScope.symbolName,
                    title: activePolicy.accessScope.shortLabel,
                    accentColor: activePolicy.accessScope == .fullMacAccess ? Color(hex: "#D4F000") : nil
                )
            }
            .menuStyle(.borderlessButton)

            // Approval mode
            Menu {
                ForEach(CommandApprovalMode.allCases) { mode in
                    Button {
                        accessPreferences.approvalMode = mode
                    } label: {
                        Label(mode.displayName, systemImage: mode == accessPreferences.approvalMode ? "checkmark" : mode.symbolName)
                    }
                }
            } label: {
                commandPolicyChip(
                    icon: activePolicy.approvalMode.symbolName,
                    title: activePolicy.approvalMode.displayName,
                    accentColor: activePolicy.approvalMode == .neverAsk ? StudioAccentColor.primary : nil
                )
            }
            .menuStyle(.borderlessButton)

            Text(policyNote)
                .font(StudioTypography.dataMicro)
                .foregroundStyle(StudioTextColorDark.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
    }

    @ViewBuilder
    private func commandPolicyChip(icon: String, title: String, accentColor: Color? = nil) -> some View {
        let tint = accentColor ?? StudioTextColorDark.primary
        let isHighlighted = accentColor != nil
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: icon)
                .font(StudioTypography.microSemibold)
            Text(title)
                .font(StudioTypography.dataMicroSemibold)
            Image(systemName: "chevron.down")
                .font(StudioTypography.badgeSmallSemibold)
                .foregroundStyle(isHighlighted ? tint.opacity(0.55) : StudioTextColorDark.tertiary)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(isHighlighted ? tint.opacity(0.10) : StudioSurfaceElevated.level2)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isHighlighted ? tint.opacity(0.22) : StudioSeparator.subtle)
        )
    }
}

struct MinimalComposerDock: View {

    @Binding var goalText: String
    @Binding var attachments: [ChatAttachment]
    let runner: PipelineRunner
    let onSubmit: () -> Void
    var isGated: Bool = false
    var isIndexing: Bool = false

    @State private var isFocused = false
    @State private var isImporterPresented = false
    @State private var measuredInputHeight: CGFloat = CommandSurfaceMetrics.inputMinHeight
    @State private var textFadeOpacity: Double = 1.0
    @State private var isSubmitHovered = false
    @State private var isDropTargeted = false

    /// Recovery state: brief visual handoff after pipeline completes
    @State private var isRecovering = false
    /// Delays placeholder re-appearance after completion
    @State private var showPlaceholder = true
    /// User typed a new goal while pipeline was running — auto-submit when done
    @State private var isQueued = false
    /// Shows "Take over" prompt when user clicks into command bar during a run
    @State private var showTakeOverPrompt = false
    /// Tracks the recovery animation task so it can be cancelled on disappear
    @State private var pendingRecoveryTask: Task<Void, Never>?

    /// Terminal border flash: true during the 0.3s flash + 1.5s linger after a failure
    @State private var terminalFailureCooldown = false
    @State private var terminalFailureCooldownTask: Task<Void, Never>?

    /// Multimodal preset selection
    @State private var selectedPreset: MultimodalPreset?
    /// Structured extractor schema selection
    @State private var selectedExtractor: ExtractorSchema?

    /// @ mention: current in-progress query and results
    @State private var mentionQuery: String? = nil
    @State private var mentionResults: [WorkspaceFileResult] = []
    @State private var mentionSearchTask: Task<Void, Never>? = nil

    @AppStorage("packageRoot") private var storedPackageRoot = ""

    private var trimmedGoalText: String {
        goalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedGoalText.isEmpty || !attachments.isEmpty
    }

    private var commandSurfaceTextColor: Color {
        StudioTextColorDark.primary
    }

    private var commandPlaceholderColor: Color {
        StudioTextColorDark.tertiary
    }

    private var hasText: Bool {
        !trimmedGoalText.isEmpty
    }

    private var commandButtonFill: Color {
        StudioTextColorDark.primary.opacity(runner.isRunning ? 0.14 : 0.10)
    }

    private var focusedLiftOpacity: Double {
        isFocused ? 0.03 : 0.0
    }

    private var submitLabel: String {
        if runner.isCancelling {
            return "Stopping"
        }
        if runner.isRunning {
            if canSubmit && !isQueued {
                return "Queue"
            }
            return "Stop"
        }
        return "Send"
    }

    private func submitOrCancel() {
        if runner.isCancelling {
            return
        }

        if runner.isRunning {
            // If user has typed new text, queue it for auto-submit after completion
            if canSubmit && !isQueued {
                withAnimation(StudioMotion.softFade) {
                    isQueued = true
                }
                return
            }
            // Otherwise cancel (or cancel even if queued — user hits stop twice)
            isQueued = false
            Task {
                StudioFeedback.cancel()
                await runner.cancel()
            }
        } else if canSubmit {
            isQueued = false
            StudioFeedback.send()
            // Fade the text out, then submit — composer snaps back to zero-state gracefully.
            withAnimation(.easeOut(duration: 0.15)) {
                textFadeOpacity = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                onSubmit()
                selectedPreset = nil
                selectedExtractor = nil
                // Brief pause for height to collapse, then restore opacity for next input.
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(StudioMotion.softFade) {
                    textFadeOpacity = 1.0
                }
            }
        }
    }

    @State private var thinkingPulse = false

    /// Freeze pulse+shimmer the instant cancel is pressed.
    private var effectivePulse: Bool {
        runner.isCancelling ? false : thinkingPulse
    }

    @ViewBuilder
    private var commandBarBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: StudioRadius.hero, style: .continuous)
                .fill(.regularMaterial)

            // Edge lighting on sides and bottom only; the top is covered by the context bar
            RoundedRectangle(cornerRadius: StudioRadius.hero, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1.0)

            // Status and focus strokes — precision over glow
            RoundedRectangle(cornerRadius: StudioRadius.hero, style: .continuous)
                .stroke(
                    terminalFailureCooldown
                        ? Color(hex: "#FF7373").opacity(0.72)
                        : (runner.isRunning && !runner.isCancelling
                            ? StudioSeparator.subtle.opacity(effectivePulse ? 1.0 : 0.4)
                            : (isFocused ? StudioAccentColor.primary.opacity(0.30) : Color.clear)),
                    lineWidth: 1
                )
                .shadow(
                    color: terminalFailureCooldown
                        ? Color(hex: "#FF7373").opacity(0.25)
                        : (isFocused ? StudioAccentColor.primary.opacity(0.15) : .clear),
                    radius: 6, x: 0, y: 0
                )
        }
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        .allowsHitTesting(false)
        .animation(StudioMotion.softFade, value: isFocused)
        .animation(StudioMotion.statusPulse, value: effectivePulse)
        .animation(StudioMotion.fastSpring, value: runner.isCancelling)
        .animation(.easeOut(duration: 0.15), value: terminalFailureCooldown)
        .onChange(of: runner.isRunning) { _, running in
            thinkingPulse = running
        }
        .onChange(of: runner.isCancelling) { _, cancelling in
            if cancelling { thinkingPulse = false }
        }
        .onChange(of: runner.stage) { _, newStage in
            if newStage == .failed {
                terminalFailureCooldownTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) {
                    terminalFailureCooldown = true
                }
                terminalFailureCooldownTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1800))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.4)) {
                        terminalFailureCooldown = false
                    }
                }
            }
        }
    }

    private var commandBarInternalHairline: some View {
        Color.clear.frame(height: 1)
    }

    private var commandBarTopDivider: some View {
        // kept for compatibility; shadows delegated to hairline now
        EmptyView()
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: StudioRadius.hero - 2, style: .continuous)
            .stroke(
                isDropTargeted ? StudioAccentColor.primary : Color.clear,
                lineWidth: 1.5
            )
            .shadow(color: isDropTargeted ? StudioAccentColor.primary.opacity(0.50) : .clear, radius: 10)
            .animation(StudioMotion.softFade, value: isDropTargeted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Internal hairline — the visible seam between context bar and composer body.
            // The external borders are intentionally continuous; only the inside shows the join.
            commandBarInternalHairline

            VStack(alignment: .leading, spacing: StudioSpacing.lg) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StudioSpacing.md) {
                        ForEach(attachments) { attachment in
                            referencePill(attachment)
                        }
                    }
                }

                // Multimodal preset picker — appears when an image is attached
                if attachments.contains(where: { $0.isImage }) {
                    multimodalPresetRow
                }
            }

            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                // Take-over prompt — appears when user clicks into bar during a run
                if showTakeOverPrompt && runner.isRunning && !runner.isCancelling {
                    HStack(spacing: StudioSpacing.md) {
                        Text("Continue manually?")
                            .font(StudioTypography.captionMedium)
                            .foregroundStyle(StudioTextColorDark.tertiary)
                        Button {
                            showTakeOverPrompt = false
                            Task { await runner.cancel() }
                        } label: {
                            Text("Take over")
                                .font(StudioTypography.captionSemibold)
                                .foregroundStyle(StudioAccentColor.primary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            withAnimation(StudioMotion.softFade) {
                                showTakeOverPrompt = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(StudioTypography.badgeSmallSemibold)
                                .foregroundStyle(StudioTextColorDark.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, StudioSpacing.xs)
                    .transition(.studioCollapse)
                }

                ZStack(alignment: .topLeading) {
                    if goalText.isEmpty && showPlaceholder {
                        Text(runner.isRunning ? "" : (isIndexing ? "Indexing workspace…" : "Ask Studio.92"))
                            .font(isIndexing ? StudioTypography.footnoteSemibold.monospaced() : StudioTypography.subheadline)
                            .foregroundStyle(commandPlaceholderColor)
                            .padding(.top, StudioSpacing.xs)
                            .allowsHitTesting(false)
                    }

                    ComposerTextView(
                        text: $goalText,
                        measuredHeight: $measuredInputHeight,
                        isFocused: $isFocused,
                        isEnabled: !runner.isCancelling,
                        canSubmit: canSubmit,
                        isRunning: runner.isRunning,
                        textColor: hasText ? .white : NSColor(white: 1.0, alpha: 0.5),
                        insertionPointColor: .white,
                        onSubmit: submitOrCancel
                    )
                    .frame(height: measuredInputHeight)
                    .animation(StudioMotion.panelSpring, value: measuredInputHeight)
                    .tint(StudioTextColorDark.primary)
                }
                .opacity((runner.isRunning && !hasText ? 0.45 : 1.0) * textFadeOpacity)
                .animation(StudioMotion.emphasisFade, value: runner.isRunning)

                HStack(alignment: .center, spacing: StudioSpacing.xl) {
                    // Attach files — same 30×30 bare frame as mic
                    Button {
                        performLightHaptic()
                        isImporterPresented = true
                    } label: {
                        Image(systemName: StudioSymbol.resolve("plus.rectangle.on.folder", "paperclip"))
                            .font(.system(size: 13, weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(StudioTextColorDark.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(CommandAccessoryIconButtonStyle())
                    .help("Attach files")
                    .disabled(runner.isCancelling)

                    Spacer(minLength: 0)

                    // Queued indicator
                    if isQueued && runner.isRunning {
                        Text("Queued")
                            .font(StudioTypography.microMedium)
                            .foregroundStyle(StudioAccentColor.primary.opacity(0.8))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    // Character count (appears after 50 chars)
                    if goalText.count > 50 {
                        Text("\(goalText.count)")
                            .font(StudioTypography.dataMicro)
                            .foregroundStyle(StudioTextColorDark.tertiary.opacity(0.6))
                            .contentTransition(.numericText())
                            .animation(StudioMotion.fastSpring, value: goalText.count)
                    }

                    // Microphone input — same bare 30×30 frame as folder
                    Button(action: {}) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(StudioTextColorDark.tertiary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(CommandAccessoryIconButtonStyle())
                    .help("Voice input")
                    .disabled(runner.isCancelling)

                    // Submit / Stop / Queue — circle appears only when active
                    Button(action: submitOrCancel) {
                        ZStack {
                            if runner.isRunning && !runner.isCancelling && !canSubmit {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.55)
                                    .tint(StudioTextColorDark.primary.opacity(0.85))
                            } else {
                                Image(systemName: submitSymbolName)
                                    .font(.system(size: 13, weight: .regular))
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(canSubmit || runner.isRunning ? StudioTextColorDark.primary : StudioTextColorDark.tertiary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(commandButtonFill)
                                .opacity(canSubmit || runner.isRunning ? 1.0 : 0)
                        )
                        .scaleEffect(runner.isRunning ? 1.0 : (canSubmit ? 1.0 : 0.94))
                        .animation(StudioMotion.fastSpring, value: hasText)
                        .animation(StudioMotion.softFade, value: runner.isRunning)
                        .overlay {
                            if isSubmitHovered && !runner.isRunning {
                                Text("⌘↩")
                                    .font(StudioTypography.badgeSmallMono)
                                    .foregroundStyle(StudioTextColorDark.tertiary)
                                    .offset(y: 20)
                                    .transition(.opacity.animation(StudioMotion.softFade))
                            }
                        }
                    }
                    .buttonStyle(CommandPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!runner.isRunning && !canSubmit)
                    .help(runner.isRunning ? "Stop (⌘↩)" : "Send (⌘↩)")
                    .onHover { hovering in
                        isSubmitHovered = hovering
                    }
                }
            }
            .padding(.horizontal, StudioSpacing.xxl)
            .padding(.vertical, StudioSpacing.xl)
            .background(
                Color.black.opacity(0.001)
                    .onTapGesture {
                        if !runner.isCancelling {
                            isFocused = true
                        }
                    }
            )
            .background(commandBarBackground)
            .overlay(commandBarTopDivider, alignment: .top)
            .scaleEffect(isRecovering ? StudioMotion.commandBarTuckScale : (runner.isRunning ? StudioMotion.commandBarTuckScale : (isFocused ? StudioMotion.commandBarFocusScale : 1.0)))
            .animation(StudioMotion.fastSpring, value: isFocused)
            .animation(StudioMotion.standardSpring, value: runner.isRunning)
            .animation(StudioMotion.fastSpring, value: isRecovering)
            .overlay(dropTargetOverlay)
            .onDrop(of: [.fileURL, .item], isTargeted: $isDropTargeted) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                        guard let data = data as? Data,
                              let urlString = String(data: data, encoding: .utf8),
                              let url = URL(string: urlString) else { return }
                        Task { @MainActor in
                            let normalized = url.standardizedFileURL
                            guard normalized.isFileURL else { return }
                            let attachment = ChatAttachment(url: normalized, displayName: normalized.lastPathComponent)
                            if !self.attachments.contains(where: { $0.url == attachment.url }) {
                                self.attachments.append(attachment)
                            }
                        }
                    }
                }
                return true
            }
            } // end inner VStack(spacing: StudioSpacing.lg)
        } // end outer VStack(spacing: 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if let query = mentionQuery, !mentionResults.isEmpty {
                MentionSuggestionsView(
                    results: mentionResults,
                    query: query,
                    onSelect: handleMentionSelect
                )
                .alignmentGuide(.top) { d in d[.bottom] + 8 }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            appendAttachments(from: urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusStudioComposer)) { _ in
            isFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .prefillStudioComposer)) { notification in
            if let text = notification.userInfo?["text"] as? String {
                goalText = text
            }
            isFocused = true
        }
        .onDisappear {
            pendingRecoveryTask?.cancel()
            pendingRecoveryTask = nil
        }
        .onChange(of: goalText) { _, newValue in
            // Detect @query at end of text — open file mention popover
            if let range = newValue.range(of: #"@(\S*)$"#, options: .regularExpression) {
                let match = String(newValue[range])
                let query = String(match.dropFirst())
                if mentionQuery != query {
                    mentionQuery = query
                    fetchMentionResults(query: query)
                }
            } else if mentionQuery != nil {
                closeMention()
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused && runner.isRunning && !runner.isCancelling && goalText.isEmpty {
                withAnimation(StudioMotion.softFade) {
                    showTakeOverPrompt = true
                }
            }
        }
        .onChange(of: runner.isRunning) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                // Pipeline just finished — dismiss take-over prompt and trigger recovery
                showTakeOverPrompt = false
                // Pipeline just finished — trigger recovery bounce
                let shouldAutoSubmit = isQueued && canSubmit
                isQueued = false
                showPlaceholder = false
                isRecovering = true
                pendingRecoveryTask?.cancel()
                pendingRecoveryTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    isRecovering = false
                    if shouldAutoSubmit {
                        // Auto-submit the queued goal
                        onSubmit()
                    } else {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        withAnimation(StudioMotion.softFade) {
                            showPlaceholder = true
                        }
                    }
                }
            } else if isRunning {
                showPlaceholder = true
            }
        }
        .opacity(isGated ? 0.4 : 1.0)
        .allowsHitTesting(!isGated)
        .animation(StudioMotion.softFade, value: isGated)
    }

    private func referencePill(_ attachment: ChatAttachment) -> some View {
        ReferencePillTag(
            attachment: attachment,
            onRemove: { attachments.removeAll { $0.id == attachment.id } }
        )
    }

    // MARK: - @ Mention

    private var resolvedWorkspaceURL: URL {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return URL(fileURLWithPath: storedPackageRoot)
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func fetchMentionResults(query: String) {
        mentionSearchTask?.cancel()
        let root = resolvedWorkspaceURL
        mentionSearchTask = Task {
            let results = await WorkspaceFileFinder.findFiles(in: root, query: query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(StudioMotion.fastSpring) {
                    mentionResults = results
                }
            }
        }
    }

    private func closeMention() {
        mentionQuery = nil
        mentionResults = []
        mentionSearchTask?.cancel()
        mentionSearchTask = nil
    }

    private func handleMentionSelect(_ result: WorkspaceFileResult) {
        // Strip @query suffix from goalText
        if let range = goalText.range(of: #"@(\S*)$"#, options: .regularExpression) {
            goalText.removeSubrange(range)
        }
        let attachment = ChatAttachment(url: result.url, displayName: result.name)
        if !attachments.contains(where: { $0.url == attachment.url }) {
            withAnimation(StudioMotion.fastSpring) {
                attachments.append(attachment)
            }
        }
        closeMention()
    }

    private var submitSymbolName: String {
        if runner.isCancelling {
            return "stop.circle.fill"
        }
        if runner.isRunning {
            // If user has typed new text, show send icon to queue; otherwise stop
            if canSubmit && !isQueued {
                return StudioSymbol.resolve("arrow.up.message.fill", "paperplane.circle.fill", "paperplane.fill")
            }
            return "stop.circle.fill"
        }
        return StudioSymbol.resolve("arrow.up.message.fill", "paperplane.circle.fill", "paperplane.fill")
    }

    @MainActor
    private func appendAttachments(from urls: [URL]) {
        let additions = urls.compactMap { url -> ChatAttachment? in
            let normalized = url.standardizedFileURL
            guard normalized.isFileURL else { return nil }
            return ChatAttachment(url: normalized, displayName: normalized.lastPathComponent)
        }

        if let replacementImage = additions.last(where: { $0.isImage }) {
            attachments.removeAll(where: { $0.isImage })
            var img = replacementImage
            img.multimodalPreset = selectedPreset
            img.extractorSchema = selectedExtractor
            attachments.append(img)
        }

        for attachment in additions where !attachments.contains(where: { $0.url == attachment.url }) {
            guard !attachment.isImage else { continue }
            attachments.append(attachment)
        }
    }

    // MARK: - Multimodal Preset Row

    private var multimodalPresetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudioSpacing.md) {
                ForEach(MultimodalPreset.allCases) { preset in
                    presetChip(preset)
                }

                if selectedPreset != nil {
                    Divider()
                        .frame(height: 16)
                        .opacity(0.3)

                    // Extractor schema picker
                    Menu {
                        Button("None") {
                            selectedExtractor = nil
                            syncPresetToAttachments()
                        }
                        ForEach(ExtractorSchema.allCases) { schema in
                            Button(schema.displayName) {
                                selectedExtractor = schema
                                syncPresetToAttachments()
                            }
                        }
                    } label: {
                        HStack(spacing: StudioSpacing.xs) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(StudioTypography.microSemibold)
                            Text(selectedExtractor?.displayName ?? "Extractor")
                                .font(StudioTypography.microMedium)
                        }
                        .foregroundStyle(
                            selectedExtractor != nil
                                ? StudioAccentColor.primary
                                : StudioTextColorDark.tertiary
                        )
                        .padding(.horizontal, StudioSpacing.lg)
                        .padding(.vertical, StudioSpacing.xs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    selectedExtractor != nil
                                        ? StudioAccentColor.primary.opacity(0.15)
                                        : StudioSurfaceGrouped.primary.opacity(0.3)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func presetChip(_ preset: MultimodalPreset) -> some View {
        let isSelected = selectedPreset == preset
        return Button {
            withAnimation(StudioMotion.fastSpring) {
                if isSelected {
                    selectedPreset = nil
                    selectedExtractor = nil
                } else {
                    selectedPreset = preset
                    // Auto-select OCR extractor preset
                    if preset == .ocrTranscribe || preset == .diagramReasoning || preset == .deepInspect {
                        // Keep extractor if compatible
                    } else {
                        selectedExtractor = nil
                    }
                }
                syncPresetToAttachments()
            }
        } label: {
            HStack(spacing: StudioSpacing.xs) {
                Image(systemName: preset.iconName)
                    .font(StudioTypography.microSemibold)
                Text(preset.displayName)
                    .font(StudioTypography.microMedium)
            }
            .foregroundStyle(isSelected ? StudioAccentColor.primary : StudioTextColorDark.tertiary)
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, StudioSpacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? StudioAccentColor.primary.opacity(0.15) : StudioSurfaceGrouped.primary.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
        .help(preset.hint)
    }

    private func syncPresetToAttachments() {
        for i in attachments.indices where attachments[i].isImage {
            attachments[i].multimodalPreset = selectedPreset
            attachments[i].extractorSchema = selectedExtractor
        }
    }

    private func performLightHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
}

private enum CommandSurfaceMetrics {
    static let inputMinHeight: CGFloat = 28
    /// ~10 lines at 16.5pt system font. Beyond this the text area scrolls internally.
    static let inputMaxHeight: CGFloat = 200
}

private struct ComposerTextView: NSViewRepresentable {

    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool

    let isEnabled: Bool
    let canSubmit: Bool
    let isRunning: Bool
    let textColor: NSColor
    let insertionPointColor: NSColor
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textView = CommandTextView()
        textView.commandDelegate = context.coordinator
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.handleFocusChange(focused)
        }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindPanel = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: CommandSurfaceMetrics.inputMinHeight)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 16.5, weight: .regular)
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        textView.focusRingType = .none
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.recalculateHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandTextView else { return }

        context.coordinator.parent = self
        textView.textColor = textColor
        textView.insertionPointColor = insertionPointColor
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.commandDelegate = context.coordinator

        if context.coordinator.isUpdatingFromAppKit == false && textView.string != text {
            context.coordinator.isUpdatingFromAppKit = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.count, length: 0))
            context.coordinator.isUpdatingFromAppKit = false
        }

        context.coordinator.recalculateHeight(for: textView)

        // Only gain focus programmatically. Focus loss is handled by AppKit's
        // responder chain via CommandTextView.resignFirstResponder.
        guard let window = scrollView.window else { return }
        if isFocused, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: ComposerTextView
        var isUpdatingFromAppKit = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        /// Syncs the SwiftUI binding immediately when first-responder status
        /// changes, closing the gap between click and textDidBeginEditing.
        func handleFocusChange(_ focused: Bool) {
            guard parent.isFocused != focused else { return }
            parent.isFocused = focused
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard parent.isFocused == false else { return }
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard parent.isFocused else { return }
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommandTextView else { return }
            if isUpdatingFromAppKit == false {
                parent.text = textView.string
            }
            recalculateHeight(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertLineBreak(_:)) else {
                return false
            }

            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.command) {
                return false
            }
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                return false
            }

            if parent.isRunning || parent.canSubmit {
                parent.onSubmit()
            }
            return true
        }

        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let targetHeight = min(
                max(usedRect.height + (textView.textContainerInset.height * 2), CommandSurfaceMetrics.inputMinHeight),
                CommandSurfaceMetrics.inputMaxHeight
            )

            if abs(parent.measuredHeight - targetHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.measuredHeight = targetHeight
                }
            }
        }
    }
}

private final class CommandTextView: NSTextView {

    weak var commandDelegate: NSTextViewDelegate?
    /// Called synchronously when first-responder status changes so the
    /// SwiftUI binding stays in sync before the next `updateNSView` pass.
    var onFocusChange: ((Bool) -> Void)?

    override var focusRingMaskBounds: NSRect {
        .zero
    }

    override func drawFocusRingMask() {}

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func doCommand(by selector: Selector) {
        if commandDelegate?.textView?(self, doCommandBy: selector) == true {
            return
        }
        super.doCommand(by: selector)
    }
}

struct ComposerModePill: View {

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(StudioTypography.microSemibold)
                .contentTransition(.symbolEffect(.replace))

            Text("Full Send")
                .font(StudioTypography.footnoteSemibold)
                .contentTransition(.numericText())
        }
        .foregroundStyle(StudioTextColorDark.primary)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(StudioSurfaceGrouped.primary.opacity(0.5))
        )
    }
}

private struct CommandAccessoryIconButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? StudioMotion.pressScale : 1.0)
            .opacity(configuration.isPressed ? StudioMotion.pressMinOpacity : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

private struct CommandPrimaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? StudioMotion.pressPrimaryScale : 1.0)
            .opacity(configuration.isPressed ? StudioMotion.pressMinOpacity : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

// MARK: - Workspace File Mention

private struct WorkspaceFileResult: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let ext: String
    let modDate: Date

    var sfSymbol: String {
        switch ext {
        case "swift":                  return "doc.text"
        case "py":                     return "doc.plaintext"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json":                   return "curly.braces"
        case "md":                     return "doc.richtext"
        case "yaml", "yml", "toml":    return "list.bullet.rectangle"
        case "txt":                    return "doc.plaintext"
        case "sh", "bash":             return "terminal"
        case "html":                   return "globe"
        case "css":                    return "paintbrush.pointed"
        case "xcodeproj", "pbxproj":   return "hammer"
        default:                       return "doc"
        }
    }
}

private enum WorkspaceFileFinder {

    private static let allowedExtensions: Set<String> = [
        "swift", "py", "ts", "tsx", "js", "jsx", "json", "md", "yaml", "yml",
        "toml", "txt", "sh", "bash", "rb", "go", "rs", "c", "cpp", "h",
        "html", "css", "pbxproj", "plist", "xcconfig"
    ]

    private static let skipDirectories: Set<String> = [
        ".git", "DerivedData", "node_modules", ".build", ".studio92", ".codex",
        "xcuserdata", "Pods", "__pycache__", ".cache"
    ]

    static func findFiles(in root: URL, query: String) async -> [WorkspaceFileResult] {
        await Task.detached(priority: .userInitiated) {
            var results: [WorkspaceFileResult] = []
            let fm = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { return [] }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: resourceKeys)
                if values?.isDirectory == true {
                    if skipDirectories.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let ext = url.pathExtension.lowercased()
                guard allowedExtensions.contains(ext) else { continue }

                let name = url.lastPathComponent
                guard query.isEmpty || fuzzyMatch(name, query: query) else { continue }

                let modDate = values?.contentModificationDate ?? .distantPast
                results.append(WorkspaceFileResult(url: url, name: name, ext: ext, modDate: modDate))
            }

            let lower = query.lowercased()
            return Array(
                results
                    .sorted { a, b in
                        let aP = a.name.lowercased().hasPrefix(lower)
                        let bP = b.name.lowercased().hasPrefix(lower)
                        if aP != bP { return aP }
                        return a.modDate > b.modDate
                    }
                    .prefix(10)
            )
        }.value
    }

    private static func fuzzyMatch(_ string: String, query: String) -> Bool {
        var haystack = string.lowercased()[...]
        for char in query.lowercased() {
            guard let idx = haystack.firstIndex(of: char) else { return false }
            haystack = haystack[haystack.index(after: idx)...]
        }
        return true
    }
}

// MARK: - Reference Pill (Composer)

private struct ReferencePillTag: View {

    let attachment: ChatAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

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
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: fileSymbol)
                .font(.system(size: 10, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.white.opacity(0.32))

            Text(attachment.displayName)
                .font(StudioTypography.captionMedium)
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .layoutPriority(1)

            // Electric Cyan loaded indicator
            Circle()
                .fill(StudioAccentColor.primary.opacity(0.75))
                .frame(width: 4, height: 4)

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, StudioSpacing.md)
        .padding(.vertical, StudioSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(Color(hex: "#14181D"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .animation(StudioMotion.fastSpring, value: isHovering)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Mention Suggestions Popover

private struct MentionSuggestionsView: View {

    let results: [WorkspaceFileResult]
    let query: String
    let onSelect: (WorkspaceFileResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: "at")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioAccentColor.primary.opacity(0.8))
                Text(query.isEmpty ? "Recent files" : "@ \(query)")
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, StudioSpacing.section)
            .padding(.vertical, StudioSpacing.md)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            if results.isEmpty {
                Text("No matching files")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(Color.white.opacity(0.28))
                    .padding(StudioSpacing.section)
            } else {
                VStack(spacing: 0) {
                    ForEach(results.prefix(10)) { result in
                        MentionRow(result: result, onSelect: onSelect)
                    }
                }
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.40), radius: 24, x: 0, y: -6)
    }
}

private struct MentionRow: View {

    let result: WorkspaceFileResult
    let onSelect: (WorkspaceFileResult) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect(result)
        } label: {
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: result.sfSymbol)
                    .font(.system(size: 11, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white.opacity(isHovering ? 0.70 : 0.32))
                    .frame(width: 16, alignment: .center)

                Text(result.name)
                    .font(StudioTypography.footnoteMedium)
                    .foregroundStyle(Color.white.opacity(isHovering ? 1.0 : 0.78))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                Text(result.ext.uppercased())
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(Color.white.opacity(0.22))
            }
            .padding(.horizontal, StudioSpacing.section)
            .padding(.vertical, StudioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.sm, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hoverEase, value: isHovering)
    }
}
