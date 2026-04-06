// MultimodalEngineTests.swift
// Studio.92 — Multimodal Engine Tests

import Foundation
import XCTest
import AppKit
@testable import MultimodalEngine

final class MultimodalPresetTests: XCTestCase {

    // MARK: - Request Shape

    func testAllPresetsReturnValidShape() {
        for preset in MultimodalPreset.allCases {
            let shape = MultimodalRequestShape.shape(for: preset)
            XCTAssertGreaterThan(shape.maxImageDimension, 0, "\(preset) maxImageDimension must be positive")
            XCTAssertGreaterThan(shape.compressionQuality, 0, "\(preset) compressionQuality must be positive")
            XCTAssertLessThanOrEqual(shape.compressionQuality, 1.0, "\(preset) compressionQuality must be <= 1.0")
        }
    }

    func testQuickQAUsesAutoDetail() {
        let shape = MultimodalRequestShape.shape(for: .quickQA)
        XCTAssertEqual(shape.imageDetail, "auto")
        XCTAssertFalse(shape.structuredOutput)
    }

    func testDenseScreenshotUsesOriginalDetail() {
        let shape = MultimodalRequestShape.shape(for: .denseScreenshot)
        XCTAssertEqual(shape.imageDetail, "original")
        XCTAssertFalse(shape.structuredOutput)
    }

    func testOCRTranscribeUsesStructuredOutput() {
        let shape = MultimodalRequestShape.shape(for: .ocrTranscribe)
        XCTAssertTrue(shape.structuredOutput)
    }

    func testLocateRegionUsesStructuredOutput() {
        let shape = MultimodalRequestShape.shape(for: .locateRegion)
        XCTAssertTrue(shape.structuredOutput)
    }

    func testDeepInspectUsesHighEffort() {
        let shape = MultimodalRequestShape.shape(for: .deepInspect)
        XCTAssertEqual(shape.reasoningEffort, "high")
        XCTAssertTrue(shape.structuredOutput)
    }

    func testPresetDisplayNamesAreUnique() {
        let names = MultimodalPreset.allCases.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count, "All preset display names should be unique")
    }

    func testPresetIconNamesAreAllPopulated() {
        for preset in MultimodalPreset.allCases {
            XCTAssertFalse(preset.iconName.isEmpty, "\(preset) must have an icon name")
        }
    }
}

// MARK: - BBox

final class NormalizedBBoxTests: XCTestCase {

    func testValidBBox() {
        let bbox = NormalizedBBox(x: 100, y: 200, width: 300, height: 400)
        XCTAssertTrue(bbox.isValid)
    }

    func testInvalidBBoxZeroWidth() {
        let bbox = NormalizedBBox(x: 100, y: 200, width: 0, height: 400)
        XCTAssertFalse(bbox.isValid)
    }

    func testInvalidBBoxZeroHeight() {
        let bbox = NormalizedBBox(x: 100, y: 200, width: 300, height: 0)
        XCTAssertFalse(bbox.isValid)
    }

    func testInvalidBBoxExceedsBounds() {
        let bbox = NormalizedBBox(x: 100, y: 200, width: 300, height: 400)
        XCTAssertTrue(bbox.isValid)

        let oob = NormalizedBBox(x: 800, y: 200, width: 300, height: 400)
        XCTAssertFalse(oob.isValid, "x + width exceeds 999")
    }

    func testFractionalRect() {
        let bbox = NormalizedBBox(x: 0, y: 0, width: 999, height: 999)
        let rect = bbox.fractionalRect
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1.0, accuracy: 0.001)
    }

    func testFractionalRectMidpoint() {
        let bbox = NormalizedBBox(x: 500, y: 500, width: 100, height: 100)
        let rect = bbox.fractionalRect
        XCTAssertEqual(rect.origin.x, 500.0 / 999.0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 500.0 / 999.0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100.0 / 999.0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 100.0 / 999.0, accuracy: 0.001)
    }

    func testBBoxDecodingFromJSON() throws {
        let json = """
        {"x": 100, "y": 200, "width": 300, "height": 400, "label": "error_panel"}
        """.data(using: .utf8)!
        let bbox = try JSONDecoder().decode(NormalizedBBox.self, from: json)
        XCTAssertEqual(bbox.x, 100)
        XCTAssertEqual(bbox.y, 200)
        XCTAssertEqual(bbox.width, 300)
        XCTAssertEqual(bbox.height, 400)
        XCTAssertEqual(bbox.label, "error_panel")
    }

    func testBBoxDecodingWithoutLabel() throws {
        let json = """
        {"x": 10, "y": 20, "width": 30, "height": 40}
        """.data(using: .utf8)!
        let bbox = try JSONDecoder().decode(NormalizedBBox.self, from: json)
        XCTAssertNil(bbox.label)
        XCTAssertTrue(bbox.isValid)
    }
}

// MARK: - BBox Response Parsing

final class BBoxParsingTests: XCTestCase {

