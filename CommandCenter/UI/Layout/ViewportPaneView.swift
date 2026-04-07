import AppKit
import SwiftUI

struct ViewportPaneView: View {

    let model: ViewportStreamModel
    let ambientContext: AmbientEditorContextCoordinator
    let previewService: SimulatorPreviewService
    var onHide: (() -> Void)?
    var onDiagnoseError: (() -> Void)?
    var onAuthorizeApproval: (() -> Void)?
    var onRejectApproval: (() -> Void)?
    var onExecuteRevert: ((TemporalRevertModel) -> Void)?
    var onCancelRevert: (() -> Void)?
    var isIndexing: Bool = false

    @State private var displayedImage: NSImage?
    @State private var displayedImagePath: String?
    @State private var imageLoadTask: Task<Void, Never>?

    /// Tracks whether we've shown the first real content for the arrival animation.
    @State private var hasReceivedContent = false
    @State private var contentArrivalScale: CGFloat = 0.998
    @State private var contentArrivalOpacity: Double = 0.92

    var body: some View {
        VStack(spacing: 0) {
            header
            executionSurface
                .animation(model.transitionAnimation(to: model.phase), value: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioSurface(.viewport)
        .onAppear {
            syncViewportImage(for: model.imagePath)
        }
        .onDisappear {
            imageLoadTask?.cancel()
        }
        .onChange(of: model.imagePath) { _, newPath in
            syncViewportImage(for: newPath)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: StudioSpacing.xl) {
            Text(model.lockedTitle)
                .font(StudioTypography.subheadlineSemibold)
                .foregroundStyle(StudioTextColorDark.primary)
                .contentTransition(.opacity)
                .animation(StudioMotion.softFade, value: model.lockedTitle)

            if !model.statusLabel.isEmpty {
                Text(model.statusLabel)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColorDark.tertiary)
                    .contentTransition(.opacity)
                    .animation(StudioMotion.softFade, value: model.statusLabel)
            }

            Spacer(minLength: 0)

            deviceMenu

            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(StudioTypography.microSemibold)
                        .foregroundStyle(StudioTextColorDark.tertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Hide Viewport")
            }
        }
        .padding(.horizontal, StudioSpacing.section)
        .padding(.vertical, StudioSpacing.lg)
    }

    private var deviceMenu: some View {
        Menu {
            if previewService.availableDevices.isEmpty {
                Text("No iOS Simulators")
            } else {
                ForEach(previewService.availableDevices) { device in
                    Button {
                        previewService.selectDevice(udid: device.udid)
                    } label: {
                        Text(device.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: StudioSpacing.sm) {
                Text(previewService.selectedDeviceName)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColorDark.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(StudioTypography.badge)
                    .foregroundStyle(StudioTextColorDark.tertiary)
            }
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, StudioSpacing.sm)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(previewService.hasAvailableDevices == false)
    }

    private var executionSurface: some View {
        Group {
            switch model.content {
            case .diffPreview(let diffModel):
                viewportDiffView(diffModel)
            case .errorCard(let errorModel):
                BuildErrorCard(errorModel: errorModel, onDiagnose: onDiagnoseError)
            case .approvalGate(let approvalModel):
                ApprovalGateCard(approvalModel: approvalModel, onAuthorize: onAuthorizeApproval, onReject: onRejectApproval)
            case .temporalRevert(let revertModel):
                TemporalRevertCard(
                    model: revertModel,
                    onRevert: onExecuteRevert,
                    onCancel: onCancelRevert
                )
            case .filePreview(let fileModel):
                viewportFileView(fileModel)
            case .planDocument(let planModel):
                ViewportPlanDocumentView(plan: planModel)
            case .simulatorScreenshot, .artifactImage:
                if let displayedImage {
                    renderedFrameView(displayedImage)
                } else if model.phase == .intent {
                    bootingView
                } else {
                    idleView
                }
            case .simulatorBooting:
                bootingView
            case .none:
                switch model.phase {
                case .error:
                    errorView
                default:
                    idleView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioSurfaceElevated.level1)
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
        .padding(StudioSpacing.xl)
        .contentTransition(.opacity)
        .scaleEffect(contentArrivalScale)
        .opacity(contentArrivalOpacity)
        .onChange(of: model.content) { oldContent, newContent in
            let wasEmpty = (oldContent == .none)
            let isReal = (newContent != .none)
            if wasEmpty && isReal && !hasReceivedContent {
                hasReceivedContent = true
                contentArrivalScale = 0.998
                contentArrivalOpacity = 0.92
                withAnimation(StudioMotion.softFade) {
                    contentArrivalScale = 1.0
                    contentArrivalOpacity = 1.0
                }
            }

            if case .filePreview = newContent {
                // Keep the existing selection for the active file preview.
            } else {
                ambientContext.clearSelection()
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .idle {
                hasReceivedContent = false
                contentArrivalScale = 1.0
                contentArrivalOpacity = 1.0
            }
        }
    }

    private var errorView: some View {
        ContentUnavailableView(
            "Error",
            systemImage: "exclamationmark.triangle",
            description: Text(model.errorMessage ?? "An unknown error occurred.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func renderedFrameView(_ image: NSImage) -> some View {
        GeometryReader { geometry in
            let aspectRatio = previewService.deviceAspectRatio ?? fallbackAspectRatio(for: image)
            let isPhone = aspectRatio < 0.7
            let deviceCornerRadius: CGFloat = isPhone ? 44 : 20

            // Cap the device to a smaller portion of the viewport
            let maxDeviceWidth = geometry.size.width * 0.52
            let maxDeviceHeight = geometry.size.height * 0.62
            let fittedSize = fitSize(
                aspectRatio: aspectRatio,
                maxWidth: maxDeviceWidth,
                maxHeight: maxDeviceHeight
            )

            ZStack {
                Color.clear

                RoundedRectangle(cornerRadius: deviceCornerRadius + 4, style: .continuous)
                    .fill(StudioTextColor.primary)
                    .frame(width: fittedSize.width + 6, height: fittedSize.height + 6)
                    .studioShadow(StudioDepth.floating)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(aspectRatio, contentMode: .fill)
                            .frame(width: fittedSize.width, height: fittedSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: deviceCornerRadius, style: .continuous))
                            .overlay {
                                // BBox overlays from multimodal "Locate Region"
                                if !model.bboxOverlays.isEmpty {
                                    ForEach(Array(model.bboxOverlays.enumerated()), id: \.offset) { _, bbox in
                                        let rect = bbox.fractionalRect
                                        Rectangle()
                                            .strokeBorder(StudioAccentColor.primary, lineWidth: 2)
                                            .background(StudioAccentColor.primary.opacity(0.12))
                                            .frame(
                                                width: rect.width * fittedSize.width,
                                                height: rect.height * fittedSize.height
                                            )
                                            .position(
                                                x: (rect.midX) * fittedSize.width,
                                                y: (rect.midY) * fittedSize.height
                                            )
                                            .overlay(alignment: .topLeading) {
                                                if let label = bbox.label {
                                                    Text(label)
                                                        .font(StudioTypography.microSemibold)
                                                        .foregroundStyle(.white)
                                                        .padding(.horizontal, StudioSpacing.sm)
                                                        .padding(.vertical, 2)
                                                        .background(
                                                            Capsule(style: .continuous)
                                                                .fill(StudioAccentColor.primary)
                                                        )
                                                        .position(
                                                            x: rect.minX * fittedSize.width + 30,
                                                            y: rect.minY * fittedSize.height - 8
                                                        )
                                                }
                                            }
                                    }
                                }
                            }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fitSize(aspectRatio: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard aspectRatio > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let widthFromHeight = maxHeight * aspectRatio
        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        } else {
            return CGSize(width: maxWidth, height: maxWidth / aspectRatio)
        }
    }

    private var idleView: some View {
        VStack(spacing: StudioSpacing.xl) {
            if model.isPipelineActive {
                ProgressView()
                    .controlSize(.small)
                    .tint(StudioTextColorDark.secondary.opacity(0.5))
            } else {
                ViewportIdleCanvas(isIndexing: isIndexing)
            }

            VStack(spacing: StudioSpacing.xs) {
                Text(model.isPipelineActive ? "Preparing output…" : "No active output")
                    .font(StudioTypography.bodyMedium)
                    .foregroundStyle(StudioTextColorDark.secondary)
                    .contentTransition(.opacity)

                Text(model.isPipelineActive
                     ? (model.pipelineStageLabel.isEmpty ? "Working" : model.pipelineStageLabel)
                     : "Diffs, plans, and previews appear here")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColorDark.tertiary)
                    .contentTransition(.numericText())
            }
            .animation(StudioMotion.emphasisFade, value: model.isPipelineActive)
            .animation(StudioMotion.softFade, value: model.pipelineStageLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bootingView: some View {
        VStack(spacing: StudioSpacing.lg) {
            ProgressView()
                .controlSize(.small)
                .tint(StudioTextColorDark.secondary.opacity(0.74))

            Text("Starting simulator")
                .font(StudioTypography.bodyMedium)
                .foregroundStyle(StudioTextColorDark.secondary)

            Text(previewService.statusDetail)
                .font(StudioTypography.codeSmallMedium)
                .foregroundStyle(StudioTextColorDark.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func viewportDiffView(_ diffModel: ViewportDiffModel) -> some View {
        DiffDocumentCard(diffModel: diffModel, onApply: model.applyCurrentDiff)
    }

    private func viewportFileView(_ fileModel: ViewportFileModel) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: StudioSpacing.xl) {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text(fileModel.displayName)
                        .font(StudioTypography.headline)
                        .foregroundStyle(StudioTextColorDark.primary)

                    Text(fileModel.path)
                        .font(StudioTypography.codeSmallMedium)
                        .foregroundStyle(StudioTextColorDark.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let language = fileModel.language {
                    Text(language.uppercased())
                        .font(StudioTypography.dataMicroSemibold)
                        .foregroundStyle(StudioTextColorDark.secondary)
                }
            }
            .padding(.horizontal, StudioSpacing.sectionGap)
            .padding(.vertical, StudioSpacing.section)

            Group {
                switch fileModel.state {
                case .loading:
                    VStack(spacing: StudioSpacing.xl) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(StudioTextColorDark.secondary.opacity(0.78))

                        Text("Loading file preview")
                            .font(StudioTypography.dataCaption)
                            .foregroundStyle(StudioTextColorDark.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView(
                        "File Unavailable",
                        systemImage: "doc.badge.xmark",
                        description: Text(message)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready(let content):
                    AmbientContextCodePreview(
                        path: fileModel.path,
                        language: fileModel.language,
                        content: content,
                        ambientContext: ambientContext
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioSurface.viewport)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncViewportImage(for path: String?) {
        imageLoadTask?.cancel()

        guard let path,
              FileManager.default.fileExists(atPath: path) else {
            displayedImage = nil
            displayedImagePath = nil
            return
        }

        guard path != displayedImagePath else { return }

        imageLoadTask = Task {
            let loadedImage = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: path)
            }.value

            guard Task.isCancelled == false else { return }

            await MainActor.run {
                guard let loadedImage else { return }
                displayedImage = loadedImage
                displayedImagePath = path
            }
        }
    }

    private func fallbackAspectRatio(for image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return 0.5 }
        return image.size.width / image.size.height
    }
}

private struct AmbientContextCodePreview: NSViewRepresentable {

    let path: String
    let language: String?
    let content: String
    let ambientContext: AmbientEditorContextCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.applyContent(to: textView, parent: self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.applyContent(to: textView, parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: AmbientContextCodePreview
        private var lastIdentity: String?

        init(parent: AmbientContextCodePreview) {
            self.parent = parent
        }

        func applyContent(to textView: NSTextView, parent: AmbientContextCodePreview) {
            let identity = "\(parent.path)::\(parent.content.count)"
            if identity != lastIdentity {
                textView.textStorage?.setAttributedString(NSAttributedString(
                    CodeSyntaxHighlighter.highlight(
                        code: parent.content.isEmpty ? " " : parent.content,
                        language: parent.language
                    )
                ))
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                lastIdentity = identity
            }

            parent.ambientContext.notePresentedFile(
                path: parent.path,
                language: parent.language,
                isDirty: false,
                content: parent.content,
                openFiles: [
                    OpenFileContext(
                        path: parent.path,
                        language: parent.language,
                        isDirty: false,
                        lastFocusedAt: Date()
                    )
                ]
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.ambientContext.noteSelection(
                path: parent.path,
                content: parent.content,
                selection: textView.selectedRange(),
                language: parent.language,
                isDirty: false,
                openFiles: [
                    OpenFileContext(
                        path: parent.path,
                        language: parent.language,
                        isDirty: false,
                        lastFocusedAt: Date()
                    )
                ]
            )
        }
    }
}

// MARK: - Approval Gate Card

private struct ApprovalGateCard: View {

    let approvalModel: ViewportApprovalModel
    let onAuthorize: (() -> Void)?
    let onReject: (() -> Void)?

    @State private var cardVisible = false
    @State private var isExiting = false

    private static let cardSpring   = Animation.spring(response: 0.30, dampingFraction: 0.86)
    private static let cardExit     = Animation.easeOut(duration: 0.28)
    private let cardWidth: CGFloat  = 560
    private let warningAmber        = Color(hex: "#FFB340")

    var body: some View {
        ZStack {
            ViewportIdleCanvas()
                .opacity(cardVisible ? 0.10 : 0)
                .animation(isExiting ? ApprovalGateCard.cardExit : ApprovalGateCard.cardSpring, value: cardVisible)

            VStack(spacing: 0) {
                approvalCardHeader
                    .padding(.horizontal, StudioSpacing.section)
                    .padding(.vertical, StudioSpacing.lg)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                approvalCardBody

                approvalCardButtons
            }
            .frame(width: cardWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(Color(hex: "#0B0D10"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .strokeBorder(warningAmber.opacity(0.30), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 8)
            .shadow(color: warningAmber.opacity(cardVisible ? 0.10 : 0), radius: 40, x: 0, y: 0)
            .opacity(cardVisible ? 1 : 0)
            .scaleEffect(isExiting ? 0.94 : 1.0)
            .offset(y: cardVisible ? 0 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(ApprovalGateCard.cardSpring) {
                cardVisible = true
            }
        }
        .animation(ApprovalGateCard.cardExit, value: isExiting)
    }

    // MARK: - Exit helper

    private func dismiss(then action: (() -> Void)?) {
        guard !isExiting else { return }
        withAnimation(ApprovalGateCard.cardExit) {
            isExiting = true
            cardVisible = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            action?()
        }
    }

    // MARK: Header

    private var approvalCardHeader: some View {
        HStack(alignment: .center, spacing: StudioSpacing.lg) {
            Image(systemName: "shield.exclamationmark.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(warningAmber)
                .symbolRenderingMode(.monochrome)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text("Authorization Required")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(warningAmber.opacity(0.85))
                    .kerning(0.4)

                Text(approvalModel.title)
                    .font(StudioTypography.subheadlineSemibold)
                    .foregroundStyle(StudioTextColorDark.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Waiting pulse indicator
            HStack(spacing: StudioSpacing.sm) {
                WaitingAmberDot()
                Text("Waiting")
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(warningAmber.opacity(0.7))
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var approvalCardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Intent description
            Text(approvalModel.intentDescription)
                .font(StudioTypography.footnote)
                .foregroundStyle(StudioTextColorDark.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, StudioSpacing.section)
                .padding(.top, StudioSpacing.lg)
                .padding(.bottom, approvalModel.actionPreview != nil ? StudioSpacing.md : StudioSpacing.lg)

            // Command / path preview block
            if let preview = approvalModel.actionPreview, !preview.isEmpty {
                if approvalModel.isTerminalCommand {
                    TerminalCommandBlock(command: preview, accentColor: warningAmber)
                        .padding(.horizontal, StudioSpacing.section)
                        .padding(.bottom, StudioSpacing.lg)
                } else {
                    Text(preview)
                        .font(StudioTypography.code)
                        .foregroundStyle(StudioTextColorDark.secondary)
                        .lineLimit(4)
                        .padding(.horizontal, StudioSpacing.section)
                        .padding(.bottom, StudioSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    // MARK: Buttons

    private var approvalCardButtons: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            HStack(spacing: 0) {
                // Reject
                Button(action: { dismiss(then: onReject) }) {
                    Text("Reject")
                        .font(StudioTypography.bodyMedium)
                        .foregroundStyle(StudioTextColorDark.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, StudioSpacing.xxl)
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)

                // Authorize
                Button(action: { dismiss(then: onAuthorize) }) {
                    HStack(spacing: StudioSpacing.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("Authorize")
                            .font(StudioTypography.bodyMedium)
                    }
                    .foregroundStyle(Color(hex: "#0B0D10"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StudioSpacing.xxl)
                    .background(warningAmber)
                }
                .buttonStyle(.plain)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: StudioRadius.xl,
                        style: .continuous
                    )
                )
            }
        }
    }
}

// MARK: - Temporal Revert Card

private struct TemporalRevertCard: View {

    let model: TemporalRevertModel
    let onRevert: ((TemporalRevertModel) -> Void)?
    let onCancel: (() -> Void)?

    @State private var cardVisible = false
    @State private var isExiting = false

    private static let cardExit = Animation.easeOut(duration: 0.28)
    private static let cardEntrance = Animation.spring(response: 0.38, dampingFraction: 0.84)

    // Temporal palette — fully desaturated. No cyan. Time is grey.
    private let graphite    = Color(hex: "#7E8794")
    private let ghostWhite  = Color(hex: "#FFFFFF")
    private let elevated    = Color(hex: "#1A1E24")
    private let cardFill    = Color(hex: "#0D1014")
    private let cardWidth: CGFloat = 560

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        ZStack {
            ViewportIdleCanvas()
                .opacity(cardVisible ? 0.06 : 0)
                .saturation(0) // strip all color — nothing warm in the past
                .animation(
                    isExiting ? Self.cardExit : Self.cardEntrance,
                    value: cardVisible
                )

            VStack(alignment: .leading, spacing: 0) {
                revertHeader
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 16)

                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)

                revertBody
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)

                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)

                revertActions
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(graphite.opacity(0.22), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.55), radius: 32, x: 0, y: 10)
            .scaleEffect(isExiting ? 0.94 : 1.0)
            .opacity(cardVisible ? 1 : 0)
            .offset(y: cardVisible ? 0 : 18)
            .animation(isExiting ? Self.cardExit : Self.cardEntrance, value: cardVisible)
            .animation(Self.cardExit, value: isExiting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(Self.cardEntrance) { cardVisible = true }
        }
    }

    // MARK: Header

    private var revertHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(graphite)
                .symbolRenderingMode(.monochrome)

            VStack(alignment: .leading, spacing: 2) {
                Text("TEMPORAL REVERT")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(graphite.opacity(0.6))
                    .tracking(1.6)

                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            Text(Self.timeFormatter.string(from: model.anchorTimestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(graphite.opacity(0.55))
        }
    }

    // MARK: Body

    @ViewBuilder
    private var revertBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reverting will restore all files to the state at this exact point in time. Messages after this anchor will remain in the chat as read-only context.")
                .font(.system(size: 12))
                .foregroundStyle(graphite)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = model.actionPreview, !preview.isEmpty {
                TemporalCommandBlock(text: preview)
            }
        }
    }

    // MARK: Actions

    private var revertActions: some View {
        HStack(spacing: 10) {
            // Cancel — ghost
            Button {
                dismiss(then: { onCancel?() })
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(graphite)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(graphite.opacity(0.18), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // Revert CTA — white text on deeply elevated graphite pill
            Button {
                dismiss(then: { onRevert?(model) })
            } label: {
                ZStack {
                    if model.isReverting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.white.opacity(0.6))
                            .scaleEffect(0.65)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Revert Workspace to this Point")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(graphite.opacity(0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isReverting)
        }
    }

    // MARK: Exit

    private func dismiss(then action: @escaping () -> Void) {
        guard !isExiting else { return }
        withAnimation(Self.cardExit) {
            isExiting = true
            cardVisible = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            action()
        }
    }
}

// MARK: - Temporal Command Block (desaturated)

private struct TemporalCommandBlock: View {

    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.50))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Terminal Command Block

private struct TerminalCommandBlock: View {

    let command: String
    let accentColor: Color

    // Tokens that signal destructive or elevated-risk operations
    private static let riskyTokens: Set<String> = [
        "rm", "-rf", "-r", "-f", "--force", "--recursive",
        "sudo", "mkfs", "dd", "shred", "truncate", "chmod", "chown",
        "mv", ">", "|", "&&", ";"
    ]

    private var tokens: [CommandToken] {
        command.components(separatedBy: .whitespaces).compactMap { token in
            let clean = token.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            return CommandToken(
                text: clean,
                isRisky: Self.riskyTokens.contains(clean) || clean.hasPrefix("-") && clean.count <= 4
            )
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.5))

                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    Text(token.text)
                        .font(StudioTypography.code)
                        .foregroundStyle(token.isRisky ? accentColor : StudioTextColorDark.primary)
                }
            }
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, StudioSpacing.md)
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .strokeBorder(accentColor.opacity(0.15), lineWidth: 0.5)
        )
    }

    private struct CommandToken {
        let text: String
        let isRisky: Bool
    }
}

// MARK: - Waiting Amber Dot

private struct WaitingAmberDot: View {
    @State private var blink = false
    private let amber = Color(hex: "#FFB340")

    var body: some View {
        Circle()
            .fill(amber)
            .frame(width: 6, height: 6)
            .opacity(blink ? 0.2 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: blink
            )
            .onAppear { blink = true }
    }
}

// MARK: - Build Error Card

private struct BuildErrorCard: View {

    let errorModel: ViewportBuildErrorModel
    let onDiagnose: (() -> Void)?

    @State private var cardVisible = false

    private static let cardSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private let cardWidth: CGFloat = 620
    private let coolRed = Color(hex: "#FF7373")

    var body: some View {
        ZStack {
            ViewportIdleCanvas()
                .opacity(cardVisible ? 0.14 : 0)
                .animation(BuildErrorCard.cardSpring, value: cardVisible)

            VStack(spacing: 0) {
                errorCardHeader
                    .padding(.horizontal, StudioSpacing.section)
                    .padding(.vertical, StudioSpacing.lg)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                errorCardBody

                errorCardCTA
            }
            .frame(width: cardWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(Color(hex: "#0B0D10"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .strokeBorder(coolRed.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 8)
            .shadow(color: coolRed.opacity(cardVisible ? 0.12 : 0), radius: 32, x: 0, y: 0)
            .opacity(cardVisible ? 1 : 0)
            .offset(x: cardVisible ? 0 : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(BuildErrorCard.cardSpring) {
                cardVisible = true
            }
        }
    }

    // MARK: Header

    private var errorCardHeader: some View {
        HStack(alignment: .center, spacing: StudioSpacing.md) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(coolRed)
                .symbolRenderingMode(.monochrome)

            Text(errorModel.command.isEmpty ? "Build Failed" : errorModel.command)
                .font(StudioTypography.subheadlineSemibold)
                .foregroundStyle(StudioTextColorDark.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let report = errorModel.report {
                HStack(spacing: StudioSpacing.sm) {
                    if report.errorCount > 0 {
                        issueCountPill("\(report.errorCount) error\(report.errorCount == 1 ? "" : "s")", color: coolRed)
                    }
                    if report.warningCount > 0 {
                        issueCountPill("\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s")", color: Color(hex: "#FBBF24"))
                    }
                }
            }

            if errorModel.triageAttempts > 0 {
                Text("Attempt \(errorModel.triageAttempts + 1)")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(StudioTextColorDark.tertiary)
                    .padding(.horizontal, StudioSpacing.md)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
    }

    private func issueCountPill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(StudioTypography.microSemibold)
            .foregroundStyle(color)
            .padding(.horizontal, StudioSpacing.md)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
    }

    // MARK: Body

    @ViewBuilder
    private var errorCardBody: some View {
        if let report = errorModel.report, !report.issues.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.issues) { issue in
                        BuildIssueRow(issue: issue)

                        Rectangle()
                            .fill(Color.white.opacity(0.04))
                            .frame(height: 1)
                            .padding(.horizontal, StudioSpacing.section)
                    }
                }
                .padding(.vertical, StudioSpacing.xs)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                Text(errorModel.rawTail.isEmpty ? "No output captured." : errorModel.rawTail)
                    .font(StudioTypography.code)
                    .foregroundStyle(StudioTextColorDark.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(StudioSpacing.section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: CTA

    private var errorCardCTA: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            Button(action: { onDiagnose?() }) {
                HStack(spacing: StudioSpacing.md) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Diagnose & Fix")
                        .font(StudioTypography.bodyMedium)
                }
                .foregroundStyle(onDiagnose != nil ? StudioAccentColor.primary : StudioAccentColor.primary.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, StudioSpacing.xxl)
            }
            .buttonStyle(.plain)
            .disabled(onDiagnose == nil)
        }
    }
}

// MARK: - Build Issue Row

private struct BuildIssueRow: View {

    let issue: BuildIssue

    private var severityColor: Color {
        switch issue.severity {
        case .error:   return Color(hex: "#FF7373")
        case .warning: return Color(hex: "#FBBF24")
        case .note:    return Color(hex: "#7B9FD4")
        }
    }

    private var severitySymbol: String {
        switch issue.severity {
        case .error:   return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note:    return "info.circle.fill"
        }
    }

    private var fileLabel: String {
        guard let file = issue.file else { return "" }
        let name = URL(fileURLWithPath: file).lastPathComponent
        if let line = issue.line {
            return "\(name):\(line)"
        }
        return name
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.md) {
            Image(systemName: severitySymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(severityColor)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(issue.message)
                    .font(StudioTypography.footnote)
                    .foregroundStyle(StudioTextColorDark.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !fileLabel.isEmpty {
                    Text(fileLabel)
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColorDark.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioSpacing.section)
        .padding(.vertical, StudioSpacing.lg)
    }
}
// MARK: - Diff Document Card

private struct DiffDocumentCard: View {

    let diffModel: ViewportDiffModel
    let onApply: () -> Void

    @State private var cardVisible = false

    private static let cardSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private let cardWidth: CGFloat = 620

    var body: some View {
        ZStack {
            // Dimmed canvas bleed-through
            ViewportIdleCanvas()
                .opacity(cardVisible ? 0.18 : 0)
                .animation(DiffDocumentCard.cardSpring, value: cardVisible)

            // Floating document card
            VStack(spacing: 0) {
                diffCardHeader
                    .padding(.horizontal, StudioSpacing.section)
                    .padding(.vertical, StudioSpacing.lg)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                diffCardBody

                if diffModel.canApply {
                    diffHeroCTA
                }
            }
            .frame(width: cardWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(Color(hex: "#0B0D10"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 8)
            .opacity(cardVisible ? 1 : 0)
            .offset(x: cardVisible ? 0 : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(DiffDocumentCard.cardSpring) {
                cardVisible = true
            }
        }
    }

    // MARK: Card Header

    private var diffCardHeader: some View {
        HStack(alignment: .center, spacing: StudioSpacing.md) {
            Image(systemName: "arrow.left.and.right.square")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioAccentColor.primary.opacity(0.8))

            Text(diffModel.title)
                .font(StudioTypography.subheadlineSemibold)
                .foregroundStyle(StudioTextColorDark.primary)
                .lineLimit(1)

            if case .ready(let session) = diffModel.state {
                let stats = diffStats(from: session)
                if stats.additions > 0 || stats.removals > 0 {
                    HStack(spacing: StudioSpacing.sm) {
                        if stats.additions > 0 {
                            Text("+\(stats.additions)")
                                .font(StudioTypography.microSemibold)
                                .foregroundStyle(Color(hex: "#86EFAC"))
                        }
                        if stats.removals > 0 {
                            Text("−\(stats.removals)")
                                .font(StudioTypography.microSemibold)
                                .foregroundStyle(Color(hex: "#FF7373"))
                        }
                    }
                    .padding(.horizontal, StudioSpacing.md)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Card Body

    @ViewBuilder
    private var diffCardBody: some View {
        switch diffModel.state {
        case .idle, .loading:
            VStack(spacing: StudioSpacing.xl) {
                ProgressView()
                    .controlSize(.small)
                    .tint(StudioTextColorDark.secondary.opacity(0.78))
                Text("Preparing diff preview")
                    .font(StudioTypography.dataCaption)
                    .foregroundStyle(StudioTextColorDark.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView(
                "Apply Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready(let session):
            DiffPreviewView(session: session)
                .padding(.horizontal, 4)

        case .archived(let diffText):
            ArtifactCodeDiffView(diffText: diffText)
        }
    }

    // MARK: Hero CTA

    private var diffHeroCTA: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            Button(action: onApply) {
                HStack(spacing: StudioSpacing.md) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Accept & Apply")
                        .font(StudioTypography.bodyMedium)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, StudioSpacing.xxl)
                .background(StudioAccentColor.primary)
            }
            .buttonStyle(.plain)
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: StudioRadius.xl,
                    bottomTrailingRadius: StudioRadius.xl,
                    style: .continuous
                )
            )
        }
    }

    // MARK: Helpers

    private func diffStats(from session: CodeDiffSession) -> (additions: Int, removals: Int) {
        let adds = session.diffLines.filter { $0.kind == .addition }.count
        let rems = session.diffLines.filter { $0.kind == .removal }.count
        return (adds, rems)
    }
}

// MARK: - Viewport Idle Canvas

private struct ViewportIdleCanvas: View {

    var isIndexing: Bool = false

    @State private var glowPulse = false

    var body: some View {
        ZStack {
            // Isometric dot grid
            IsometricDotGrid()
                .frame(width: 340, height: 340)
                .mask(
                    RadialGradient(
                        gradient: Gradient(colors: [.black, .black, .clear]),
                        center: .center,
                        startRadius: 30,
                        endRadius: 160
                    )
                )

            // Wireframe device silhouette
            WireframeDeviceShape()
                .stroke(
                    LinearGradient(
                        colors: [
                            StudioAccentColor.primary.opacity(0.70),
                            StudioAccentColor.primary.opacity(0.38),
                            Color.white.opacity(0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.0
                )
                .frame(width: 80, height: 136)
                .shadow(color: StudioAccentColor.primary.opacity(glowPulse ? 0.45 : 0.18), radius: glowPulse ? 28 : 16)
                .animation(
                    Animation.easeInOut(duration: isIndexing ? 0.8 : 2.8).repeatForever(autoreverses: true),
                    value: glowPulse
                )
        }
        .onAppear { glowPulse = true }
        .onChange(of: isIndexing) { _, _ in
            // Reset the pulse so the new duration animation picks up cleanly.
            glowPulse = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                glowPulse = true
            }
        }
    }
}

private struct IsometricDotGrid: View {

    private let spacing: CGFloat = 14
    private let dotSize: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            // Isometric projection: offset alternating rows by half-spacing
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / (spacing * 0.577)) + 2  // 0.577 ≈ tan(30°)
            let rowHeight = spacing * 0.866  // cos(30°)

            for row in 0..<rows {
                for col in 0..<cols {
                    let xOffset: CGFloat = row % 2 == 0 ? 0 : spacing / 2
                    let x = CGFloat(col) * spacing + xOffset - spacing
                    let y = CGFloat(row) * rowHeight - rowHeight

                    let dot = Path(ellipseIn: CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    ))
                    context.fill(dot, with: .color(Color.white.opacity(0.12)))
                }
            }
        }
    }
}

private struct WireframeDeviceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = 7          // corner radius
        let w = rect.width
        let h = rect.height
        let sideInset: CGFloat = 0

        // Outer body
        p.addRoundedRect(in: CGRect(x: sideInset, y: 0, width: w - sideInset * 2, height: h), cornerSize: CGSize(width: r, height: r))

        // Screen inset
        let screenPad: CGFloat = 4
        let screenTop: CGFloat = 12
        let screenBottom: CGFloat = 12
        p.addRoundedRect(
            in: CGRect(x: screenPad, y: screenTop, width: w - screenPad * 2, height: h - screenTop - screenBottom),
            cornerSize: CGSize(width: r - 2, height: r - 2)
        )

        // Home indicator line
        let hiW: CGFloat = 20
        let hiY = h - 6
        p.move(to: CGPoint(x: (w - hiW) / 2, y: hiY))
        p.addLine(to: CGPoint(x: (w + hiW) / 2, y: hiY))

        // Camera dot
        let camCX = w / 2
        let camR: CGFloat = 1.5
        p.addEllipse(in: CGRect(x: camCX - camR, y: 5 - camR, width: camR * 2, height: camR * 2))

        return p
    }
}

private struct ViewportSubtleButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .fill(configuration.isPressed ? StudioSurfaceElevated.level2 : StudioSurfaceElevated.level1)
            )
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

// MARK: - Plan Document View

struct ViewportPlanDocumentView: View {

    let plan: ViewportPlanModel

    @State private var showSuggestField = false
    @State private var suggestText = ""
    @FocusState private var isSuggestFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable spec document
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    documentHeader
                        .padding(.horizontal, StudioSpacing.sectionGap)
                        .padding(.top, StudioSpacing.sectionGap)

                    // Hairline divider
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.horizontal, StudioSpacing.sectionGap)
                        .padding(.vertical, StudioSpacing.section)

                    documentBody
                        .padding(.horizontal, StudioSpacing.sectionGap)

                    Spacer(minLength: StudioSpacing.pagePad)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Fixed approve/decline bar — never scrolls away
            approvalBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Document Header

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.section) {

            // Meta row: agent badge + timestamp
            HStack(spacing: StudioSpacing.md) {
                if let agent = plan.agentName {
                    Text(agent.uppercased())
                        .font(StudioTypography.dataMicroSemibold)
                        .foregroundStyle(StudioAccentColor.primary)
                        .tracking(0.9)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(StudioAccentColor.primary.opacity(0.12))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(StudioAccentColor.primary.opacity(0.25), lineWidth: 0.5)
                                )
                        )
                } else {
                    // Default agent badge when name is absent
                    HStack(spacing: 5) {
                        Circle()
                            .fill(StudioAccentColor.primary)
                            .frame(width: 5, height: 5)
                        Text("AGENT PLAN")
                            .font(StudioTypography.dataMicroSemibold)
                            .foregroundStyle(StudioAccentColor.primary)
                            .tracking(0.9)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(StudioAccentColor.primary.opacity(0.10))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(StudioAccentColor.primary.opacity(0.22), lineWidth: 0.5)
                            )
                    )
                }

                Spacer(minLength: 0)

                Text(plan.timestamp, format: .dateTime.hour().minute())
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioTextColorDark.tertiary.opacity(0.6))
            }

            // Title
            Text(plan.title)
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundStyle(StudioTextColorDark.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            // Subtitle pill
            if !plan.subtitle.isEmpty {
                HStack(spacing: StudioSpacing.sm) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(StudioAccentColor.primary.opacity(0.65))
                        .frame(width: 3, height: 12)
                    Text(plan.subtitle)
                        .font(StudioTypography.footnoteMedium)
                        .foregroundStyle(StudioTextColorDark.secondary)
                }
            }
        }
    }

    // MARK: - Document Body

    private var documentBody: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.messageGap) {
            ForEach(Array(parseSections().enumerated()), id: \.offset) { _, section in
                planSection(section)
            }
        }
    }

    // MARK: - Section

    private func planSection(_ section: PlanSection) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.lg) {

            if let heading = section.heading {
                HStack(alignment: .center, spacing: StudioSpacing.lg) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(StudioAccentColor.primary.opacity(0.55))
                        .frame(width: 2.5, height: 13)
                    Text(heading)
                        .font(StudioTypography.headline)
                        .foregroundStyle(StudioTextColorDark.primary)
                        .tracking(0.05)
                }
            }

            if !section.body.isEmpty {
                Text(section.body)
                    .font(StudioTypography.body)
                    .foregroundStyle(StudioTextColorDark.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, section.heading != nil ? 14 : 0)
            }

            if !section.items.isEmpty {
                VStack(alignment: .leading, spacing: StudioSpacing.md + 2) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        planStepRow(item, index: index)
                    }
                }
                .padding(.leading, section.heading != nil ? 14 : 0)
            }
        }
    }

    private func planStepRow(_ item: PlanItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.xl) {
                // Step number / checkmark bubble
                ZStack {
                    if item.isChecked {
                        Circle()
                            .fill(StudioStatusColor.success.opacity(0.14))
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StudioStatusColor.success)
                    } else {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            .frame(width: 20, height: 20)
                        Text("\(index + 1)")
                            .font(StudioTypography.microSemibold)
                            .foregroundStyle(StudioTextColorDark.tertiary)
                    }
                }
                .frame(width: 20, height: 20)

                Text(item.text)
                    .font(StudioTypography.body)
                    .foregroundStyle(
                        item.isChecked
                            ? StudioTextColorDark.tertiary
                            : StudioTextColorDark.primary
                    )
                    .strikethrough(item.isChecked, color: StudioTextColorDark.tertiary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            if !item.substeps.isEmpty {
                VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus + 1) {
                    ForEach(Array(item.substeps.enumerated()), id: \.offset) { _, sub in
                        HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.md) {
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 1, height: 9)
                                .offset(y: 2)
                            Text(sub)
                                .font(StudioTypography.subheadline)
                                .foregroundStyle(StudioTextColorDark.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        }
                    }
                }
                .padding(.leading, 32)
            }
        }
    }

    // MARK: - Approval Action Bar

    private var approvalBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Suggest changes inline input — slides in above the button row
            if showSuggestField {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 1)

                    HStack(spacing: StudioSpacing.xl) {
                        TextField("Describe your changes…", text: $suggestText)
                            .textFieldStyle(.plain)
                            .font(StudioTypography.body)
                            .foregroundStyle(StudioTextColorDark.primary)
                            .focused($isSuggestFocused)
                            .onSubmit { submitSuggestion() }

                        Button(action: submitSuggestion) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(
                                    suggestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? StudioTextColorDark.tertiary.opacity(0.35)
                                        : StudioAccentColor.primary
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(suggestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, StudioSpacing.sectionGap)
                    .padding(.vertical, StudioSpacing.section)
                    .background(Color.white.opacity(0.025))
                }
                .transition(.studioCollapse)
            }

            HStack(spacing: StudioSpacing.xl) {

                // Decline — auto-submits "Declined." to AI immediately
                PlanActionButton(
                    label: "Decline",
                    icon: "xmark",
                    style: .ghost
                ) {
                    NotificationCenter.default.post(
                        name: .submitStudioMessage,
                        object: nil,
                        userInfo: ["text": "Declined. Don't proceed with this plan."]
                    )
                }

                Spacer(minLength: 0)

                // Suggest changes — reveals inline compose field
                PlanActionButton(
                    label: showSuggestField ? "Cancel" : "Suggest changes",
                    icon: showSuggestField ? "xmark" : "pencil.line",
                    style: .subtle
                ) {
                    withAnimation(StudioMotion.standardSpring) {
                        showSuggestField.toggle()
                        if showSuggestField {
                            isSuggestFocused = true
                        } else {
                            suggestText = ""
                        }
                    }
                }

                // Approve — auto-submits "Approved." to AI immediately
                PlanActionButton(
                    label: "Approve Plan",
                    icon: "checkmark",
                    style: .primary
                ) {
                    NotificationCenter.default.post(
                        name: .submitStudioMessage,
                        object: nil,
                        userInfo: ["text": "Approved. Please proceed with the plan."]
                    )
                }
            }
            .padding(.horizontal, StudioSpacing.sectionGap)
            .padding(.vertical, StudioSpacing.section)
        }
        .background(StudioSurface.viewport)
        .animation(StudioMotion.standardSpring, value: showSuggestField)
    }

    private func submitSuggestion() {
        let trimmed = suggestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NotificationCenter.default.post(
            name: .submitStudioMessage,
            object: nil,
            userInfo: ["text": "I'd like to suggest some changes to the plan: \(trimmed)"]
        )
        withAnimation(StudioMotion.standardSpring) {
            showSuggestField = false
            suggestText = ""
        }
    }

    // MARK: - Parsing

    private struct PlanItem {
        var text: String
        var substeps: [String] = []
        var isChecked: Bool = false
    }

    private struct PlanSection {
        var heading: String?
        var items: [PlanItem] = []
        var body: String = ""
    }

    private func parseSections() -> [PlanSection] {
        let lines = plan.markdown.components(separatedBy: .newlines)
        var sections: [PlanSection] = []
        var current = PlanSection()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)

            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                if current.heading != nil || !current.items.isEmpty || !current.body.isEmpty {
                    sections.append(current)
                }
                let headingText = trimmed.drop(while: { $0 == "#" || $0 == " " })
                current = PlanSection(heading: String(headingText))
            } else if (line.hasPrefix("  ") || line.hasPrefix("\t")),
                      (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")),
                      !current.items.isEmpty {
                let subText = String(trimmed.dropFirst(2))
                current.items[current.items.count - 1].substeps.append(subText)
            } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let isChecked = trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")
                let itemText = String(trimmed.dropFirst(6))
                current.items.append(PlanItem(text: itemText, isChecked: isChecked))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let itemText = String(trimmed.dropFirst(2))
                current.items.append(PlanItem(text: itemText))
            } else if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                let itemText = String(trimmed[match.upperBound...])
                current.items.append(PlanItem(text: itemText))
            } else if !trimmed.isEmpty {
                if current.body.isEmpty {
                    current.body = trimmed
                } else {
                    current.body += " " + trimmed
                }
            }
        }

        if current.heading != nil || !current.items.isEmpty || !current.body.isEmpty {
            sections.append(current)
        }

        if sections.isEmpty {
            sections.append(PlanSection(body: plan.markdown))
        }

        return sections
    }
}

