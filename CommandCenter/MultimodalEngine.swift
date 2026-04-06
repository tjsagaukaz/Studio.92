// MultimodalEngine.swift
// Studio.92 — Command Center
// First-class multimodal document/screenshot support for GPT-5.4 Responses API.
// Provides presets, request shaping, structured extraction, and bbox/crop pipeline.

import Foundation
import AppKit

// MARK: - Multimodal Preset

/// Presets that map user intent to GPT-5.4 Responses API parameters.
enum MultimodalPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case quickQA           = "quick_qa"
    case denseScreenshot   = "dense_screenshot"
    case ocrTranscribe     = "ocr_transcribe"
    case diagramReasoning  = "diagram_reasoning"
    case locateRegion      = "locate_region"
    case deepInspect       = "deep_inspect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickQA:          return "Quick QA"
        case .denseScreenshot:  return "Dense Screenshot"
        case .ocrTranscribe:    return "OCR / Transcribe"
        case .diagramReasoning: return "Diagram / Table"
        case .locateRegion:     return "Locate Region"
        case .deepInspect:      return "Deep Inspect"
        }
    }

    var iconName: String {
        switch self {
        case .quickQA:          return "sparkle.magnifyingglass"
        case .denseScreenshot:  return "text.viewfinder"
        case .ocrTranscribe:    return "doc.text.magnifyingglass"
        case .diagramReasoning: return "chart.bar.doc.horizontal"
        case .locateRegion:     return "crop"
        case .deepInspect:      return "eye.trianglebadge.exclamationmark"
        }
    }

    var hint: String {
        switch self {
        case .quickQA:          return "Fast general question about the image"
        case .denseScreenshot:  return "Full-res analysis of dense UI, forms, or tiny text"
        case .ocrTranscribe:    return "Extract all visible text from the image"
        case .diagramReasoning: return "Analyze diagrams, tables, charts, or architecture"
        case .locateRegion:     return "Find and highlight a specific region, then zoom in"
        case .deepInspect:      return "Two-pass: locate region, crop, then re-analyze at full detail"
        }
    }
}

// MARK: - Request Shaping

/// GPT-5.4 Responses API parameters derived from a MultimodalPreset.
struct MultimodalRequestShape: Sendable {
    /// Image detail level: "auto", "low", "high", or "original"
    let imageDetail: String
    /// Text verbosity: nil, "low", "medium", "high"
    let textVerbosity: String?
    /// Reasoning effort: nil, "low", "medium", "high"
    let reasoningEffort: String?
    /// Whether to request structured JSON output (response_format)
    let structuredOutput: Bool
    /// Max dimension for image resize before base64 encoding
    let maxImageDimension: CGFloat
    /// JPEG compression quality
    let compressionQuality: Double

    static func shape(for preset: MultimodalPreset) -> MultimodalRequestShape {
        switch preset {
        case .quickQA:
            return MultimodalRequestShape(
                imageDetail: "auto",
                textVerbosity: nil,
                reasoningEffort: nil,
                structuredOutput: false,
                maxImageDimension: 1024,
                compressionQuality: 0.82
            )
        case .denseScreenshot:
            return MultimodalRequestShape(
                imageDetail: "original",
                textVerbosity: nil,
                reasoningEffort: "high",
                structuredOutput: false,
                maxImageDimension: 2048,
                compressionQuality: 0.92
            )
        case .ocrTranscribe:
            return MultimodalRequestShape(
                imageDetail: "original",
                textVerbosity: "high",
                reasoningEffort: nil,
                structuredOutput: true,
                maxImageDimension: 2048,
                compressionQuality: 0.92
            )
        case .diagramReasoning:
            return MultimodalRequestShape(
                imageDetail: "auto",
                textVerbosity: nil,
                reasoningEffort: "high",
                structuredOutput: true,
                maxImageDimension: 2048,
                compressionQuality: 0.88
            )
        case .locateRegion:
            return MultimodalRequestShape(
                imageDetail: "auto",
                textVerbosity: nil,
                reasoningEffort: "medium",
                structuredOutput: true,
                maxImageDimension: 1536,
                compressionQuality: 0.85
            )
        case .deepInspect:
            return MultimodalRequestShape(
                imageDetail: "original",
                textVerbosity: "high",
                reasoningEffort: "high",
                structuredOutput: true,
                maxImageDimension: 2048,
                compressionQuality: 0.92
            )
        }
    }
}