    func testParseBBoxResponseValid() {
        let json = """
        {
            "regions": [
                {"x": 100, "y": 200, "width": 300, "height": 400, "label": "header"},
                {"x": 50, "y": 50, "width": 100, "height": 100}
            ],
            "description": "Found two regions"
        }
        """
        let result = MultimodalEngine.parseBBoxResponse(from: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.regions.count, 2)
        XCTAssertEqual(result?.regions.first?.label, "header")
        XCTAssertEqual(result?.description, "Found two regions")
    }

    func testParseBBoxResponseWithCodeFence() {
        let json = """
        ```json
        {
            "regions": [
                {"x": 100, "y": 200, "width": 300, "height": 400}
            ]
        }
        ```
        """
        let result = MultimodalEngine.parseBBoxResponse(from: json)
        XCTAssertNotNil(result, "Should strip code fences")
        XCTAssertEqual(result?.regions.count, 1)
    }

    func testParseBBoxResponseInvalid() {
        let result = MultimodalEngine.parseBBoxResponse(from: "This is just plain text with no JSON")
        XCTAssertNil(result)
    }

    func testParseBBoxResponseEmptyRegions() {
        let json = """
        {"regions": []}
        """
        let result = MultimodalEngine.parseBBoxResponse(from: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.regions.count, 0)
    }
}

// MARK: - Extractor Schema

final class ExtractorSchemaTests: XCTestCase {

    func testAllSchemasHaveRequiredFields() {
        for schema in ExtractorSchema.allCases {
            let jsonSchema = schema.jsonSchema
            XCTAssertEqual(jsonSchema["type"] as? String, "object", "\(schema) must be object type")
            XCTAssertNotNil(jsonSchema["properties"], "\(schema) must have properties")
            XCTAssertNotNil(jsonSchema["required"], "\(schema) must have required fields")
        }
    }

    func testAllSchemasHaveDisplayNames() {
        for schema in ExtractorSchema.allCases {
            XCTAssertFalse(schema.displayName.isEmpty)
        }
    }

    func testAllSchemasHaveExtractionPrompts() {
        for schema in ExtractorSchema.allCases {
            XCTAssertFalse(schema.extractionPrompt.isEmpty)
            XCTAssertGreaterThan(schema.extractionPrompt.count, 20, "\(schema) prompt should be substantive")
        }
    }

    func testBuildErrorSchemaHasErrorsArray() {
        let schema = ExtractorSchema.buildError.jsonSchema
        let properties = schema["properties"] as? [String: Any]
        let errors = properties?["errors"] as? [String: Any]
        XCTAssertNotNil(errors)
        XCTAssertEqual(errors?["type"] as? String, "array")
    }

    func testParseExtractionResultValid() {
        let json = """
        {
            "errors": [
                {"severity": "error", "message": "Missing return", "file": "main.swift", "line": 42}
            ],
            "summary": "1 build error found"
        }
        """
        let result = MultimodalEngine.parseExtractionResult(from: json, schema: .buildError)
        XCTAssertEqual(result.schemaID, "build_error")
        XCTAssertNotNil(result.parsed)
    }

    func testParseExtractionResultInvalid() {
        let result = MultimodalEngine.parseExtractionResult(from: "not json", schema: .buildError)
        XCTAssertNil(result.parsed)
    }
}

// MARK: - BBox Response Schema

final class BBoxResponseSchemaTests: XCTestCase {

    func testBBoxResponseSchemaStructure() {
        let schema = MultimodalEngine.bboxResponseSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["regions"])
        let required = schema["required"] as? [String]
        XCTAssertTrue(required?.contains("regions") ?? false)
    }
}

// MARK: - Image Content Block

final class ImageContentBlockTests: XCTestCase {

    func testImageContentBlockFormatOpenAI() async {
        // Create a tiny 1x1 PNG
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_pixel_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ), let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create test image")
            return
        }
        try! pngData.write(to: url)

        let block = await MultimodalEngine.imageContentBlock(from: url, detail: "high", maxDimension: 512, compressionQuality: 0.8)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?["type"] as? String, "input_image")
        let imageURL = block?["image_url"] as? String
        XCTAssertTrue(imageURL?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertEqual(block?["detail"] as? String, "high")
    }

    func testImageContentBlockMissingFileReturnsNil() async {
        let block = await MultimodalEngine.imageContentBlock(
            from: URL(fileURLWithPath: "/nonexistent/file.png"),
            detail: "auto",
            maxDimension: 1024,
            compressionQuality: 0.85
        )
        XCTAssertNil(block)
    }

    func testAnthropicImageContentBlock() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_anthropic_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ), let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create test image")
            return
        }
        try! pngData.write(to: url)

        let block = await MultimodalEngine.anthropicImageContentBlock(from: url, maxDimension: 512, compressionQuality: 0.8)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?["type"] as? String, "image")
        let source = block?["source"] as? [String: Any]
        XCTAssertEqual(source?["type"] as? String, "base64")
        XCTAssertEqual(source?["media_type"] as? String, "image/jpeg")
    }
}
