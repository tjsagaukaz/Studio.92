// APIModels.swift
// Studio.92 — Agent Council
// Codable models for the Anthropic Messages API.
// Supports both blocking and streaming modes, tool_use, and extended thinking.

import Foundation

// MARK: - Request

public struct ClaudeRequest: Encodable {
    public let model:       String
    public let maxTokens:   Int
    public let system:      String
    public let messages:    [ClaudeMessage]
    public let temperature: Double?
    public let stream:      Bool?
    public let tools:       [ToolDefinition]?
    public let thinking:    ThinkingConfig?
    public let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens   = "max_tokens"
        case system
        case messages
        case temperature
        case stream
        case tools
        case thinking
        case cacheControl = "cache_control"
    }

    public init(
        model:       String           = ClaudeModel.sonnet.rawValue,
        maxTokens:   Int              = 2048,
        system:      String,
        messages:    [ClaudeMessage],
        temperature: Double?          = 0.2,
        stream:      Bool?            = nil,
        tools:       [ToolDefinition]? = nil,
        thinking:    ThinkingConfig?  = nil,
        cacheControl: CacheControl?   = nil
    ) {
        self.model       = model
        self.maxTokens   = maxTokens
        self.system      = system
        self.messages    = messages
        // Anthropic requires temperature to be omitted when thinking is enabled.
        self.temperature = thinking != nil ? nil : temperature
        self.stream      = stream
        self.tools       = tools
        self.thinking    = thinking
        self.cacheControl = cacheControl
    }
}

// MARK: - Thinking Configuration

public struct ThinkingConfig: Encodable, Sendable {
    public let type:         String
    public let budgetTokens: Int?
    public let effort:       String?
    public let display:      String?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
        case effort
        case display
    }

    public init(budgetTokens: Int, display: DisplayMode? = nil) {
        self.type         = "enabled"
        self.budgetTokens = budgetTokens
        self.effort       = nil
        self.display      = display?.rawValue
    }

    public init(adaptiveEffort: Effort = .medium, display: DisplayMode? = nil) {
        self.type         = "enabled"
        self.budgetTokens = adaptiveEffort.minimumBudgetTokens
        self.effort       = adaptiveEffort.rawValue
        self.display      = display?.rawValue
    }

    public enum Effort: String, Codable, Sendable {
        case low
        case medium
        case high

        var minimumBudgetTokens: Int {
            switch self {
            case .low:
                return 1_024
            case .medium:
                return 2_048
            case .high:
                return 4_096
            }
        }
    }

    public enum DisplayMode: String, Codable, Sendable {
        case summarized
        case omitted
    }
}

// MARK: - Cache Control

public struct CacheControl: Encodable, Sendable {
    public let type: String
    public let ttl:  String?

    public init(type: String = "ephemeral", ttl: TTL? = nil) {
        self.type = type
        self.ttl  = ttl?.rawValue
    }

    public enum TTL: String, Codable, Sendable {
        case fiveMinutes = "5m"
        case oneHour = "1h"
    }
}

// MARK: - Tool Definition

public struct ToolDefinition: Encodable, Sendable {
    public let name:        String
    public let description: String
    public let inputSchema: JSONSchema
    public let strict:      Bool?
    public let inputExamples: [[String: AnyCodableValue]]?
    public let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
        case strict
        case inputExamples = "input_examples"
        case cacheControl = "cache_control"
    }

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        strict: Bool? = nil,
        inputExamples: [[String: AnyCodableValue]]? = nil,
        cacheControl: CacheControl? = nil
    ) {
        self.name        = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict      = strict
        self.inputExamples = inputExamples
        self.cacheControl = cacheControl
    }
}

/// Minimal JSON Schema representation for tool input_schema.
public struct JSONSchema: Encodable, Sendable {
    public let type:       String
    public let properties: [String: PropertySchema]?
    public let required:   [String]?
    public let additionalProperties: Bool?

