// ClaudeAPIClient.swift
// Studio.92 — Agent Council
// URLSession-based client for the Anthropic Messages API.
// No third-party dependencies — pure Foundation.

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

public actor ClaudeAPIClient {

    // MARK: Configuration

    private let apiKey:  String
    private let baseURL: URL
    private let session: URLSession

    /// Anthropic API version header value. Override via `STUDIO_ANTHROPIC_API_VERSION` env var.
    private static let apiVersion: String =
        ProcessInfo.processInfo.environment["STUDIO_ANTHROPIC_API_VERSION"] ?? "2023-06-01"
    private static let transientStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    private static let maxRetryAttempts = 3
    private static let maxRetryDelay: TimeInterval = 12
    /// Endpoint path for the Messages API.
    private static let messagesPath = "/v1/messages"
    /// Endpoint path for the token counting API.
    private static let countTokensPath = "/v1/messages/count_tokens"
    private static let anthropicBaseURL: URL =
        URL(string: ProcessInfo.processInfo.environment["STUDIO_ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com")!
    /// Anthropic beta header for interleaved thinking.
    private static let betaVersion = "interleaved-thinking-2025-05-14"
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    public init(apiKey: String, baseURL: URL? = nil, session: URLSession? = nil) throws {
        guard !apiKey.isEmpty else { throw OrchestratorError.missingAPIKey }
        self.apiKey  = apiKey
        self.baseURL = baseURL ?? Self.anthropicBaseURL
        self.session = session ?? Self.makeDefaultSession()
    }

    /// Convenience initialiser that reads from the environment.
    public init(session: URLSession? = nil) throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !key.isEmpty else {
            throw OrchestratorError.missingAPIKey
        }
        try self.init(apiKey: key, session: session)
    }

    // MARK: - Messages API

    /// Send a single turn to the Messages API and return the response.
    ///
    /// - Parameters:
    ///   - system:      System prompt (persona + constraints).
    ///   - messages:    Conversation turn(s). Typically one user message.
    ///   - model:       Claude model to use.
    ///   - maxTokens:   Upper bound on response tokens (default 2048).
    ///   - temperature: Sampling temperature (default 0.2 for structured output).
    public func complete(
        system:      String,
        messages:    [ClaudeMessage],
        model:       ClaudeModel = .sonnet,
        maxTokens:   Int         = 2048,
        temperature: Double      = 0.2,
        cacheControl: CacheControl? = nil
    ) async throws -> ClaudeResponse {
        let request = ClaudeRequest(
            model:       model.rawValue,
            maxTokens:   maxTokens,
            system:      system,
            messages:    messages,
            temperature: temperature,
            cacheControl: cacheControl
        )
        return try await send(request)
    }

    // MARK: - Token Counting API

    /// Count input tokens for a would-be message request without creating a response.
    public func countTokens(
        system: String,
        messages: [ClaudeMessage],
        model: ClaudeModel = .sonnet,
        tools: [ToolDefinition]? = nil,
        thinking: ThinkingConfig? = nil,
        cacheControl: CacheControl? = nil
    ) async throws -> ClaudeTokenCountResponse {
        let request = ClaudeTokenCountRequest(
            model: model.rawValue,
            system: system,
            messages: messages,
            tools: tools,
            thinking: thinking,
            cacheControl: cacheControl
        )

        let url = baseURL.appendingPathComponent(Self.countTokensPath)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let betaHeader = Self.anthropicBetaHeader(for: request.model, thinking: request.thinking) {
            urlRequest.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let data = try await performDataRequest(urlRequest)

        return try JSONDecoder().decode(ClaudeTokenCountResponse.self, from: data)
    }

    // MARK: - Streaming Messages API

    /// Stream a conversation turn, yielding typed events as they arrive via SSE.
    ///
    /// The caller consumes the returned `AsyncThrowingStream` and receives
    /// `StreamEvent` values (text deltas, tool_use blocks, thinking, etc.)
    /// in real time — no buffering until the full response is available.
    ///
    /// Cancelling the consuming Task automatically tears down the HTTP stream.
    public func stream(
        system:      String,
        messages:    [ClaudeMessage],
        model:       ClaudeModel      = .sonnet,
        maxTokens:   Int              = 4096,
        temperature: Double?          = 0.2,
        tools:       [ToolDefinition]? = nil,
        thinking:    ThinkingConfig?  = nil,
        cacheControl: CacheControl?   = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [apiKey, baseURL, session] in
                do {
                    let request = ClaudeRequest(
                        model:       model.rawValue,
                        maxTokens:   maxTokens,
                        system:      system,
                        messages:    messages,
                        temperature: temperature,
                        stream:      true,
                        tools:       tools,
                        thinking:    thinking,
                        cacheControl: cacheControl
                    )

                    let url = baseURL.appendingPathComponent(Self.messagesPath)
                    var urlRequest       = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 300
                    urlRequest.setValue("application/json",  forHTTPHeaderField: "content-type")
                    urlRequest.setValue(apiKey,              forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue(Self.apiVersion,     forHTTPHeaderField: "anthropic-version")
                    if let betaHeader = Self.anthropicBetaHeader(for: model.rawValue, thinking: thinking) {
                        urlRequest.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
                    }

                    let encoder = JSONEncoder()
                    urlRequest.httpBody = try encoder.encode(request)

                    let bytes = try await Self.performStreamingRequest(
                        urlRequest,
                        session: session
                    )

                    let parser = SSEParser()
                    for try await event in parser.events(from: bytes) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private (blocking)

    private func send(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let url = baseURL.appendingPathComponent(Self.messagesPath)
        var urlRequest       = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json",  forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey,              forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion,     forHTTPHeaderField: "anthropic-version")
        if let betaHeader = Self.anthropicBetaHeader(for: request.model, thinking: request.thinking) {
            urlRequest.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let data = try await performDataRequest(urlRequest)

        let decoder = JSONDecoder()
        return try decoder.decode(ClaudeResponse.self, from: data)
    }

    private func performDataRequest(_ request: URLRequest) async throws -> Data {
        var lastRetryableError: OrchestratorError?

        for attempt in 1...Self.maxRetryAttempts {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw OrchestratorError.apiCallFailed(statusCode: -1, body: "No HTTP response")
            }

            guard http.statusCode == 200 else {
                let body = String(decoding: data, as: UTF8.self)
                let error = OrchestratorError.apiCallFailed(statusCode: http.statusCode, body: body)
                guard Self.shouldRetry(statusCode: http.statusCode, attempt: attempt) else {
                    throw error
                }
                lastRetryableError = error
                try await Task.sleep(nanoseconds: UInt64(Self.retryDelay(attempt: attempt, response: http) * 1_000_000_000))
                continue
            }

            return data
        }

        if let lastRetryableError {
            throw lastRetryableError
        }
        throw OrchestratorError.maxRetriesExceeded(attempts: Self.maxRetryAttempts)
    }

    private static func performStreamingRequest(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> URLSession.AsyncBytes {
        var lastRetryableError: OrchestratorError?

        for attempt in 1...maxRetryAttempts {
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw OrchestratorError.apiCallFailed(statusCode: -1, body: "No HTTP response")
            }

            guard http.statusCode == 200 else {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let body = String(decoding: errorData, as: UTF8.self)
                let error = OrchestratorError.apiCallFailed(statusCode: http.statusCode, body: body)
                guard shouldRetry(statusCode: http.statusCode, attempt: attempt) else {
                    throw error
                }
                lastRetryableError = error
                try await Task.sleep(nanoseconds: UInt64(retryDelay(attempt: attempt, response: http) * 1_000_000_000))
                continue
            }

            return bytes
        }

        if let lastRetryableError {
            throw lastRetryableError
        }
        throw OrchestratorError.maxRetriesExceeded(attempts: maxRetryAttempts)
    }

    private static func shouldRetry(statusCode: Int, attempt: Int) -> Bool {
        transientStatusCodes.contains(statusCode) && attempt < maxRetryAttempts
    }

    private static func retryDelay(attempt: Int, response: HTTPURLResponse) -> TimeInterval {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(retryAfter) {
                return min(max(seconds, 0.5), maxRetryDelay)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

            if let date = formatter.date(from: retryAfter) {
                return min(max(date.timeIntervalSinceNow, 0.5), maxRetryDelay)
            }
        }

        let fallback = pow(2, Double(max(0, attempt - 1)))
        return min(max(fallback, 0.5), maxRetryDelay)
    }

    private static func anthropicBetaHeader(for model: String, thinking: ThinkingConfig?) -> String? {
        guard thinking != nil else { return nil }

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModel.hasPrefix("claude-") else { return nil }

        return betaVersion
    }

    /// Legacy diagnostic-only estimate kept for CLI/debug surfaces.
    /// Runtime Claude paths should prefer `countTokens(...)` when accurate preflight is needed.
    public static func estimatedTokens(for text: String) -> Int {
        max(1, text.count / 4)
    }
}

public struct ClaudeTokenCountResponse: Codable, Sendable, Equatable {
    public let inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
    }
}

private struct ClaudeTokenCountRequest: Encodable {
    let model: String
    let system: String
    let messages: [ClaudeMessage]
    let tools: [ToolDefinition]?
    let thinking: ThinkingConfig?
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case tools
        case thinking
        case cacheControl = "cache_control"
    }
}

#if canImport(AppKit) && canImport(ImageIO)
public enum ClaudeVisionEncoder {

    public static func encodeJPEGBase64(
        from image: NSImage,
        maxDimension: CGFloat = 1024
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let tiffData = image.tiffRepresentation,
                  let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
                  let cgImage = thumbnail(from: source, maxDimension: maxDimension) else {
                return nil
            }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: 0.82
            ]
            guard let jpegData = rep.representation(using: .jpeg, properties: properties) else {
                return nil
            }
            return jpegData.base64EncodedString()
        }.value
    }

    private static func thumbnail(
        from source: CGImageSource,
        maxDimension: CGFloat
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
#endif
