// CommandCenterApp.swift
// Studio.92 — Command Center
// macOS app entry point. Configures SwiftData container and window.

import SwiftUI
import SwiftData
import AppKit
import CoreText

@main
struct CommandCenterApp: App {

    @NSApplicationDelegateAdaptor(CommandCenterAppDelegate.self) private var appDelegate
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
        let schema = Schema([AppProject.self, Epoch.self, PersistedSpan.self, PersistedThread.self, PersistedMessage.self, DurableMemoryProfile.self, WorkingMemorySnapshot.self, RunCheckpoint.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            print("[Studio.92] SwiftData container failed: \(error.localizedDescription). Attempting fresh store.")
            // Attempt to delete the corrupted store and its companion files, then retry.
            let storeDir = URL.applicationSupportDirectory
            let fm = FileManager.default
            for suffix in ["default.store", "default.store-wal", "default.store-shm"] {
                try? fm.removeItem(at: storeDir.appendingPathComponent(suffix))
            }
            do {
                return try ModelContainer(for: schema)
            } catch {
                fatalError("[Studio.92] SwiftData container unrecoverable after store reset: \(error.localizedDescription)")
            }
        }
    }()

    init() {
        StudioFontRegistry.registerBundledFonts()
        StudioCredentialStore.migrateFromUserDefaultsIfNeeded()
        WindowStateSanitizer.sanitizeIfNeeded()
        WindowStateObserver.shared.start()
    }