    public init(
        type: String = "object",
        properties: [String: PropertySchema]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = false
    ) {
        self.type       = type
        self.properties = properties
        self.required   = required
        self.additionalProperties = additionalProperties
    }
}

public struct PropertySchema: Encodable, Sendable {
    public let type:        String
    public let description: String?
    public let `enum`:      [String]?
    public let items:       SchemaItems?

    enum CodingKeys: String, CodingKey {
        case type, description
        case `enum`
        case items
    }

    public init(type: String, description: String? = nil, `enum`: [String]? = nil, items: SchemaItems? = nil) {
        self.type        = type
        self.description = description
        self.enum        = `enum`
        self.items       = items
    }
}

public struct SchemaItems: Encodable, Sendable {
    public let type: String
    public let description: String?
    public let `enum`: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case `enum`
    }

    public init(type: String, description: String? = nil, `enum`: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
    }
}

// MARK: - Model IDs

public enum ClaudeModel: String, Sendable {
    case opus   = "claude-opus-4-6"
    case sonnet = "claude-sonnet-4-6"
    case haiku  = "claude-haiku-4-5"
}

// MARK: - Message

public struct ClaudeMessage: Sendable {
    public let role:    MessageRole
    public let content: MessageContent

    public init(role: MessageRole, content: MessageContent) {
        self.role    = role
        self.content = content
    }

    /// Convenience: plain text user message.
    public static func user(_ text: String) -> ClaudeMessage {
        .init(role: .user, content: .text(text))
    }

    /// Convenience: plain text assistant message.
    public static func assistant(_ text: String) -> ClaudeMessage {
        .init(role: .assistant, content: .text(text))
    }

    public static func user(text: String, imageJPEGBase64: String, mediaType: String = "image/jpeg") -> ClaudeMessage {
        .init(
            role: .user,
            content: .blocks([
                .text(text),
                .image(
                    ImageBlock(
                        source: ImageSource(
                            mediaType: mediaType,
                            data: imageJPEGBase64
                        )
                    )
                )
            ])
        )
    }

    /// Convenience: tool result turn (user role per Anthropic spec).
    public static func toolResult(callID: String, content: String, isError: Bool = false) -> ClaudeMessage {
        .init(role: .user, content: .blocks([
            .toolResult(ToolResultBlock(toolUseId: callID, content: content, isError: isError))
        ]))
    }
}

/// Message content: either a plain string or an array of typed content blocks.
/// Encodes as `"content": "text"` or `"content": [{ ... }]` per the Anthropic spec.
public enum MessageContent: Sendable {
    case text(String)
    case blocks([MessageBlock])
}

/// A single block within a content array.
public enum MessageBlock: Sendable {
    case text(String)
    case image(ImageBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case thinking(ThinkingBlock)
}

public struct ImageBlock: Sendable {
    public let source: ImageSource

    public init(source: ImageSource) {
        self.source = source
    }
}

public struct ImageSource: Sendable, Codable {
    public let type: String
    public let mediaType: String
    public let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }

    public init(type: String = "base64", mediaType: String, data: String) {
        self.type = type
        self.mediaType = mediaType
        self.data = data
    }
}

public struct ToolUseBlock: Sendable {
    public let id:    String
    public let name:  String
    public let input: [String: AnyCodableValue]

    public init(id: String, name: String, input: [String: AnyCodableValue]) {
        self.id    = id
        self.name  = name
        self.input = input
    }
}

public struct ToolResultBlock: Sendable {
    public let toolUseId: String
    public let content:   ToolResultContent
    public let isError:   Bool

    public init(toolUseId: String, content: ToolResultContent, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content   = content
        self.isError   = isError
    }

    public init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content   = .text(content)
        self.isError   = isError
    }

    public init(toolUseId: String, contentBlocks: [ToolResultContentBlock], isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content   = .blocks(contentBlocks)
        self.isError   = isError
    }
}

public struct ThinkingBlock: Sendable {
    public let thinking: String
    public let signature: String?

    public init(thinking: String, signature: String? = nil) {
        self.thinking = thinking
        self.signature = signature
    }
}

