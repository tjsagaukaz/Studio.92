import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

extension Notification.Name {
    static let studioShellCommandDidStart = Notification.Name("studioShellCommandDidStart")
    static let studioShellCommandDidFinish = Notification.Name("studioShellCommandDidFinish")
}

enum StudioShellCommandNotificationKey {
    static let id = "id"
    static let command = "command"
    static let projectRoot = "projectRoot"
    static let output = "output"
    static let exitStatus = "exitStatus"
}

enum SimulatorShellCommandNotifier {

    static func commandDidStart(id: String, command: String, projectRoot: String) {
        NotificationCenter.default.post(
            name: .studioShellCommandDidStart,
            object: nil,
            userInfo: [
                StudioShellCommandNotificationKey.id: id,
                StudioShellCommandNotificationKey.command: command,
                StudioShellCommandNotificationKey.projectRoot: projectRoot
            ]
        )
    }

    static func commandDidFinish(
        id: String,
        command: String,
        projectRoot: String,
        output: String,
        exitStatus: Int32
    ) {
        NotificationCenter.default.post(
            name: .studioShellCommandDidFinish,
            object: nil,
            userInfo: [
                StudioShellCommandNotificationKey.id: id,
                StudioShellCommandNotificationKey.command: command,
                StudioShellCommandNotificationKey.projectRoot: projectRoot,
                StudioShellCommandNotificationKey.output: output,
                StudioShellCommandNotificationKey.exitStatus: exitStatus
            ]
        )
    }
}

struct SimulatorDevice: Identifiable, Equatable {
    let name: String
    let runtime: String
    let runtimeVersion: [Int]
    let udid: String
    let state: String

    var id: String { udid }
    var isBooted: Bool { state.caseInsensitiveCompare("Booted") == .orderedSame }
    var isPhone: Bool { name.localizedCaseInsensitiveContains("iPhone") }
    var menuTitle: String { "\(name)  \(runtime)" }
}

@MainActor
@Observable
final class SimulatorPreviewService {

    static let shared = SimulatorPreviewService()

    var status: SimulatorPreviewStatus = .idle
    var latestScreenshotPath: String?
    var latestFrameFingerprint: String?
    var availableDevices: [SimulatorDevice] = []
    var selectedDeviceUDID: String?
    var deviceAspectRatio: CGFloat?
    var statusDetail = "Run a target to preview"

    var selectedDevice: SimulatorDevice? {
        if let selectedDeviceUDID,
           let matchedDevice = availableDevices.first(where: { $0.udid == selectedDeviceUDID }) {
            return matchedDevice
        }

        return availableDevices.first
    }

    var selectedDeviceName: String {
        selectedDevice?.name ?? "No Simulator"
    }

    var selectedDeviceRuntime: String {
        selectedDevice?.runtime ?? "Install an iOS runtime in Xcode"
    }

    var hasAvailableDevices: Bool {
        availableDevices.isEmpty == false
    }

    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var commandSession: MonitoredCommandSession?
    @ObservationIgnored private var currentCaptureDeviceUDID: String?
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private let captureIntervalNanoseconds: UInt64 = 100_000_000
    @ObservationIgnored private let selectedDeviceDefaultsKey = "studio92.selectedSimulatorUDID"
    @ObservationIgnored private let outputDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Studio92Viewport", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    func start() {
        guard observerTokens.isEmpty else { return }
        installShellObservers()

