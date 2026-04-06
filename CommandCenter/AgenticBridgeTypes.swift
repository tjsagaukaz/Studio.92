// AgenticBridgeTypes.swift
// Studio.92 — Command Center
// Shared types for the agentic bridge — extracted from AgenticBridge.swift

import Foundation
import AppKit
import ImageIO

// MARK: - Agentic Event

enum ToolProgress: Sendable {
    case command(String)
    case output(String)
}

struct ToolExecutionOutcome: @unchecked Sendable {
    let displayText: String
    let toolResultPayload: Any
    let isError: Bool

    init(displayText: String, toolResultPayload: Any, isError: Bool) {
        self.displayText = displayText
        self.toolResultPayload = toolResultPayload
        self.isError = isError
    }

    init(text: String, isError: Bool) {
        self.init(displayText: text, toolResultPayload: text, isError: isError)
    }
}

struct ResearcherSearchResult: Decodable {
    let query: String
    let title: String
    let url: String
    let snippet: String
}

enum AgenticEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case thinkingSignature(String)
    case toolCallStart(id: String, name: String)
    case toolCallInputDelta(id: String, partialJSON: String)
    case toolCallCommand(id: String, command: String)
    case toolCallOutput(id: String, line: String)
    case toolCallResult(id: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int)
    case completed(stopReason: String)
    case error(String)
}

// MARK: - Errors

enum AgenticBridgeError: LocalizedError {
    case noHTTPResponse
    case apiError(statusCode: Int, body: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .noHTTPResponse: return "No HTTP response"
        case .apiError(let code, let body): return openAIAPIErrorSummary(statusCode: code, body: body)
        case .missingAPIKey: return "No API key configured"
        }
    }
}

// MARK: - Vision

enum VisionPayloadBuilder {

    static func imageContentBlock(from url: URL, maxDimension: CGFloat = 1024) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = thumbnail(from: source, maxDimension: maxDimension) else {
                return nil
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: 0.82
            ]
            guard let jpegData = bitmap.representation(using: .jpeg, properties: properties) else {
                return nil
            }

            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ]
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