public enum ToolResultContent: Sendable, Equatable {
    case text(String)
    case blocks([ToolResultContentBlock])
}

public struct ToolResultSearchResult: Sendable, Equatable {
    public let source: String
    public let title: String
    public let texts: [String]
    public let citationsEnabled: Bool

    public init(source: String, title: String, texts: [String], citationsEnabled: Bool = true) {
        self.source = source
        self.title = title
        self.texts = texts
        self.citationsEnabled = citationsEnabled
    }
}

public enum ToolResultContentBlock: Sendable, Equatable {
    case text(String)
    case searchResult(ToolResultSearchResult)
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

// MARK: - Codable Conformances

extension ClaudeMessage: Codable {
    enum CodingKeys: String, CodingKey { case role, content }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(MessageRole.self, forKey: .role)
        // Try string first, fall back to blocks.
        if let text = try? container.decode(String.self, forKey: .content) {
            content = .text(text)
        } else {
            let blocks = try container.decode([MessageBlockCodable].self, forKey: .content)
            content = .blocks(blocks.compactMap(\.block))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch content {
        case .text(let text):
            try container.encode(text, forKey: .content)
        case .blocks(let blocks):
            try container.encode(blocks.map { MessageBlockCodable($0) }, forKey: .content)
        }
    }
}

/// Internal helper for coding MessageBlock to/from JSON.
private struct MessageBlockCodable: Codable {
    let block: MessageBlock?

    init(_ block: MessageBlock) { self.block = block }

    enum CodingKeys: String, CodingKey {
        case type, id, name, input, text, thinking, signature, source
        case toolUseId = "tool_use_id"
        case content
        case isError   = "is_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            block = .text(text)
        case "image":
            let source = try container.decode(ImageSource.self, forKey: .source)
            block = .image(ImageBlock(source: source))
        case "tool_use":
            let id    = try container.decode(String.self, forKey: .id)
            let name  = try container.decode(String.self, forKey: .name)
            let input = try container.decode([String: AnyCodableValue].self, forKey: .input)
            block = .toolUse(ToolUseBlock(id: id, name: name, input: input))
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let content: ToolResultContent
            if let stringContent = try? container.decode(String.self, forKey: .content) {
                content = .text(stringContent)
            } else if let blocks = try? container.decode([ToolResultContentBlockCodable].self, forKey: .content) {
                content = .blocks(blocks.map(\.block))
            } else {
                content = .text("")
            }
            let isError   = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            block = .toolResult(ToolResultBlock(toolUseId: toolUseId, content: content, isError: isError))
        case "thinking":
            let thinking = try container.decode(String.self, forKey: .thinking)
            let signature = try container.decodeIfPresent(String.self, forKey: .signature)
            block = .thinking(ThinkingBlock(thinking: thinking, signature: signature))
        default:
            // Forward-compatible: unknown block types (e.g. redacted_thinking) are
            // silently skipped rather than killing the entire message decode.
            block = nil
            return
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let block else { return }
        switch block {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image.source, forKey: .source)
        case .toolUse(let tu):
            try container.encode("tool_use", forKey: .type)
            try container.encode(tu.id, forKey: .id)
            try container.encode(tu.name, forKey: .name)
            try container.encode(tu.input, forKey: .input)
        case .toolResult(let tr):
            try container.encode("tool_result", forKey: .type)
            try container.encode(tr.toolUseId, forKey: .toolUseId)
            switch tr.content {
            case .text(let text):
                try container.encode(text, forKey: .content)
            case .blocks(let blocks):
                try container.encode(blocks.map(ToolResultContentBlockCodable.init), forKey: .content)
            }
            if tr.isError { try container.encode(true, forKey: .isError) }
        case .thinking(let th):
            try container.encode("thinking", forKey: .type)
            try container.encode(th.thinking, forKey: .thinking)
            try container.encodeIfPresent(th.signature, forKey: .signature)
        }
    }
}

// MARK: - AnyCodableValue