        Task {
            await refreshDevices(adoptBootedDevice: true)
            await restoreBootedSelectionIfNeeded()
        }
    }

    func stop() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()

        captureTask?.cancel()
        captureTask = nil
        currentCaptureDeviceUDID = nil
        commandSession = nil

        clearRetainedFrame()
        status = .idle
        statusDetail = "Run a target to preview"
    }

    func refreshInventory() {
        Task {
            await refreshDevices(adoptBootedDevice: true)
            await restoreBootedSelectionIfNeeded()
        }
    }

    func selectDevice(udid: String) {
        guard selectedDeviceUDID != udid else {
            Task {
                await bootSelectedDevice(reason: "Switching simulator")
            }
            return
        }

        let previousSelection = selectedDeviceUDID
        selectedDeviceUDID = udid
        UserDefaults.standard.set(udid, forKey: selectedDeviceDefaultsKey)

        if previousSelection != udid {
            clearRetainedFrame()
        }

        Task {
            await refreshDevices(adoptBootedDevice: false)
            await bootSelectedDevice(reason: "Switching simulator")
        }
    }

    private func installShellObservers() {
        let center = NotificationCenter.default

        observerTokens.append(
            center.addObserver(
                forName: .studioShellCommandDidStart,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleShellCommandDidStart(notification)
                }
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: .studioShellCommandDidFinish,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleShellCommandDidFinish(notification)
                }
            }
        )
    }

    private func handleShellCommandDidStart(_ notification: Notification) async {
        guard let payload = ShellCommandPayload(notification: notification),
              let kind = MonitoredCommandKind(command: payload.command),
              let projectRoot = payload.projectRootURL else {
            return
        }

        commandSession = MonitoredCommandSession(
            id: payload.id,
            command: payload.command,
            projectRoot: projectRoot,
            startedAt: Date(),
            kind: kind
        )

        await refreshDevices(adoptBootedDevice: true)
        await bootSelectedDevice(reason: "Preparing \(selectedDeviceName)")
    }

    private func handleShellCommandDidFinish(_ notification: Notification) async {
        guard let payload = ShellCommandPayload(notification: notification),
              let session = commandSession,
              session.id == payload.id else {
            return
        }

        defer {
            commandSession = nil
        }

        if payload.exitStatus == 0 {
            await installAndLaunchIfNeeded(for: session, output: payload.output)
        }

        await refreshDevices(adoptBootedDevice: false)
        await restoreBootedSelectionIfNeeded()
    }

    private func restoreBootedSelectionIfNeeded() async {
        guard let selectedDevice else {
            captureTask?.cancel()
            captureTask = nil
            currentCaptureDeviceUDID = nil
            clearRetainedFrame()
            status = .idle
            statusDetail = hasAvailableDevices ? "Run a target to preview" : "Install an iOS runtime in Xcode"
            return
        }

        if selectedDevice.isBooted {
            status = latestScreenshotPath == nil ? .booting : .attached
            statusDetail = selectedDevice.runtime
            startCaptureLoop(for: selectedDevice.udid, preserveFrame: true)
            return
        }

        captureTask?.cancel()
        captureTask = nil
        currentCaptureDeviceUDID = nil
        clearRetainedFrame()
        status = .idle
        statusDetail = "Run a target to preview"
    }

    private func bootSelectedDevice(reason: String) async {
        guard let device = selectedDevice else {
            status = .idle
            statusDetail = hasAvailableDevices ? "Run a target to preview" : "Install an iOS runtime in Xcode"
            return
        }

        status = .booting
        statusDetail = reason

        let result = await Task.detached(priority: .userInitiated) {
            Self.bootDevice(udid: device.udid)
        }.value

        await refreshDevices(adoptBootedDevice: false)

        if result {
            status = .booting
            statusDetail = device.runtime
            startCaptureLoop(for: device.udid, preserveFrame: true)
        } else {
            clearRetainedFrame()
            status = .idle
            statusDetail = "Run a target to preview"
        }
    }

    private func startCaptureLoop(for udid: String, preserveFrame: Bool) {
        if preserveFrame == false {
            clearRetainedFrame()
        }

        if currentCaptureDeviceUDID == udid, captureTask != nil {
            return
        }

        captureTask?.cancel()
        currentCaptureDeviceUDID = udid

        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.runCaptureLoop(deviceUDID: udid)
        }
    }

    private func runCaptureLoop(deviceUDID: String) async {
        while Task.isCancelled == false {
            await captureFrame(for: deviceUDID)

            if Task.isCancelled {
                break
            }

            try? await Task.sleep(nanoseconds: captureIntervalNanoseconds)
        }
    }

    private func captureFrame(for deviceUDID: String) async {
        let outputDirectory = self.outputDirectory
        let result = await Task.detached(priority: .utility) {
            Self.captureFrame(for: deviceUDID, in: outputDirectory)
        }.value

        guard Task.isCancelled == false else { return }
        guard currentCaptureDeviceUDID == deviceUDID else { return }

        switch result {
        case .success(let frame):
            if frame.fingerprint == latestFrameFingerprint {
                try? FileManager.default.removeItem(atPath: frame.path)
                if status == .booting {
                    status = .attached
                }
                if let selectedDevice {
                    statusDetail = selectedDevice.runtime
                }
                return
            }

            let previousPath = latestScreenshotPath
            latestScreenshotPath = frame.path
            latestFrameFingerprint = frame.fingerprint
            deviceAspectRatio = frame.aspectRatio
            status = .attached

            if let selectedDevice {
                statusDetail = selectedDevice.runtime
            }

            if let previousPath, previousPath != frame.path {
                try? FileManager.default.removeItem(atPath: previousPath)
            }

        case .deviceNotBooted:
            clearRetainedFrame()
            captureTask?.cancel()
            captureTask = nil
            currentCaptureDeviceUDID = nil
            status = .idle
            statusDetail = "Run a target to preview"

        case .failure:
            if latestScreenshotPath == nil {
                status = commandSession == nil ? .idle : .booting
            }
        }
    }

    private func refreshDevices(adoptBootedDevice: Bool) async {
        let refreshedDevices = await Task.detached(priority: .userInitiated) {
            Self.loadAvailableDevices()
        }.value

        availableDevices = refreshedDevices

        let storedSelection = UserDefaults.standard.string(forKey: selectedDeviceDefaultsKey)
        let currentSelection = selectedDeviceUDID ?? storedSelection

        if let currentSelection,
           refreshedDevices.contains(where: { $0.udid == currentSelection }) {
            selectedDeviceUDID = currentSelection
        } else if adoptBootedDevice,
                  let bootedDevice = refreshedDevices.first(where: \.isBooted) {
            selectedDeviceUDID = bootedDevice.udid
        } else {
            selectedDeviceUDID = refreshedDevices.first?.udid
        }

        if let selectedDeviceUDID {
            UserDefaults.standard.set(selectedDeviceUDID, forKey: selectedDeviceDefaultsKey)
        }
    }

    private func clearRetainedFrame() {
        if let latestScreenshotPath {
            try? FileManager.default.removeItem(atPath: latestScreenshotPath)
        }

        latestScreenshotPath = nil
        latestFrameFingerprint = nil
        deviceAspectRatio = nil
    }

    private func installAndLaunchIfNeeded(
        for session: MonitoredCommandSession,
        output: String
    ) async {
        guard let selectedDevice else { return }
        guard session.kind.shouldAttemptPostRunLaunch else { return }

        let launchTarget = await Task.detached(priority: .userInitiated) {
            Self.resolveLaunchTarget(
                for: session,
                output: output
            )
        }.value

        guard let launchTarget else { return }

        status = .booting
        statusDetail = "Launching \(launchTarget.displayName)"

        _ = await Task.detached(priority: .userInitiated) {
            Self.installAndLaunch(
                launchTarget,
                deviceUDID: selectedDevice.udid
            )
        }.value
    }

    nonisolated private static func loadAvailableDevices() -> [SimulatorDevice] {
        let result = runCommand(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "-j", "devices", "available"]
        )

        guard result.terminationStatus == 0,
              let data = result.standardOutput.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SimctlDeviceListResponse.self, from: data) else {
            return []
        }

        let devices: [SimulatorDevice] = decoded.devices.flatMap { runtimeID, devices in
            guard runtimeID.contains(".iOS-") else { return [SimulatorDevice]() }
            let (runtimeTitle, version) = readableRuntime(from: runtimeID)

            return devices.map { device in
                SimulatorDevice(
                    name: device.name,
                    runtime: runtimeTitle,
                    runtimeVersion: version,
                    udid: device.udid,
                    state: device.state
                )
            }
        }

        return devices.sorted { lhs, rhs in
            if lhs.isBooted != rhs.isBooted {
                return lhs.isBooted && rhs.isBooted == false
            }

            if lhs.isPhone != rhs.isPhone {
                return lhs.isPhone && rhs.isPhone == false
            }

            if lhs.runtimeVersion != rhs.runtimeVersion {
                return lhs.runtimeVersion.lexicographicallyPrecedes(rhs.runtimeVersion) == false
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func readableRuntime(from runtimeID: String) -> (String, [Int]) {
        let runtimeToken = runtimeID
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        let components = runtimeToken.split(separator: "-")

        guard let platformToken = components.first else {
            return ("iOS", [])
        }

        let platform = String(platformToken)

        let versionNumbers = components.dropFirst().compactMap { Int($0) }
        let versionLabel = versionNumbers
            .map(String.init)
            .joined(separator: ".")

        if versionLabel.isEmpty {
            return (platform, versionNumbers)
        }

        return ("\(platform) \(versionLabel)", versionNumbers)
    }

    nonisolated private static func bootDevice(udid: String) -> Bool {
        let bootResult = runCommand(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", udid, "-b"]
        )

        guard bootResult.terminationStatus == 0 else {
            return false
        }

        _ = runCommand(
            executablePath: "/usr/bin/open",
            arguments: ["-a", "Simulator"]
        )

        return true
    }

    nonisolated private static func captureFrame(
        for deviceUDID: String,
        in outputDirectory: URL
    ) -> CaptureResult {
        let fileURL = outputDirectory
            .appendingPathComponent("\(deviceUDID)-\(UUID().uuidString).png")

        let screenshotResult = runCommand(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "simctl",
                "io",
                deviceUDID,
                "screenshot",
                "--type=png",
                fileURL.path
            ]
        )

        guard screenshotResult.terminationStatus == 0,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let aspectRatio = imageAspectRatio(data: data) else {
            let diagnostic = "\(screenshotResult.standardOutput)\n\(screenshotResult.standardError)"
                .lowercased()
            if diagnostic.contains("shutdown")
                || diagnostic.contains("unable to find")
                || diagnostic.contains("device is not booted") {
                return .deviceNotBooted
            }

            try? FileManager.default.removeItem(at: fileURL)
            return .failure
        }

        let fingerprint = SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()

        return .success(
            CapturedFrame(
                path: fileURL.path,
                fingerprint: fingerprint,
                aspectRatio: aspectRatio
            )
        )
    }

    nonisolated private static func imageAspectRatio(data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              height > 0 else {
            return nil
        }

        return width / height
    }

    nonisolated private static func resolveLaunchTarget(
        for session: MonitoredCommandSession,
        output: String
    ) -> LaunchTarget? {
        let bundleIdentifier = extractBundleIdentifier(from: output)
        let appPathCandidates = candidateAppPaths(in: output).map(URL.init(fileURLWithPath:))

        let discoveredAppURL = appPathCandidates.first(where: { isLaunchableAppBundle(at: $0) })
            ?? mostRecentBuildApp(in: session.projectRoot, since: session.startedAt)
            ?? mostRecentDerivedDataApp(since: session.startedAt)

        if let discoveredAppURL {
            let resolvedBundleIdentifier = bundleIdentifier ?? bundleIdentifierForApp(at: discoveredAppURL)
            guard let resolvedBundleIdentifier else { return nil }
            return LaunchTarget(
                appURL: discoveredAppURL,
                bundleIdentifier: resolvedBundleIdentifier,
                displayName: appDisplayName(at: discoveredAppURL)
            )
        }

        guard let bundleIdentifier else { return nil }
        return LaunchTarget(
            appURL: nil,
            bundleIdentifier: bundleIdentifier,
            displayName: bundleIdentifier
        )
    }

    nonisolated private static func candidateAppPaths(in output: String) -> [String] {
        let patterns = [
            #""(/[^"\n]+?\.app)""#,
            #"'(/[^'\n]+?\.app)'"#,
            #"(\/\S+?\.app)"#
        ]

        var matches: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)

            for match in regex.matches(in: output, range: range) {
                let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                guard let stringRange = Range(captureRange, in: output) else { continue }

                let rawPath = String(output[stringRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),:"))

                if matches.contains(rawPath) == false {
                    matches.append(rawPath)
                }
            }
        }

        return matches
    }

    nonisolated private static func extractBundleIdentifier(from output: String) -> String? {
        let patterns = [
            #"simctl launch\s+\S+\s+([A-Za-z0-9._-]+)"#,
            #"bundle identifier[:=]\s*([A-Za-z0-9._-]+)"#,
            #"launching\s+([A-Za-z0-9._-]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            guard let match = regex.firstMatch(in: output, range: range),
                  let captureRange = Range(match.range(at: 1), in: output) else {
                continue
            }

            return String(output[captureRange])
        }

        return nil
    }

    nonisolated private static func mostRecentBuildApp(
        in projectRoot: URL,
        since startDate: Date
    ) -> URL? {
        let candidateRoots = [
            projectRoot.appendingPathComponent("build", isDirectory: true),
            projectRoot.appendingPathComponent("ios", isDirectory: true)
        ]

        return mostRecentApp(in: candidateRoots, since: startDate)
    }

    nonisolated private static func mostRecentDerivedDataApp(since startDate: Date) -> URL? {
        let derivedDataRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        return mostRecentApp(in: [derivedDataRoot], since: startDate)
    }

    nonisolated private static func mostRecentApp(
        in roots: [URL],
        since startDate: Date
    ) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var bestCandidate: (url: URL, date: Date)?

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app",
                      url.path.lowercased().contains("iphonesimulator"),
                      isLaunchableAppBundle(at: url) else {
                    continue
                }

                let values = try? url.resourceValues(forKeys: Set(keys))
                let modificationDate = values?.contentModificationDate ?? .distantPast

                guard modificationDate >= startDate.addingTimeInterval(-60) else {
                    continue
                }

                if let bestDate = bestCandidate?.date, bestDate >= modificationDate {
                    continue
                }

                bestCandidate = (url, modificationDate)
            }
        }

        return bestCandidate?.url
    }

    nonisolated private static func isLaunchableAppBundle(at url: URL) -> Bool {
        let lastComponent = url.lastPathComponent.lowercased()

        if lastComponent.contains("tests")
            || url.path.contains("/Frameworks/")
            || url.path.contains("/PlugIns/") {
            return false
        }

        return bundleIdentifierForApp(at: url) != nil
    }

    nonisolated private static func bundleIdentifierForApp(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              let packageType = plist["CFBundlePackageType"] as? String,
              packageType == "APPL" else {
            return nil
        }

        return plist["CFBundleIdentifier"] as? String
    }

    nonisolated private static func appDisplayName(at appURL: URL) -> String {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else {
            return appURL.deletingPathExtension().lastPathComponent
        }

        if let displayName = plist["CFBundleDisplayName"] as? String,
           displayName.isEmpty == false {
            return displayName
        }

        if let bundleName = plist["CFBundleName"] as? String,
           bundleName.isEmpty == false {
            return bundleName
        }

        return appURL.deletingPathExtension().lastPathComponent
    }

    nonisolated private static func installAndLaunch(
        _ launchTarget: LaunchTarget,
        deviceUDID: String
    ) -> Bool {
        if let appURL = launchTarget.appURL {
            let installResult = runCommand(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "install", deviceUDID, appURL.path]
            )

            guard installResult.terminationStatus == 0 else {
                return false
            }
        }

        let launchResult = runCommand(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "simctl",
                "launch",
                "--terminate-running-process",
                deviceUDID,
                launchTarget.bundleIdentifier
            ]
        )

        return launchResult.terminationStatus == 0
    }

    nonisolated private static func runCommand(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: Double = 60
    ) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            return CommandResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        // Timeout watchdog: terminate if the process hangs.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let standardOutput = String(
            decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let standardError = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}

