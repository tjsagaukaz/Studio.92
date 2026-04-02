// CommandCenterApp.swift
// Studio.92 — Command Center
// macOS app entry point. Configures SwiftData container and window.

import SwiftUI
import SwiftData
import AppKit

@main
struct CommandCenterApp: App {

    @AppStorage("packageRoot") private var packageRoot = ""

    /// Resolve the package root: use stored value, or auto-detect from bundle location.
    private var resolvedPackageRoot: String {
        if !packageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(packageRoot)/Package.swift") {
            return packageRoot
        }

        // Auto-detect: walk up from bundle location looking for Package.swift
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.path
            }
        }

        // Fallback
        return "/Users/tj/Desktop/Studio.92"
    }

    /// Shared model container for SwiftData.
    private var sharedContainer: ModelContainer = {
        try! ModelContainer(for: AppProject.self, Epoch.self)
    }()

    var body: some Scene {
        WindowGroup {
            CommandCenterView(packageRoot: resolvedPackageRoot)
                .onAppear {
                    startTelemetryObserver()
                    Task {
                        await StatefulTerminalEngine.shared.bootstrap()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task {
                        await StatefulTerminalEngine.shared.terminate()
                    }
                }
        }
        .modelContainer(sharedContainer)
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(packageRoot: $packageRoot)
        }
    }

    // MARK: - Telemetry Observer

    /// Lazy observer and ingestor — started once on app launch.
    private static var observer: FactoryObserver?
    private static var ingestor: TelemetryIngestor?
    private static var observerStarted = false

    private func startTelemetryObserver() {
        guard !Self.observerStarted else { return }
        Self.observerStarted = true

        let ingestor = TelemetryIngestor(container: sharedContainer)
        Self.ingestor = ingestor

        let observer = FactoryObserver { url in
            Task {
                let projectID = await ingestor.ingest(fileURL: url)
                if let projectID {
                    // Notify the main context to refresh
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .telemetryIngested,
                            object: nil,
                            userInfo: ["projectID": projectID]
                        )
                    }
                    print("[TelemetryObserver] Ingested: \(url.lastPathComponent) → project \(projectID)")
                }
            }
        }
        observer.start()
        Self.observer = observer
    }
}

// MARK: - Settings

private struct SettingsView: View {

    @Binding var packageRoot: String
    @AppStorage("anthropicAPIKey") private var apiKey = ""
    @AppStorage("openAIAPIKey") private var openAIKey = ""
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("Package Root") {
                HStack {
                    TextField("Path to Studio.92", text: $packageRoot)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Button("Browse...") {
                        showFolderPicker = true
                    }
                }

                if !packageRoot.isEmpty {
                    let valid = FileManager.default.fileExists(atPath: "\(packageRoot)/Package.swift")
                    HStack(spacing: 4) {
                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(valid ? StudioTheme.accent : StudioTheme.secondaryText)
                        Text(valid ? "Package.swift found" : "No Package.swift at this path")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Model Routing") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Studio.92 is now wired around explicit model roles instead of hidden provider switching.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(StudioModelStrategy.all, id: \.id) { model in
                        SettingsModelRoleCard(model: model)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Anthropic Access") {
                SecureField("ANTHROPIC_API_KEY", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 4) {
                    Image(systemName: anthropicAccessReady ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(anthropicAccessReady ? StudioTheme.accent : StudioTheme.secondaryText)
                    Text(anthropicAccessStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("OpenAI Access") {
                SecureField("OPENAI_API_KEY", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 4) {
                    Image(systemName: openAIAccessReady ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(openAIAccessReady ? StudioTheme.accent : StudioTheme.secondaryText)
                    Text(openAIAccessStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                packageRoot = url.path
            }
        }
    }

    private var anthropicAccessReady: Bool {
        StudioModelStrategy.credential(provider: .anthropic, storedValue: apiKey) != nil
    }

    private var openAIAccessReady: Bool {
        StudioModelStrategy.credential(provider: .openAI, storedValue: openAIKey) != nil
    }

    private var anthropicAccessStatus: String {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Saved in Studio.92 — Review mode and Opus escalation are ready."
        }

        if anthropicAccessReady {
            return "Using ANTHROPIC_API_KEY from the environment — Review mode and Opus escalation are ready."
        }

        return "Needed for Claude Sonnet 4.6 review mode and Claude Opus 4.6 escalation."
    }

    private var openAIAccessStatus: String {
        if !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Saved in Studio.92 — Full Send, subagents, research, and release workflows are ready."
        }

        if openAIAccessReady {
            return "Using OPENAI_API_KEY from the environment — Full Send, subagents, research, and release workflows are ready."
        }

        return "Needed for GPT-5.4 full-send, GPT-5.4 mini workers, standards research, and release/compliance flows."
    }
}

private struct SettingsModelRoleCard: View {

    let model: StudioModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.role.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.role.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.primaryText)

                        Text(model.displayName)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(StudioTheme.secondaryText)
                    }

                    Text(model.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        SettingsModelPill(
                            title: model.provider.title,
                            systemImage: model.provider.symbolName
                        )

                        if let effort = model.defaultReasoningEffort {
                            SettingsModelPill(
                                title: "Reasoning \(effort)",
                                systemImage: "brain.head.profile"
                            )
                        }

                        if model.supportsComputerUse {
                            SettingsModelPill(
                                title: "Computer Use",
                                systemImage: "macbook.and.iphone"
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct SettingsModelPill: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(StudioTheme.primaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}