    var body: some Scene {
        Window("Studio.92", id: "main") {
            CommandCenterView(packageRoot: resolvedPackageRoot)
                .background(
                    WindowAccessorView { window in
                        WindowStateSanitizer.attach(to: window)
                    }
                )
                .onAppear {
                    WindowStateSanitizer.scheduleWindowClamp()
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
        .windowToolbarStyle(.unified)
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

final class CommandCenterAppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }
}

private enum StudioFontRegistry {

    private static var hasRegistered = false
    private static let bundledFonts = [
        "Geist-Light",
        "Geist-Regular",
        "Geist-Medium"
    ]

    static func registerBundledFonts() {
        guard !hasRegistered else { return }
        hasRegistered = true

        for fontName in bundledFonts {
            guard let fontURL = Bundle.main.url(forResource: fontName, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
}

private enum WindowStateSanitizer {

    private static var attachedWindowNumbers = Set<Int>()

    static func sanitizeIfNeeded() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys

        for key in keys where key.hasPrefix("NSWindow Frame ") {
            // NSWindow Frame values are "x y w h x0 y0 w0 h0" — parse origin to check if offscreen.
            guard let frameString = defaults.string(forKey: key) else { continue }
            let components = frameString.split(separator: " ").compactMap { Double($0) }
            guard components.count >= 4 else {
                defaults.removeObject(forKey: key)
                continue
            }
            let x = components[0], y = components[1], w = components[2], h = components[3]
            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            // Remove only if the window is completely offscreen or degenerate.
            if !visibleFrame.intersects(windowRect) || w < 100 || h < 100 {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func attach(to window: NSWindow) {
        let windowNumber = window.windowNumber
        guard !attachedWindowNumbers.contains(windowNumber) else { return }

        attachedWindowNumbers.insert(windowNumber)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.setFrameAutosaveName("Studio92MainWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = StudioColorTokens.AppKit.surfaceBase
        applyInitialFrame(to: window)
    }

    static func configure(_ window: NSWindow) {
        // No-op — respect the user's window frame after initial setup.
    }

    static func clampVisibleWindows() {
        // No-op — window position is managed by frame autosave.
    }

    static func scheduleWindowClamp() {
        // No-op — initial frame is applied in attach(to:).
    }

    static func forceClamp(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }

        // No-op — forceClamp is retired. Frame autosave and macOS window
        // management handle positioning. Manual clamping fought the window
        // manager and broke maximize + focus.
    }

    private static func applyInitialFrame(to window: NSWindow) {
        let minSize = NSSize(width: 800, height: 500)
        window.minSize = minSize
        window.contentMinSize = minSize

        // If frame autosave restored a valid frame, keep it.
        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if visibleFrame.intersects(window.frame) && window.frame.width >= 800 {
                return
            }
            // First launch or invalid saved frame — center at preferred size.
            let defaultWidth = min(1200, visibleFrame.width)
            let defaultHeight = min(800, visibleFrame.height)
            let launchFrame = NSRect(
                x: visibleFrame.midX - (defaultWidth / 2),
                y: visibleFrame.midY - (defaultHeight / 2),
                width: defaultWidth,
                height: defaultHeight
            )
            window.setFrame(launchFrame, display: true)
        }
    }

}

private struct WindowAccessorView: NSViewRepresentable {

    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowProbeView()
        resolveWindow(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(from: nsView)
    }

    private func resolveWindow(from view: NSView) {
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
    }
}

/// Zero-visual-footprint NSView that reports a valid intrinsicContentSize
/// to avoid AppKit "ambiguous height or width" warnings during auto-layout.
private final class WindowProbeView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }
}

private final class WindowStateObserver {
    static let shared = WindowStateObserver()

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

        // No aggressive window observers needed — macOS frame autosave
        // and the window manager handle positioning, resizing, and
        // screen changes automatically.
    }
}

// MARK: - Settings

private struct SettingsView: View {

    @Binding var packageRoot: String
    @ObservedObject private var commandAccess = CommandAccessPreferenceStore.shared
    @State private var apiKey: String = StudioCredentialStore.cachedValue(key: "anthropicAPIKey") ?? ""
    @State private var openAIKey: String = StudioCredentialStore.cachedValue(key: "openAIAPIKey") ?? ""
    @State private var showFolderPicker = false

    private var resolvedModels: [StudioModelDescriptor] {
        StudioModelStrategy.descriptors(packageRoot: packageRoot)
    }

    private var anthropicRoutedModels: [StudioModelDescriptor] {
        resolvedModels.filter { $0.provider == .anthropic }
    }

    private var openAIRoutedModels: [StudioModelDescriptor] {
        resolvedModels.filter { $0.provider == .openAI }
    }

    var body: some View {
        Form {
            Section("Package Root") {
                HStack {
                    TextField("Path to Studio.92", text: $packageRoot)
                        .textFieldStyle(.roundedBorder)
                        .font(StudioTypography.code)

                    Button("Browse...") {
                        showFolderPicker = true
                    }
                }

                if !packageRoot.isEmpty {
                    let valid = FileManager.default.fileExists(atPath: "\(packageRoot)/Package.swift")
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(valid ? StudioStatusColor.success : StudioTextColor.secondary)
                        Text(valid ? "Package.swift found" : "No Package.swift at this path")
                            .font(StudioTypography.footnote)
                            .foregroundStyle(StudioTextColor.secondary)
                    }
                }
            }

            Section("Model Routing") {
                VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                    Text("Studio.92 is now wired around explicit model roles instead of hidden provider switching.")
                        .font(StudioTypography.subheadline)
                        .foregroundStyle(StudioTextColor.secondary)

                    ForEach(resolvedModels, id: \.id) { model in
                        SettingsModelRoleCard(model: model)
                    }
                }
                .padding(.vertical, StudioSpacing.xs)
            }

            Section("Command Access") {
                VStack(alignment: .leading, spacing: StudioSpacing.lg) {
                    Picker("Access Scope", selection: $commandAccess.accessScope) {
                        ForEach(CommandAccessScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }

                    Text(commandAccess.accessScope.summary)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)

                    Picker("Approval Mode", selection: $commandAccess.approvalMode) {
                        ForEach(CommandApprovalMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(commandAccess.approvalMode.summary)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)

                    Text("Current runtime policy: \(commandAccess.snapshot.statusLine)")
                        .font(StudioTypography.dataCaption)
                        .foregroundStyle(StudioTextColor.secondary)
                }
                .padding(.vertical, StudioSpacing.xs)
            }

            Section("Anthropic Access") {
                SecureField("ANTHROPIC_API_KEY", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(StudioTypography.code)

                HStack(spacing: StudioSpacing.xs) {
                    Image(systemName: anthropicAccessReady ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(anthropicAccessReady ? StudioStatusColor.success : StudioTextColor.secondary)
                    Text(anthropicAccessStatus)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                }
            }

            Section("OpenAI Access") {
                SecureField("OPENAI_API_KEY", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(StudioTypography.code)

                HStack(spacing: StudioSpacing.xs) {
                    Image(systemName: openAIAccessReady ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(openAIAccessReady ? StudioStatusColor.success : StudioTextColor.secondary)
                    Text(openAIAccessStatus)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                }
            }

            AutomationSettingsSection(store: AutomationPreferenceStore.shared)
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onChange(of: apiKey) { _, newValue in
            StudioCredentialStore.save(key: "anthropicAPIKey", value: newValue)
        }
        .onChange(of: openAIKey) { _, newValue in
            StudioCredentialStore.save(key: "openAIAPIKey", value: newValue)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                packageRoot = url.path
            }
        }
        .task {
            if apiKey.isEmpty {
                apiKey = StudioCredentialStore.load(key: "anthropicAPIKey", allowKeychainImport: false) ?? ""
            }
            if openAIKey.isEmpty {
                openAIKey = StudioCredentialStore.load(key: "openAIAPIKey", allowKeychainImport: false) ?? ""
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
            return "Saved in Studio.92 — Anthropic-routed roles are ready."
        }

        if anthropicAccessReady {
            return "Using ANTHROPIC_API_KEY from the environment — Anthropic-routed roles are ready."
        }

        let labels = anthropicRoutedModels.map { $0.role.title }.joined(separator: ", ")
        return labels.isEmpty
            ? "No roles are currently routed to Anthropic."
            : "Needed for: \(labels)."
    }

    private var openAIAccessStatus: String {
        if !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Saved in Studio.92 — OpenAI-routed roles are ready."
        }

        if openAIAccessReady {
            return "Using OPENAI_API_KEY from the environment — OpenAI-routed roles are ready."
        }

        let labels = openAIRoutedModels.map { $0.role.title }.joined(separator: ", ")
        return labels.isEmpty
            ? "No roles are currently routed to OpenAI."
            : "Needed for: \(labels)."
    }
}

private struct SettingsModelRoleCard: View {

    let model: StudioModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack(alignment: .top, spacing: StudioSpacing.lg) {
                Image(systemName: model.role.symbolName)
                    .font(StudioTypography.subheadlineSemibold)
                    .foregroundStyle(StudioTextColor.secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    HStack(spacing: StudioSpacing.md) {
                        Text(model.role.title)
                            .font(StudioTypography.subheadlineSemibold)
                            .foregroundStyle(StudioTextColor.primary)

                        Text(model.displayName)
                            .font(StudioTypography.dataCaption)
                            .foregroundStyle(StudioTextColor.secondary)
                    }

                    Text(model.summary)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: StudioSpacing.md) {
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

                        if let verbosity = model.defaultVerbosity {
                            SettingsModelPill(
                                title: "Verbosity \(verbosity)",
                                systemImage: "text.justify.left"
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
        .padding(StudioSpacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
    }
}

private struct SettingsModelPill: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: systemImage)
                .font(StudioTypography.microSemibold)
            Text(title)
                .font(StudioTypography.dataMicro)
        }
        .foregroundStyle(StudioTextColor.primary)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(StudioSurfaceElevated.level2)
        )
    }
}

enum StudioCredentialStore {

    private struct Payload: Codable {
        var values: [String: String] = [:]
    }

    private static let fileName = "Credentials.json"

    static func cachedValue(key: String) -> String? {
        let trimmed = loadPayload().values[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static func load(key: String, allowKeychainImport: Bool = true) -> String? {
        if let cached = cachedValue(key: key) {
            return cached
        }

        guard allowKeychainImport,
              let imported = KeychainCredentialStore.load(key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imported.isEmpty else {
            return nil
        }

        save(key: key, value: imported, persistToKeychain: false)
        return imported
    }

    static func save(key: String, value: String, persistToKeychain: Bool = true) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = loadPayload()

        if trimmed.isEmpty {
            payload.values.removeValue(forKey: key)
        } else {
            payload.values[key] = trimmed
        }

        writePayload(payload)

        if persistToKeychain {
            if trimmed.isEmpty {
                KeychainCredentialStore.delete(key: key)
            } else {
                KeychainCredentialStore.save(key: key, value: trimmed)
            }
        }
    }

    static func delete(key: String) {
        save(key: key, value: "")
    }

    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        for key in ["anthropicAPIKey", "openAIAPIKey"] {
            if let existing = defaults.string(forKey: key),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               cachedValue(key: key) == nil {
                save(key: key, value: existing, persistToKeychain: true)
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func loadPayload() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return payload
    }

    private static func writePayload(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("[StudioCredentialStore] Write failed: \(error.localizedDescription)")
        }
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent(fileName)
    }
}

// MARK: - Keychain Credential Store

/// Stores API keys in the macOS Keychain instead of UserDefaults.
enum KeychainCredentialStore {

    private static let service = "com.studio92.CommandCenter"

    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Delete any existing item first.
        SecItemDelete(query as CFDictionary)

        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainCredentialStore] Save failed for \(key): \(status)")
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration

    /// One-time migration from UserDefaults to Keychain.
    /// Reads existing keys, moves them to Keychain, then removes from UserDefaults.
    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        for key in ["anthropicAPIKey", "openAIAPIKey"] {
            if let existing = defaults.string(forKey: key),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               load(key: key) == nil {
                save(key: key, value: existing)
                defaults.removeObject(forKey: key)
                print("[KeychainCredentialStore] Migrated \(key) from UserDefaults to Keychain")
            }
        }
    }
}
