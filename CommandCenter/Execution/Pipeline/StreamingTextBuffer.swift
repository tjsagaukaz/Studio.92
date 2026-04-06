// StreamingTextBuffer.swift
// CommandCenter
//
// Incremental text assembly for streaming responses.

import Foundation

actor StreamingTextBuffer {

    static let flushInterval: Duration = .milliseconds(33)
    private static let minimumBoundaryFlushLength = 12
    private static let maximumBufferedCharacters = 32

    private var buffer = ""
    private var hasFlushedVisibleText = false

    func append(_ text: String) -> Bool {
        buffer += text

        let visibleBuffer = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasFlushedVisibleText, !visibleBuffer.isEmpty {
            hasFlushedVisibleText = true
            return true
        }

        if buffer.contains("\n") {
            return true
        }

        if buffer.count >= Self.maximumBufferedCharacters {
            return true
        }

        if buffer.count >= Self.minimumBoundaryFlushLength,
           let lastCharacter = buffer.last,
           lastCharacter.isWhitespace || Self.boundaryCharacters.contains(lastCharacter) {
            return true
        }

        return false
    }

    func flush() -> String {
        let output = buffer
        buffer.removeAll(keepingCapacity: true)
        return output
    }

    private static let boundaryCharacters: Set<Character> = [".", ",", "!", "?", ":", ";", ")"]
}


