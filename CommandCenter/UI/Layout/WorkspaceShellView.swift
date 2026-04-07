import SwiftUI

struct WorkspaceShellView: View {

    let project: AppProject?
    let allProjects: [AppProject]
    let jobs: [AgentSession]
    let selectedSession: AgentSession?
    @Binding var selectedEpochID: UUID?
    let runner: PipelineRunner
    let repositoryState: GitRepositoryState
    let isRefreshingRepository: Bool
    @Binding var goalText: String
    @Binding var attachments: [ChatAttachment]
    let viewportModel: ViewportStreamModel
    let ambientContext: AmbientEditorContextCoordinator
    let onSubmit: () -> Void
    let onSelectSession: (UUID) -> Void
    let onSelectProject: (UUID) -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onRefreshRepository: () -> Void
    let onInitializeRepository: () -> Void
    let onOpenWorkspace: () -> Void
    let simulatorPreviewService: SimulatorPreviewService
    let templateEngine: SessionTemplateEngine
    let onExecuteRevert: ((TemporalRevertModel) -> Void)?
    let onCancelRevert: (() -> Void)?
    var onShowRevert: ((ApprovalAuditEntry) -> Void)? = nil
    var onAuthorizeApproval: (() -> Void)? = nil
    var showSidebarToggle: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    @ObservedObject var titleGenerator: ThreadTitleGenerator

    @Binding var isViewportVisible: Bool
    @Binding var viewportWidth: Double

    @ObservedObject private var commandApproval = CommandApprovalController.shared

    /// Minimum width the execution pane needs to remain usable.
    private static let executionPaneMinUsable: CGFloat = 420
    /// Minimum viewport width.
    private static let viewportMinWidth: CGFloat = 260
    /// Hysteresis buffer — viewport appears at this threshold, hides at viewportMinWidth.
    /// Prevents flicker when the user resizes right at the boundary.
    private static let viewportShowThreshold: CGFloat = 280

    /// Tracks whether the viewport was showing on the last layout pass,
    /// so the hide threshold can be lower than the show threshold.
    @State private var viewportLayoutActive = false

    var body: some View {
        GeometryReader { geometry in
            let availableForViewport = geometry.size.width - Self.executionPaneMinUsable
            // Hysteresis: require more space to show than to hide.
            let threshold = viewportLayoutActive ? Self.viewportMinWidth : Self.viewportShowThreshold
            let canFitViewport = availableForViewport >= threshold

            HStack(spacing: 0) {
                ExecutionPaneView(
                project: project,
                allProjects: allProjects,
                jobs: jobs,
                selectedSession: selectedSession,
                selectedEpochID: $selectedEpochID,
                runner: runner,
                repositoryState: repositoryState,
                isRefreshingRepository: isRefreshingRepository,
                goalText: $goalText,
                attachments: $attachments,
                templateEngine: templateEngine,
                onSubmit: onSubmit,
                onSelectSession: onSelectSession,
                onSelectProject: onSelectProject,
                onOpenArtifact: onOpenArtifact,
                onRefreshRepository: onRefreshRepository,
                onInitializeRepository: onInitializeRepository,
                onOpenWorkspace: onOpenWorkspace,
                onShowRevert: onShowRevert,
                onAuthorizeApproval: onAuthorizeApproval,
                showSidebarToggle: showSidebarToggle,
                showViewportToggle: !isViewportVisible && canFitViewport,
                onToggleSidebar: onToggleSidebar,
                onToggleViewport: { withAnimation(StudioMotion.panelSpring) { isViewportVisible = true } },
                titleGenerator: titleGenerator
            )
            .frame(minWidth: 380, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioSurface.base)

            if isViewportVisible && canFitViewport {
                PaneDivider(axis: .vertical)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if let screen = NSScreen.main {
                                    let fromRight = screen.frame.width - value.location.x
                                    let proposed = max(260, min(fromRight - 12, 600))
                                    viewportWidth = proposed
                                }
                            }
                    )

                ViewportPaneView(
                    model: viewportModel,
                    ambientContext: ambientContext,
                    previewService: simulatorPreviewService,
                    onHide: { withAnimation(StudioMotion.panelSpring) { isViewportVisible = false } },
                    onAuthorizeApproval: onAuthorizeApproval ?? { commandApproval.approve() },
                    onRejectApproval: { commandApproval.deny() },
                    onExecuteRevert: onExecuteRevert,
                    onCancelRevert: onCancelRevert,
                    isIndexing: isRefreshingRepository
                )
                .frame(width: max(260, min(viewportWidth, 600)))
                .background(StudioSurface.viewport)
                .environment(\.colorScheme, .dark)
                .transition(.studioPanelTrailing)
            }
            } // end HStack
            .onChange(of: canFitViewport) { _, fits in
                viewportLayoutActive = fits && isViewportVisible
            }
            .onChange(of: isViewportVisible) { _, visible in
                viewportLayoutActive = visible && canFitViewport
            }
        } // end GeometryReader
        .background(Color.clear)
        .onChange(of: commandApproval.pendingRequest) { _, request in
            if let request {
                viewportModel.showApprovalGate(ViewportApprovalModel(
                    title: request.title,
                    toolName: request.toolName,
                    intentDescription: request.intentDescription,
                    actionPreview: request.actionPreview
                ))
            } else {
                withAnimation(.easeOut(duration: 0.30)) {
                    viewportModel.dismissApprovalGate()
                }
            }
        }
    }
}
