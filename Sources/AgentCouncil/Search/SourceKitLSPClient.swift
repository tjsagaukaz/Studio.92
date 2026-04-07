import Foundation

actor SourceKitLSPClient {

    struct DefinitionLocation: Equatable, Sendable {
        let path: String
        let line: Int
        let column: Int
    }

    struct PrepareRenameResult: Equatable, Sendable {
        let placeholder: String
        let line: Int
        let column: Int
    }

    struct DocumentDiagnostic: Equatable, Sendable {
        let severity: Int?
        let message: String
        let line: Int
        let column: Int
        let source: String?
    }

    enum Error: LocalizedError {
        case requestFailed(String)
        case invalidResponse(String)
        case processLaunchFailed(String)
        case missingFile(URL)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let message), .invalidResponse(let message), .processLaunchFailed(let message):
                return message
            case .missingFile(let url):
                return "SourceKit file not found: \(url.path)"
            }
        }
    }

    private let projectRoot: URL

    init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
    }

    func definition(fileURL: URL, line: Int, utf8Column: Int) async throws -> [DefinitionLocation] {
        try await withSession(for: fileURL) { session in
            let text = try Self.readText(at: fileURL)
            try session.openDocument(fileURL, text: text)
            let result = try session.sendRequest(
                method: "textDocument/definition",
                params: [
                    "textDocument": ["uri": fileURL.standardizedFileURL.absoluteString],
                    "position": Self.positionPayload(line: line, utf8Column: utf8Column, in: text)
                ]
            )
            return Self.decodeDefinitionLocations(from: result)
        }
    }

    func prepareRename(fileURL: URL, line: Int, utf8Column: Int) async throws -> PrepareRenameResult? {
        try await withSession(for: fileURL) { session in
            let text = try Self.readText(at: fileURL)
            try session.openDocument(fileURL, text: text)
            let result = try session.sendRequest(
                method: "textDocument/prepareRename",
                params: [
                    "textDocument": ["uri": fileURL.standardizedFileURL.absoluteString],
                    "position": Self.positionPayload(line: line, utf8Column: utf8Column, in: text)
                ]
            )
            return Self.decodePrepareRename(from: result, text: text)
        }
    }

    func documentDiagnostics(fileURL: URL) async throws -> [DocumentDiagnostic] {
        try await withSession(for: fileURL) { session in
            let text = try Self.readText(at: fileURL)
            try session.openDocument(fileURL, text: text)
            let result = try session.sendRequest(
                method: "textDocument/diagnostic",
                params: [
                    "textDocument": ["uri": fileURL.standardizedFileURL.absoluteString]
                ]
            )
            return Self.decodeDiagnostics(from: result, text: text)
        }
    }

    private func withSession<T>(for fileURL: URL, _ body: (SourceKitLSPProcessSession) throws -> T) async throws -> T {
        let workspaceRoot = sourceKitWorkspaceRoot(for: fileURL)
        let session = try SourceKitLSPProcessSession(workspaceRoot: workspaceRoot)
        defer { session.terminate() }
        try session.initialize()
        defer { try? session.shutdown() }
        return try body(session)
    }

    private func sourceKitWorkspaceRoot(for fileURL: URL) -> URL {
        let normalizedFile = fileURL.standardizedFileURL.path
        let commandCenterRoot = projectRoot.appendingPathComponent("CommandCenter", isDirectory: true)
        if normalizedFile.hasPrefix(commandCenterRoot.path + "/") {
            return commandCenterRoot
        }
        return projectRoot
    }

    private static func readText(at fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Error.missingFile(fileURL)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func positionPayload(line: Int, utf8Column: Int, in text: String) -> [String: Any] {
        let zeroBasedLine = max(0, line - 1)
        let zeroBasedUTF16Column = max(0, utf16Column(fromUTF8Column: utf8Column, line: line, in: text) - 1)
        return [
            "line": zeroBasedLine,
            "character": zeroBasedUTF16Column
        ]
    }

    private static func decodeDefinitionLocations(from value: AnyCodableValue?) -> [DefinitionLocation] {
        let items: [AnyCodableValue]
        switch value {
        case .array(let array):
            items = array
        case .object:
            items = value.map { [$0] } ?? []
        default:
            return []
        }

        return items.compactMap { item in
            guard let object = item.objectValue else { return nil }
            if let uri = object["uri"]?.stringValue,
               let range = object["range"]?.objectValue,
               let start = range["start"]?.objectValue,
               let location = definitionLocation(uri: uri, start: start) {
                return location
            }

            if let uri = object["targetUri"]?.stringValue,
               let range = object["targetSelectionRange"]?.objectValue ?? object["targetRange"]?.objectValue,
               let start = range["start"]?.objectValue,
               let location = definitionLocation(uri: uri, start: start) {
                return location
            }

            return nil
        }
        .sorted { lhs, rhs in
            (lhs.path, lhs.line, lhs.column) < (rhs.path, rhs.line, rhs.column)
        }
    }

    private static func definitionLocation(uri: String, start: [String: AnyCodableValue]) -> DefinitionLocation? {
        guard let fileURL = URL(string: uri)?.standardizedFileURL,
              fileURL.isFileURL,
              let line = start["line"]?.intValue,
              let character = start["character"]?.intValue else {
            return nil
        }
        return DefinitionLocation(path: fileURL.path, line: line + 1, column: character + 1)
    }

    private static func decodePrepareRename(from value: AnyCodableValue?, text: String) -> PrepareRenameResult? {
        guard let object = value?.objectValue,
              let placeholder = object["placeholder"]?.stringValue,
              let range = object["range"]?.objectValue,
              let start = range["start"]?.objectValue,
              let zeroBasedLine = start["line"]?.intValue,
              let zeroBasedCharacter = start["character"]?.intValue else {
            return nil
        }

        let line = zeroBasedLine + 1
        let utf8Column = utf8Column(fromUTF16Character: zeroBasedCharacter + 1, line: line, in: text)
        return PrepareRenameResult(placeholder: placeholder, line: line, column: utf8Column)
    }

    private static func decodeDiagnostics(from value: AnyCodableValue?, text: String) -> [DocumentDiagnostic] {
        guard let object = value?.objectValue,
              let items = object["items"]?.arrayValue else {
            return []
        }

        return items.compactMap { item in
            guard let object = item.objectValue,
                  let range = object["range"]?.objectValue,
                  let start = range["start"]?.objectValue,
                  let zeroBasedLine = start["line"]?.intValue,
                  let zeroBasedCharacter = start["character"]?.intValue,
                  let message = object["message"]?.stringValue else {
                return nil
            }

            let line = zeroBasedLine + 1
            let column = utf8Column(fromUTF16Character: zeroBasedCharacter + 1, line: line, in: text)
            return DocumentDiagnostic(
                severity: object["severity"]?.intValue,
                message: message,
                line: line,
                column: column,
                source: object["source"]?.stringValue
            )
        }
        .sorted { lhs, rhs in
            (lhs.line, lhs.column, lhs.message) < (rhs.line, rhs.column, rhs.message)
        }
    }

    private static func utf16Column(fromUTF8Column utf8Column: Int, line: Int, in text: String) -> Int {
        guard let lineText = lineText(line: line, in: text) else { return utf8Column }
        let targetOffset = max(0, utf8Column - 1)
        var runningOffset = 0
        var index = lineText.startIndex

        while index < lineText.endIndex {
            if runningOffset >= targetOffset {
                break
            }
            let next = lineText.index(after: index)
            runningOffset += String(lineText[index..<next]).utf8.count
            index = next
        }

        return lineText[..<index].utf16.count + 1
    }

    private static func utf8Column(fromUTF16Character utf16Character: Int, line: Int, in text: String) -> Int {
        guard let lineText = lineText(line: line, in: text) else { return utf16Character }
        let targetOffset = max(0, utf16Character - 1)
        var runningOffset = 0
        var index = lineText.startIndex

        while index < lineText.endIndex {
            let consumed = lineText[..<index].utf16.count
            if consumed >= targetOffset {
                break
            }
            index = lineText.index(after: index)
            runningOffset = lineText[..<index].utf8.count
        }

        return runningOffset + 1
    }

    private static func lineText(line: Int, in text: String) -> Substring? {
        guard line > 0 else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line - 1 < lines.count else { return nil }
        return lines[line - 1]
    }
}