private struct ShellCommandPayload {
    let id: String
    let command: String
    let projectRoot: String
    let output: String
    let exitStatus: Int32

    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo[StudioShellCommandNotificationKey.id] as? String,
              let command = userInfo[StudioShellCommandNotificationKey.command] as? String,
              let projectRoot = userInfo[StudioShellCommandNotificationKey.projectRoot] as? String else {
            return nil
        }

        self.id = id
        self.command = command
        self.projectRoot = projectRoot
        self.output = userInfo[StudioShellCommandNotificationKey.output] as? String ?? ""

        if let exitStatus = userInfo[StudioShellCommandNotificationKey.exitStatus] as? Int32 {
            self.exitStatus = exitStatus
        } else if let exitStatus = userInfo[StudioShellCommandNotificationKey.exitStatus] as? Int {
            self.exitStatus = Int32(exitStatus)
        } else if let exitStatus = userInfo[StudioShellCommandNotificationKey.exitStatus] as? NSNumber {
            self.exitStatus = exitStatus.int32Value
        } else {
            self.exitStatus = 0
        }
    }

    var projectRootURL: URL? {
        guard projectRoot.isEmpty == false else { return nil }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
    }
}

private struct MonitoredCommandSession {
    let id: String
    let command: String
    let projectRoot: URL
    let startedAt: Date
    let kind: MonitoredCommandKind
}