// MARK: - Structured Extractor Schemas

/// Built-in extraction schemas for common multimodal tasks.
enum ExtractorSchema: String, Codable, CaseIterable, Sendable, Identifiable {
    case buildError       = "build_error"
    case appStoreReview   = "app_store_review"
    case prdSpec          = "prd_spec"
    case uiReview         = "ui_review"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .buildError:     return "Build / Error Screenshot"
        case .appStoreReview: return "App Store Review"
        case .prdSpec:        return "PRD / Spec Document"
        case .uiReview:       return "UI Screenshot Review"
        }
    }

    /// JSON Schema definition for GPT-5.4 structured output.
    var jsonSchema: [String: Any] {
        switch self {
        case .buildError:
            return Self.buildErrorSchema
        case .appStoreReview:
            return Self.appStoreReviewSchema
        case .prdSpec:
            return Self.prdSpecSchema
        case .uiReview:
            return Self.uiReviewSchema
        }
    }

    /// System prompt supplement for this extractor.
    var extractionPrompt: String {
        switch self {
        case .buildError:
            return "Extract all build errors, warnings, and diagnostic messages visible in this screenshot. Include file paths, line numbers, error messages, and severity levels."
        case .appStoreReview:
            return "Extract the App Store review content including: reviewer feedback, rejection reasons, guideline citations, required changes, and any metadata visible."
        case .prdSpec:
            return "Extract the product requirements from this document. Capture: feature descriptions, acceptance criteria, priority levels, dependencies, and any technical constraints."
        case .uiReview:
            return "Analyze this UI screenshot. Identify: layout issues, accessibility concerns, HIG violations, inconsistent spacing/typography, missing states, and improvement suggestions."
        }
    }

    // MARK: - Schema Definitions

    private static let buildErrorSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "errors": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "file": ["type": "string"],
                        "line": ["type": "integer"],
                        "severity": ["type": "string", "enum": ["error", "warning", "note"]],
                        "message": ["type": "string"],
                        "code": ["type": "string"]
                    ],
                    "required": ["severity", "message"],
                    "additionalProperties": false
                ]
            ],
            "summary": ["type": "string"]
        ],
        "required": ["errors", "summary"],
        "additionalProperties": false
    ]

    private static let appStoreReviewSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "status": ["type": "string", "enum": ["approved", "rejected", "in_review", "needs_reply"]],
            "guidelines_cited": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "description": ["type": "string"],
                        "required_action": ["type": "string"],
                        "guideline": ["type": "string"]
                    ],
                    "required": ["description"],
                    "additionalProperties": false
                ]
            ],
            "summary": ["type": "string"]
        ],
        "required": ["status", "issues", "summary"],
        "additionalProperties": false
    ]

    private static let prdSpecSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "features": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "description": ["type": "string"],
                        "priority": ["type": "string", "enum": ["critical", "high", "medium", "low"]],
                        "acceptance_criteria": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ],
                    "required": ["name", "description"],
                    "additionalProperties": false
                ]
            ],
            "constraints": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "summary": ["type": "string"]
        ],
        "required": ["features", "summary"],
        "additionalProperties": false
    ]

    private static let uiReviewSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "category": ["type": "string", "enum": ["layout", "accessibility", "hig_violation", "typography", "spacing", "color", "missing_state", "interaction"]],
                        "severity": ["type": "string", "enum": ["critical", "major", "minor", "suggestion"]],
                        "description": ["type": "string"],
                        "location": ["type": "string"],
                        "fix": ["type": "string"]
                    ],
                    "required": ["category", "severity", "description"],
                    "additionalProperties": false
                ]
            ],
            "overall_quality": ["type": "string", "enum": ["excellent", "good", "fair", "poor"]],
            "summary": ["type": "string"]
        ],
        "required": ["issues", "overall_quality", "summary"],
        "additionalProperties": false
    ]
}