private final class SourceKitLSPProcessSession {

    private struct JSONRPCEnvelope: Decodable {
        let id: Int?
        let result: AnyCodableValue?
        let error: JSONRPCErrorPayload?
        let method: String?
    }

    private struct JSONRPCErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private let workspaceRoot: URL
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var openedURIs = Set<String>()

    init(workspaceRoot: URL) throws {
        self.workspaceRoot = workspaceRoot.standardizedFileURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var arguments = ["sourcekit-lsp"]
        if FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("Package.swift").path) {
            arguments.append(contentsOf: ["--default-workspace-type", "swiftPM"])
        }

        process.arguments = arguments
        process.currentDirectoryURL = workspaceRoot
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SourceKitLSPClient.Error.processLaunchFailed("Failed to launch sourcekit-lsp: \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
    }

    func initialize() throws {
        _ = try sendRequest(
            method: "initialize",
            params: [
                "processId": Int(ProcessInfo.processInfo.processIdentifier),
                "rootUri": workspaceRoot.absoluteString,
                "capabilities": [:],
                "clientInfo": [
                    "name": "Studio.92",
                    "version": "phase-c"
                ],
                "workspaceFolders": [[
                    "uri": workspaceRoot.absoluteString,
                    "name": workspaceRoot.lastPathComponent
                ]]
            ]
        )
        try sendNotification(method: "initialized", params: [:])
    }

