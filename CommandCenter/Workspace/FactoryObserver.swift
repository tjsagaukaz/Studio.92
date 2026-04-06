// FactoryObserver.swift
// Studio.92 — Command Center
// Watches ~/.darkfactory/telemetry/ for new packet JSON files.
// Uses DispatchSource for non-blocking directory monitoring.

import Foundation

/// Monitors the telemetry inbox directory for new .json files.
/// When a new file appears, calls the `onNewFile` handler.
final class FactoryObserver {

    static let telemetryDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".darkfactory/telemetry", isDirectory: true)
    }()

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var knownFiles: Set<String> = []
    private let onNewFile: (URL) -> Void

    /// - Parameter onNewFile: Called on a background queue when a new .json file is detected.
    init(onNewFile: @escaping (URL) -> Void) {
        self.onNewFile = onNewFile
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        let fm = FileManager.default
        let dir = Self.telemetryDir

        // Create the telemetry directory if it doesn't exist
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Snapshot existing files so we don't re-ingest on launch
        knownFiles = currentFileNames()

        // Open the directory for monitoring
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else {
            print("[FactoryObserver] Failed to open directory: \(dir.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.scanForNewFiles()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }

        self.source = source
        source.resume()

        print("[FactoryObserver] Watching: \(dir.path)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    // MARK: - Scanning

    private func scanForNewFiles() {
        let currentFiles = currentFileNames()
        let newFiles = currentFiles.subtracting(knownFiles)

        for fileName in newFiles.sorted() {
            let url = Self.telemetryDir.appendingPathComponent(fileName)

            // Stability window: verify file isn't still being written.
            // Read size, wait 50ms, re-read — only ingest if stable.
            guard let size1 = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { continue }
            Thread.sleep(forTimeInterval: 0.05)
            guard let size2 = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                  size1 == size2, size1 > 0 else { continue }

            onNewFile(url)
        }

        knownFiles = currentFiles
    }

    private func currentFileNames() -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: Self.telemetryDir.path) else {
            return []
        }
        return Set(contents.filter { $0.hasSuffix(".json") })
    }

    // MARK: - Telemetry Directory Helper

    /// Write a packet JSON file to the telemetry inbox.
    /// Called by run_factory.sh or PipelineRunner after a successful deliberation.
    static func dropTelemetry(packetJSON: String, packetID: String) {
        let fm = FileManager.default
        let dir = telemetryDir

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let fileName = "\(packetID).json"
        let fileURL = dir.appendingPathComponent(fileName)

        try? packetJSON.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