// MARK: - Extraction Result

/// Decoded structured result from an extractor-style multimodal query.
struct ExtractionResult: Codable, Sendable {
    var schemaID: String
    var rawJSON: String
    var parsed: [String: AnyCodableValue]?

    /// Attempt to decode the raw JSON into the typed structure.
    static func decode(json: String, schema: ExtractorSchema) -> ExtractionResult {
        var result = ExtractionResult(schemaID: schema.rawValue, rawJSON: json)
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.parsed = parsed.mapValues { AnyCodableValue(from: $0) }
        }
        return result
    }
}

/// Type-erased Codable value for structured extraction results.
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    init(from value: Any) {
        if let s = value as? String { self = .string(s) }
        else if let i = value as? Int { self = .int(i) }
        else if let d = value as? Double { self = .double(d) }
        else if let b = value as? Bool { self = .bool(b) }
        else if let arr = value as? [Any] { self = .array(arr.map { AnyCodableValue(from: $0) }) }
        else if let dict = value as? [String: Any] { self = .dictionary(dict.mapValues { AnyCodableValue(from: $0) }) }
        else { self = .null }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let arr = try? container.decode([AnyCodableValue].self) { self = .array(arr) }
        else if let dict = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(dict) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let arr): try container.encode(arr)
        case .dictionary(let dict): try container.encode(dict)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Bounding Box

/// Normalized bounding box in 0..999 coordinate space (GPT-5.4 convention).
struct NormalizedBBox: Codable, Hashable, Sendable {
    var x: Int      // left edge, 0..999
    var y: Int      // top edge, 0..999
    var width: Int   // box width, 0..999
    var height: Int  // box height, 0..999
    var label: String?

    /// Convert to fractional CGRect (0..1) for overlay rendering.
    var fractionalRect: CGRect {
        CGRect(
            x: CGFloat(x) / 999.0,
            y: CGFloat(y) / 999.0,
            width: CGFloat(width) / 999.0,
            height: CGFloat(height) / 999.0
        )
    }

    /// Validate that coordinates are within bounds.
    var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1000 && y + height <= 1000
    }
}

/// Response from a "Locate Region" query.
struct BBoxLocateResponse: Codable, Sendable {
    var regions: [NormalizedBBox]
    var description: String?
}

// MARK: - BBox JSON Schema

extension MultimodalEngine {
    static let bboxResponseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "regions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "integer", "minimum": 0, "maximum": 999],
                        "y": ["type": "integer", "minimum": 0, "maximum": 999],
                        "width": ["type": "integer", "minimum": 1, "maximum": 999],
                        "height": ["type": "integer", "minimum": 1, "maximum": 999],
                        "label": ["type": "string"]
                    ],
                    "required": ["x", "y", "width", "height"],
                    "additionalProperties": false
                ]
            ],
            "description": ["type": "string"]
        ],
        "required": ["regions"],
        "additionalProperties": false
    ]
}

// MARK: - Image Cropping

enum MultimodalEngine {

