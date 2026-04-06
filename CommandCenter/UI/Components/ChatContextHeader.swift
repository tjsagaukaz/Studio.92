// ContextHeaderView.swift
// Studio.92 — CommandCenter
//
// Thread title bar with branch indicator, export, and sidebar/viewport toggles.

import SwiftUI
import AppKit

// MARK: - Context Header

struct ContextHeaderView: View {

    let turns: [ConversationTurn]
    let project: AppProject?
    let repositoryState: GitRepositoryState?
    var showSidebarToggle: Bool = false
    var showViewportToggle: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onToggleViewport: (() -> Void)? = nil
    @ObservedObject var titleGenerator: ThreadTitleGenerator

    @State private var isEditingTitle = false
    @State private var editBuffer = ""
    @State private var customTitle: String?
    @State private var titleOpacity: Double = 1

    private var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if titleGenerator.isTyping {
            return titleGenerator.displayedTitle
        }
        if let generated = titleGenerator.generatedTitle, !generated.isEmpty {
            return generated
        }
        if let raw = turns.first?.userGoal.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let capped = String(raw.prefix(48))
            return capped.count < raw.count ? capped + "…" : capped
        }
        return project?.name ?? "New Thread"
    }

    private var isUsingPlaceholder: Bool {
        customTitle == nil && !titleGenerator.isTyping && titleGenerator.generatedTitle == nil
    }

    private var branchName: String {
        repositoryState?.branchDisplayName ?? "—"
    }

    private var isDirty: Bool {
        guard let state = repositoryState else { return false }
        return !state.changes.isEmpty
    }

    private var isRepo: Bool {
        repositoryState?.isRepository == true
    }

    var body: some View {
        HStack(spacing: 0) {

            // Sidebar toggle — leading edge, visible only when sidebar is collapsed
            if showSidebarToggle {
                Button { onToggleSidebar?() } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(hex: "#7E8794"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Sidebar (⌃⌘S)")
                .padding(.trailing, StudioSpacing.sm)
                .transition(.opacity)
            }

            // Left — Thread title
            Group {
                if isEditingTitle {
                    TextField("Thread title", text: $editBuffer)
                        .textFieldStyle(.plain)
                        .font(StudioTypography.footnoteMedium)
                        .foregroundStyle(Color(hex: "#B7BEC8"))
                        .onSubmit { commitEdit() }
                } else {
                    HStack(spacing: 0) {
                        Text(displayTitle)
                            .font(StudioTypography.footnoteMedium)
                            .foregroundStyle(Color(hex: "#B7BEC8"))
                            .lineLimit(1)
                            .opacity(titleOpacity)
                        if titleGenerator.isCursorVisible {
                            TypewriterCursor()
                        }
                    }
                    .onTapGesture(count: 2) {
                        editBuffer = displayTitle
                        isEditingTitle = true
                    }
                    // Refinement 4: fade placeholder out, then let typewriter fill in
                    .onChange(of: titleGenerator.isTyping) { _, typing in
                        if typing, isUsingPlaceholder {
                            // already faded by generator arrival; snap opacity back after swap
                        }
                    }
                    .onChange(of: titleGenerator.generatedTitle) { _, newTitle in
                        guard newTitle != nil else { return }
                        // Quick fade of placeholder before typewriter starts
                        withAnimation(.easeOut(duration: 0.1)) { titleOpacity = 0 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            titleOpacity = 1  // reset; typewriter chars will fill in
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: StudioSpacing.xxl)

            // Right — Environment telemetry + export
            HStack(spacing: StudioSpacing.sm) {

                if isRepo {
                    // Branch pill
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .medium))
                        Text(branchName)
                            .font(StudioTypography.captionMedium)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: "#7E8794"))
                    .padding(.horizontal, StudioSpacing.sm)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .environment(\.colorScheme, .dark)

                    // Status dot
                    Circle()
                        .fill(isDirty ? Color(hex: "#86EFAC") : Color(hex: "#7E8794").opacity(0.45))
                        .frame(width: 4, height: 4)
                }

                // Export
                Button { exportChat() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(hex: "#7E8794"))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Viewport toggle — trailing edge, visible only when viewport is collapsed
                if showViewportToggle {
                    Button { onToggleViewport?() } label: {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color(hex: "#7E8794"))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show Viewport (⌘1)")
                    .padding(.leading, StudioSpacing.xs)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, StudioSpacing.sectionGap)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Color(hex: "#0B0D10"))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
        }
        .onExitCommand {
            if isEditingTitle { isEditingTitle = false }
        }
    }

    private func commitEdit() {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { customTitle = trimmed }
        isEditingTitle = false
    }

    private func exportChat() {
        guard !turns.isEmpty else { return }
        let text = turns.map { turn -> String in
            let goal = turn.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## \(goal)\n\n\(response)"
        }.joined(separator: "\n\n---\n\n")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "thread-export.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Typewriter Cursor

struct TypewriterCursor: View {
    @State private var blinkOpacity: Double = 1

    var body: some View {
        Rectangle()
            .fill(Color(hex: "#B7BEC8"))
            .frame(width: 1.5, height: 12)
            .opacity(blinkOpacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true)) {
                    blinkOpacity = 0.15
                }
            }
            .padding(.leading, 1)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }
}