    func openDocument(_ fileURL: URL, text: String) throws {
        let uri = fileURL.standardizedFileURL.absoluteString
        guard !openedURIs.contains(uri) else { return }
        try sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": "swift",
                    "version": 1,
                    "text": text
                ]
            ]
        )
        openedURIs.insert(uri)
    }

    func shutdown() throws {
        for uri in openedURIs.sorted() {
            try? sendNotification(
                method: "textDocument/didClose",
                params: ["textDocument": ["uri": uri]]
            )
        }
        openedURIs.removeAll()
        _ = try? sendRequest(method: "shutdown", params: [:])
        try? sendNotification(method: "exit", params: [:])
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func sendRequest(method: String, params: [String: Any]) throws -> AnyCodableValue? {
        let id = nextRequestID
        nextRequestID += 1
        try writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        while true {
            let envelope = try readEnvelope()
            if envelope.id == id {
                if let error = envelope.error {
                    throw SourceKitLSPClient.Error.requestFailed("sourcekit-lsp \(method) failed (\(error.code)): \(error.message)")
                }
                return envelope.result
            }
        }
    }

    func sendNotification(method: String, params: [String: Any]) throws {
        try writeMessage([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    private func writeMessage(_ payload: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            throw SourceKitLSPClient.Error.invalidResponse("Failed to encode JSON-RPC header.")
        }
        stdinHandle.write(headerData)
        stdinHandle.write(body)
    }

    private func readEnvelope() throws -> JSONRPCEnvelope {
        let message = try readMessageBody()
        return try JSONDecoder().decode(JSONRPCEnvelope.self, from: message)
    }

    private func readMessageBody() throws -> Data {
        while true {
            if let boundary = stdoutBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = stdoutBuffer.subdata(in: 0..<boundary.lowerBound)
                guard let header = String(data: headerData, encoding: .utf8) else {
                    throw SourceKitLSPClient.Error.invalidResponse("Invalid JSON-RPC header encoding.")
                }
                let contentLength = header
                    .split(separator: "\r\n")
                    .compactMap { line -> Int? in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2,
                              parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
                            return nil
                        }
                        return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .first

                guard let contentLength else {
                    throw SourceKitLSPClient.Error.invalidResponse("Missing Content-Length in JSON-RPC header.")
                }

                let bodyStart = boundary.upperBound
                let requiredCount = bodyStart + contentLength
                while stdoutBuffer.count < requiredCount {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty {
                        let stderr = String(decoding: stderrHandle.readDataToEndOfFile(), as: UTF8.self)
                        throw SourceKitLSPClient.Error.invalidResponse(
                            stderr.isEmpty ? "sourcekit-lsp terminated while reading response." : stderr
                        )
                    }
                    stdoutBuffer.append(chunk)
                }

                let body = stdoutBuffer.subdata(in: bodyStart..<requiredCount)
                stdoutBuffer.removeSubrange(0..<requiredCount)
                return body
            }

            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                let stderr = String(decoding: stderrHandle.readDataToEndOfFile(), as: UTF8.self)
                throw SourceKitLSPClient.Error.invalidResponse(
                    stderr.isEmpty ? "sourcekit-lsp terminated without producing a response." : stderr
                )
            }
            stdoutBuffer.append(chunk)
        }
    }
}

private extension AnyCodableValue {
    var objectValue: [String: AnyCodableValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AnyCodableValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }
}