    /// Crop a region from an image file for second-pass analysis.
    static func cropImage(
        at url: URL,
        bbox: NormalizedBBox,
        maxDimension: CGFloat = 2048
    ) async -> (croppedURL: URL, croppedData: Data)? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }

            let imgW = CGFloat(fullImage.width)
            let imgH = CGFloat(fullImage.height)

            let cropRect = CGRect(
                x: CGFloat(bbox.x) / 999.0 * imgW,
                y: CGFloat(bbox.y) / 999.0 * imgH,
                width: CGFloat(bbox.width) / 999.0 * imgW,
                height: CGFloat(bbox.height) / 999.0 * imgH
            ).integral

            guard let cropped = fullImage.cropping(to: cropRect) else { return nil }

            let bitmap = NSBitmapImageRep(cgImage: cropped)
            guard let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.92]
            ) else { return nil }

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("crop-\(UUID().uuidString).jpg")
            do {
                try jpegData.write(to: tmpURL)
                return (tmpURL, jpegData)
            } catch {
                return nil
            }
        }.value
    }

    /// Build an OpenAI input_image content block with detail control.
    static func imageContentBlock(
        from url: URL,
        detail: String = "auto",
        maxDimension: CGFloat = 1024,
        compressionQuality: Double = 0.82
    ) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = thumbnail(from: source, maxDimension: maxDimension) else {
                return nil
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: compressionQuality]
            ) else {
                return nil
            }

            let dataURI = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"

            // OpenAI Responses API: input_image with detail control
            return [
                "type": "input_image",
                "image_url": dataURI,
                "detail": detail
            ]
        }.value
    }

    /// Build an Anthropic image content block with detail control via resize.
    static func anthropicImageContentBlock(
        from url: URL,
        maxDimension: CGFloat = 1024,
        compressionQuality: Double = 0.82
    ) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = thumbnail(from: source, maxDimension: maxDimension) else {
                return nil
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: compressionQuality]
            ) else {
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

    // MARK: - Request Construction

    /// Build the complete multimodal input array for OpenAI Responses API.
    static func buildOpenAIInput(
        goal: String,
        imageURL: URL,
        preset: MultimodalPreset,
        extractor: ExtractorSchema? = nil
    ) async -> (input: [[String: Any]], shape: MultimodalRequestShape)? {
        let shape = MultimodalRequestShape.shape(for: preset)

        guard let imageBlock = await imageContentBlock(
            from: imageURL,
            detail: shape.imageDetail,
            maxDimension: shape.maxImageDimension,
            compressionQuality: shape.compressionQuality
        ) else {
            return nil
        }

        var textContent = goal
        if let extractor {
            textContent += "\n\n" + extractor.extractionPrompt
        }
        if preset == .locateRegion {
            textContent += "\n\nReturn bounding boxes as normalized 0..999 coordinates in JSON."
        }

        let input: [[String: Any]] = [
            ["type": "input_text", "text": textContent],
            imageBlock
        ]

        return (input, shape)
    }

    /// Build the complete multimodal content blocks for Anthropic API.
    static func buildAnthropicInput(
        goal: String,
        imageURL: URL,
        preset: MultimodalPreset,
        extractor: ExtractorSchema? = nil
    ) async -> (blocks: [[String: Any]], shape: MultimodalRequestShape)? {
        let shape = MultimodalRequestShape.shape(for: preset)

        guard let imageBlock = await anthropicImageContentBlock(
            from: imageURL,
            maxDimension: shape.maxImageDimension,
            compressionQuality: shape.compressionQuality
        ) else {
            return nil
        }

        var textContent = goal
        if let extractor {
            textContent += "\n\n" + extractor.extractionPrompt
        }
        if preset == .locateRegion {
            textContent += "\n\nReturn bounding boxes as normalized 0..999 coordinates in JSON."
        }

        let blocks: [[String: Any]] = [
            ["type": "text", "text": textContent],
            imageBlock
        ]

        return (blocks, shape)
    }

    // MARK: - BBox Parsing

    /// Parse a bbox response from the model's JSON output.
    static func parseBBoxResponse(from json: String) -> BBoxLocateResponse? {
        let cleaned = Self.stripCodeFences(json)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BBoxLocateResponse.self, from: data)
    }

    /// Parse a structured extraction result from model JSON output.
    static func parseExtractionResult(from json: String, schema: ExtractorSchema) -> ExtractionResult {
        ExtractionResult.decode(json: Self.stripCodeFences(json), schema: schema)
    }

    /// Strip markdown code fences from model output.
    private static func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Remove opening fence (```json, ```, etc.)
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