// MARK: - Plan Action Button

private struct PlanActionButton: View {

    enum Style { case primary, subtle, ghost }

    let label: String
    let icon: String
    let style: Style
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: style == .primary ? 10 : 11, weight: .semibold))
                Text(label)
                    .font(StudioTypography.subheadlineSemibold)
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, StudioSpacing.sectionGap)
            .padding(.vertical, StudioSpacing.lg + 1)
            .background(background)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
        .help(label)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            return isHovered
                ? StudioAccentColor.primary.opacity(0.88)
                : StudioAccentColor.primary
        case .subtle:
            return isHovered
                ? Color.white.opacity(0.09)
                : Color.white.opacity(0.05)
        case .ghost:
            return isHovered
                ? Color.white.opacity(0.05)
                : Color.clear
        }
    }

    private var strokeColor: Color {
        switch style {
        case .primary: return Color.clear
        case .subtle:  return Color.white.opacity(isHovered ? 0.14 : 0.08)
        case .ghost:   return Color.white.opacity(isHovered ? 0.14 : 0.1)
        }
    }

    private var labelColor: Color {
        switch style {
        case .primary: return Color.black
        case .subtle:  return StudioTextColorDark.secondary
        case .ghost:   return StudioTextColorDark.tertiary
        }
    }
}

// MARK: - Terminal Activity Popup

struct ViewportTerminalPopup: View {

    let model: ViewportTerminalModel
    let onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalHeader

            if isExpanded {
                terminalOutput
                    .transition(.studioCollapse)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(StudioSurface.viewport)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
        .frame(maxWidth: .infinity)
        .animation(StudioMotion.standardSpring, value: isExpanded)
    }

    private var terminalHeader: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: StudioSpacing.md) {
                if model.isRunning {
                    Circle()
                        .fill(StudioStatusColor.success)
                        .frame(width: 6, height: 6)
                }

                Text(model.command)
                    .font(StudioTypography.codeSmallMedium)
                    .foregroundStyle(StudioTextColorDark.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up")
                    .font(StudioTypography.badgeSmallSemibold)
                    .foregroundStyle(StudioTextColorDark.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, StudioSpacing.lg)
        }
        .buttonStyle(.plain)
    }

    private var terminalOutput: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                ForEach(Array(model.lines.suffix(50).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(StudioTypography.codeSmall)
                        .foregroundStyle(StudioTextColorDark.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.bottom, StudioSpacing.lg)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 160)
        .background(StudioSurface.viewport)
    }
}