private enum MonitoredCommandKind {
    case xcodebuildBuild
    case xcodebuildTest
    case reactNative
    case expo
    case flutter

    init?(command: String) {
        let normalizedCommand = command.lowercased()

        if normalizedCommand.contains("flutter run") {
            self = .flutter
            return
        }

        if normalizedCommand.contains("expo run:ios") {
            self = .expo
            return
        }

        if normalizedCommand.contains("react-native run-ios")
            || normalizedCommand.contains("npm run ios")
            || normalizedCommand.contains("yarn ios")
            || normalizedCommand.contains("pnpm ios") {
            self = .reactNative
            return
        }

        guard normalizedCommand.contains("xcodebuild") else {
            return nil
        }

        if normalizedCommand.contains(" test")
            || normalizedCommand.contains("build-for-testing")
            || normalizedCommand.contains("test-without-building") {
            self = .xcodebuildTest
            return
        }

        self = .xcodebuildBuild
    }

    var shouldAttemptPostRunLaunch: Bool {
        switch self {
        case .xcodebuildBuild:
            return true
        case .xcodebuildTest, .reactNative, .expo, .flutter:
            return false
        }
    }
}

private struct LaunchTarget {
    let appURL: URL?
    let bundleIdentifier: String
    let displayName: String
}

private struct CapturedFrame {
    let path: String
    let fingerprint: String
    let aspectRatio: CGFloat
}

private struct CommandResult {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

private struct SimctlDeviceListResponse: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let udid: String
    let name: String
    let state: String
}

private enum CaptureResult {
    case success(CapturedFrame)
    case deviceNotBooted
    case failure
}
