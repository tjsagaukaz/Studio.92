// ThreadTitleGenerator.swift
// Studio.92 — Command Center
// Generates concise thread titles from conversation context using a lightweight API call,
// then delivers them with a typewriter reveal animation.

import Foundation

@MainActor
final class ThreadTitleGenerator: ObservableObject {

    @Published private(set) var generatedTitle: String?
    @Published private(set) var displayedTitle: String = ""
    @Published private(set) var isTyping: Bool = false
    @Published private(set) var isCursorVisible: Bool = false

    /// Called after title generation completes with (threadID, title).
    var onTitleGenerated: ((UUID, String) -> Void)?

    private var typewriterTask: Task<Void, Never>?
    private var hasGeneratedForThread: UUID?

    // MARK: - Public API

    /// Request a title for the current thread. Skips if already generated for this threadID.
    func generateIfNeeded(
        threadID: UUID,
        userGoal: String,
        assistantResponse: String
    ) {
        guard hasGeneratedForThread != threadID else { return }
        hasGeneratedForThread = threadID

        let goalSnippet = String(userGoal.prefix(300))
        let responseSnippet = String(assistantResponse.prefix(500))

        Task {
            let title = await Self.requestTitle(
                goal: goalSnippet,
                response: responseSnippet
            )
            guard let title, !title.isEmpty else { return }
            self.generatedTitle = title
            self.animateTypewriter(title)
            self.onTitleGenerated?(threadID, title)
        }
    }

    /// Reset for a new thread.
    func reset() {
        typewriterTask?.cancel()
        typewriterTask = nil
        generatedTitle = nil
        displayedTitle = ""
        isTyping = false
        isCursorVisible = false
        hasGeneratedForThread = nil
    }

    // MARK: - Typewriter Animation

    private func animateTypewriter(_ title: String) {
        typewriterTask?.cancel()
        displayedTitle = ""
        isTyping = true
        isCursorVisible = true

        typewriterTask = Task { @MainActor in
            // Refinement 1: intentional beat before first character appears
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            guard !Task.isCancelled else { return }

            let characters = Array(title)
            let count = characters.count

            // Refinement 2: soft cap at 850ms total typing time
            let maxDuration: Double = 850 // ms
            let naturalDuration = Double(count) * 45 // rough estimate at avg 45ms/char
            let speedFactor: Double = naturalDuration > maxDuration ? maxDuration / naturalDuration : 1.0

            for (index, char) in characters.enumerated() {
                guard !Task.isCancelled else { return }

                displayedTitle.append(char)

                let baseDelay: UInt64 = 35_000_000
                let jitter = UInt64.random(in: 0...15_000_000)
                let extraPause: UInt64 = (char == " " || char == "—" || char == ",") ? 20_000_000 : 0
                let warmup: UInt64 = index > 3 ? 10_000_000 : 0
                let raw = Double(baseDelay + jitter + extraPause - min(warmup, baseDelay))
                let adjusted = UInt64(raw * speedFactor)

                try? await Task.sleep(nanoseconds: adjusted)
            }

            // Refinement 5: fade cursor out (view uses .transition(.opacity) on isCursorVisible)
            try? await Task.sleep(nanoseconds: 80_000_000)
            isCursorVisible = false
            try? await Task.sleep(nanoseconds: 130_000_000)
            isTyping = false
        }
    }

    // MARK: - API Call

    private static func requestTitle(goal: String, response: String) async -> String? {
        // Try Anthropic first, fall back to OpenAI
        let anthropicKey = StudioCredentialStore.load(key: "anthropicAPIKey")
        let openAIKey = StudioCredentialStore.load(key: "openAIAPIKey")

        if let key = anthropicKey, !key.isEmpty {
            return await requestTitleAnthropic(key: key, goal: goal, response: response)
        } else if let key = openAIKey, !key.isEmpty {
            return await requestTitleOpenAI(key: key, goal: goal, response: response)
        }
        return nil
    }

    private static let titlePrompt = """
    Generate a short, descriptive title (3-7 words) for this conversation thread. \
    The title should capture the main topic or task being discussed. \
    Return ONLY the title text, nothing else. No quotes, no punctuation at the end, no explanation.
    """

    private static func requestTitleAnthropic(key: String, goal: String, response: String) async -> String? {
        var request = URLRequest(url: StudioAPIConfig.anthropicMessagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(StudioAPIConfig.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 30,
            "temperature": 0.3,
            "system": titlePrompt,
            "messages": [
                ["role": "user", "content": "User asked: \(goal)\n\nAssistant began: \(response)"]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data

        guard let (responseData, httpResponse) = try? await URLSession.shared.data(for: request),
              let http = httpResponse as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return nil }

        return sanitizeTitle(text)
    }

    private static func requestTitleOpenAI(key: String, goal: String, response: String) async -> String? {
        var request = URLRequest(url: StudioAPIConfig.openAIChatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 30,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": titlePrompt],
                ["role": "user", "content": "User asked: \(goal)\n\nAssistant began: \(response)"]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data

        guard let (responseData, httpResponse) = try? await URLSession.shared.data(for: request),
              let http = httpResponse as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }

        return sanitizeTitle(text)
    }

    private static func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes
        if (title.hasPrefix("\"") && title.hasSuffix("\"")) ||
           (title.hasPrefix("'") && title.hasSuffix("'")) {
            title = String(title.dropFirst().dropLast())
        }
        // Strip trailing period
        if title.hasSuffix(".") { title = String(title.dropLast()) }
        // Refinement 3: char cap at 48 (before ellipsis)
        if title.count > 48 { title = String(title.prefix(45)) + "…" }
        // Refinement 3: reject generically useless or too-short titles
        let words = title.split(separator: " ")
        guard words.count >= 2 else { return "" }
        return title
    }
}
