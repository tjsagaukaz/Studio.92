// SSEParser.swift
// Studio.92 — Agent Council
// Parses Anthropic's Server-Sent Events stream into typed StreamEvent values.
// Follows the same async pattern as StatefulTerminalEngine.

import Foundation

/// Parses a raw byte stream from URLSession into Anthropic StreamEvent values.
/// The Anthropic SSE format uses `event:` and `data:` fields separated by blank lines.
public struct SSEParser: Sendable {

    public init() {}

    /// Parse an `AsyncBytes` sequence into `StreamEvent` values.
    public func events<S: AsyncSequence>(
        from bytes: S
    ) -> AsyncThrowingStream<StreamEvent, Error> where S.Element == UInt8, S: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lineBuffer = ""
                var currentEvent = ""
                var currentData  = ""

                do {
                    for try await byte in bytes {
                        let char = Character(UnicodeScalar(byte))

                        if char == "\n" {
                            let line = lineBuffer
                            lineBuffer = ""

                            // Blank line = event boundary.
                            if line.isEmpty {
                                if !currentData.isEmpty {
                                    if let event = Self.parse(eventType: currentEvent, data: currentData) {
                                        continuation.yield(event)
                                    }
                                }
                                currentEvent = ""
                                currentData  = ""
                                continue
                            }

                            if line.hasPrefix("event:") {
                                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))
                                if currentData.isEmpty {
                                    currentData = payload
                                } else {
                                    currentData += "\n" + payload
                                }
                            }
                            // Ignore comments (lines starting with :) and other fields.
                        } else {
                            lineBuffer.append(char)
                        }
                    }

                    // Flush any trailing event.
                    if !currentData.isEmpty {
                        if let event = Self.parse(eventType: currentEvent, data: currentData) {
                            continuation.yield(event)
                        }
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

    // MARK: - Event Parsing

    private static func parse(eventType: String, data: String) -> StreamEvent? {
        guard data != "[DONE]" else { return nil }

        switch eventType {
        case "message_start":
            return parseMessageStart(data)
        case "content_block_start":
            return parseContentBlockStart(data)
        case "content_block_delta":
            return parseContentBlockDelta(data)
        case "content_block_stop":
            return parseContentBlockStop(data)
        case "message_delta":
            return parseMessageDelta(data)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            return parseError(data)
        default:
            return nil
        }
    }

    // MARK: - Individual Parsers

    private static func parseMessageStart(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable { let message: StreamMessage }
        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        return .messageStart(wrapper.message)
    }

    private static func parseContentBlockStart(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable {
            let index:        Int
            let contentBlock: ContentBlock

            enum CodingKeys: String, CodingKey {
                case index
                case contentBlock = "content_block"
            }
        }
        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        return .contentBlockStart(index: wrapper.index, wrapper.contentBlock)
    }

    private static func parseContentBlockDelta(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable {
            let index: Int
            let delta: DeltaPayload
        }
        struct DeltaPayload: Decodable {
            let type:              String
            let text:              String?
            let partialJson:       String?
            let thinking:          String?
            let signature:         String?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature
                case partialJson = "partial_json"
            }
        }

        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        let d = wrapper.delta

        let delta: StreamDelta
        switch d.type {
        case "text_delta":
            delta = .textDelta(d.text ?? "")
        case "input_json_delta":
            delta = .inputJSONDelta(d.partialJson ?? "")
        case "thinking_delta":
            delta = .thinkingDelta(d.thinking ?? "")
        case "signature_delta":
            delta = .signatureDelta(d.signature ?? "")
        default:
            return nil
        }

        return .contentBlockDelta(index: wrapper.index, delta)
    }

    private static func parseContentBlockStop(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable { let index: Int }
        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        return .contentBlockStop(index: wrapper.index)
    }

    private static func parseMessageDelta(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable { let delta: StreamMessageDelta; let usage: TokenUsage? }
        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        var combined = wrapper.delta
        if combined.usage == nil, let u = wrapper.usage {
            combined = StreamMessageDelta(stopReason: combined.stopReason, usage: u)
        }
        return .messageDelta(combined)
    }

    private static func parseError(_ data: String) -> StreamEvent? {
        struct Wrapper: Decodable { let error: StreamAPIError }
        guard let wrapper = decode(Wrapper.self, from: data) else { return nil }
        return .error(wrapper.error)
    }

    // MARK: - Helpers

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