/// Type-erased JSON value for tool input dictionaries.
public enum AnyCodableValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self)     { self = .string(s) }
        else if let i = try? container.decode(Int.self)    { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self)   { self = .bool(b) }
        else if let a = try? container.decode([AnyCodableValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: AnyCodableValue].self) { self = .object(o) }
        else if container.decodeNil()                      { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null:          try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Response

public struct ClaudeResponse: Decodable {
    public let id:      String
    public let content: [ContentBlock]
    public let model:   String
    public let usage:   TokenUsage

    /// The raw text of the first content block — what the orchestrator parses.
    public var text: String {
        content.first(where: { $0.type == "text" })?.text ?? ""
    }
}

public struct ContentBlock: Decodable, Sendable {
    public let type:  String
    public let text:  String?
    public let thinking: String?
    public let signature: String?
    public let id:    String?
    public let name:  String?
    public let input: [String: AnyCodableValue]?
    public let source: ImageSource?

    public init(
        type: String,
        text: String? = nil,
        thinking: String? = nil,
        signature: String? = nil,
        id: String? = nil,
        name: String? = nil,
        input: [String: AnyCodableValue]? = nil,
        source: ImageSource? = nil
    ) {
        self.type  = type
        self.text  = text
        self.thinking = thinking
        self.signature = signature
        self.id    = id
        self.name  = name
        self.input = input
        self.source = source
    }
}

public struct TokenUsage: Decodable, Sendable {
    public let inputTokens:  Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens  = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - Streaming Event Types

/// A single Server-Sent Event from the Anthropic streaming Messages API.
public enum StreamEvent: Sendable {
    case messageStart(StreamMessage)
    case contentBlockStart(index: Int, ContentBlock)
    case contentBlockDelta(index: Int, StreamDelta)
    case contentBlockStop(index: Int)
    case messageDelta(StreamMessageDelta)
    case messageStop
    case ping
    case error(StreamAPIError)
}

/// Delta variants within a content_block_delta event.
public enum StreamDelta: Sendable {
    case textDelta(String)
    case inputJSONDelta(String)
    case thinkingDelta(String)
    case signatureDelta(String)
}

/// Top-level message metadata from message_start.
public struct StreamMessage: Decodable, Sendable {
    public let id:      String
    public let model:   String
    public let usage:   TokenUsage?
}

/// Partial message update from message_delta (carries stop_reason + final usage).
public struct StreamMessageDelta: Decodable, Sendable {
    public let stopReason: String?
    public let usage:      TokenUsage?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case usage
    }
}

/// Error event from the stream.
public struct StreamAPIError: Decodable, Sendable, Error {
    public let type:    String
    public let message: String
}

// MARK: - API Error

public struct ClaudeAPIError: Decodable, Error {
    public let type:    String
    public let error:   APIErrorDetail
}

public struct APIErrorDetail: Decodable {
    public let type:    String
    public let message: String
}

// MARK: - Orchestrator Errors

public enum OrchestratorError: Error, Sendable {
    case apiCallFailed(statusCode: Int, body: String)
    case jsonExtractionFailed(rawOutput: String)
    case jsonDecodingFailed(rawJSON: String, underlying: Error)
    case maxRetriesExceeded(attempts: Int)
    case deliberationLoopFailed(packetID: UUID, reason: String)
    case missingAPIKey
}

extension OrchestratorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .apiCallFailed(let code, let body):
            return "API call failed (\(code)): \(body.prefix(200))"
        case .jsonExtractionFailed(let raw):
            return "Could not extract JSON from LLM output: \(raw.prefix(200))"
        case .jsonDecodingFailed(let json, let err):
            return "JSON decoding failed — \(err): \(json.prefix(300))"
        case .maxRetriesExceeded(let n):
            return "Max retries (\(n)) exceeded in deliberation loop"
        case .deliberationLoopFailed(let id, let reason):
            return "Deliberation loop failed for packet \(id): \(reason)"
        case .missingAPIKey:
            return "ANTHROPIC_API_KEY environment variable is not set"
        }
    }
}
