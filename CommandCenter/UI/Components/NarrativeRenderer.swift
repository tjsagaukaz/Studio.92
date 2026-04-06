import Foundation

// MARK: - Voice Mode

enum VoiceMode: String, CaseIterable {
    case raw       // No transformation — debug / logs
    case studio92  // Studio.92 product voice
}

// MARK: - Render Context

struct NarrativeRenderContext {
    let hasTools: Bool
    let toolCount: Int
    let turnState: TurnState
    let isDebugging: Bool
    let isArchitecture: Bool
    let isFailed: Bool

    static func from(_ turn: ConversationTurn) -> NarrativeRenderContext {
        let traces = turn.toolTraces

        let debuggingKinds: Set<ToolTrace.Kind> = [.terminal, .build]
        let architectureKinds: Set<ToolTrace.Kind> = [.write, .edit]

        let isDebugging = traces.contains { debuggingKinds.contains($0.kind) }
        let isArchitecture = traces.contains { architectureKinds.contains($0.kind) }

        return NarrativeRenderContext(
            hasTools: !traces.isEmpty,
            toolCount: traces.count,
            turnState: turn.state,
            isDebugging: isDebugging,
            isArchitecture: isArchitecture,
            isFailed: turn.state == .failed
        )
    }
}

// MARK: - Narrative Renderer

struct NarrativeRenderer {

    static var mode: VoiceMode = .studio92

    static func render(
        _ text: String,
        context: NarrativeRenderContext
    ) -> String {
        guard mode == .studio92 else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        return Studio92Voice.transform(text, context: context)
    }
}

// MARK: - Studio.92 Voice v2

enum Studio92Voice {

    // MARK: - Debug Controls

    static var debugSkipCompress        = false
    static var debugSkipTighten         = false
    static var debugSkipNormalize       = false
    static var debugSkipRefine          = false
    static var debugSkipRhythm          = false
    static var debugSkipEmoji           = false
    /// Prefixes each sentence with its classification: `[action] Run X`
    static var debugShowClassification  = false
    /// Logs emoji placement decisions to stdout.
    static var debugLogEmoji            = false

    // MARK: - Pipeline

    static func transform(_ input: String, context: NarrativeRenderContext) -> String {
        var text = input

        if !debugSkipCompress   { text = compress(text) }
        if !debugSkipTighten    { text = tighten(text) }
        if !debugSkipTighten    { text = fixImperatives(text) }
        if !debugSkipNormalize  { text = normalizeSentences(text) }
        if !debugSkipRefine     { text = refineSentences(text, context: context) }
        if !debugSkipRhythm     { text = shapeRhythm(text, context: context) }
        text = collapseDuplicates(text)
        text = structure(text)
        if !debugSkipEmoji      { text = injectEmojis(text, context: context) }

        return text
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 1: Compression                                      │
    // └─────────────────────────────────────────────────────────────┘

    private static func compress(_ text: String) -> String {
        mapProse(text) { prose in
            var p = prose

            for pattern in openerPatterns {
                if let match = p.range(of: pattern, options: .regularExpression) {
                    if p[p.startIndex..<match.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.removeSubrange(match)
                    }
                }
            }

            for pattern in inlineFillerPatterns {
                p = p.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
            }

            return collapseSpaces(p)
        }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 2: Sentence Tightening + Authority                  │
    // └─────────────────────────────────────────────────────────────┘

    private static func tighten(_ text: String) -> String {
        mapProse(text) { prose in
            var p = prose
            for (pattern, replacement) in tighteningRules {
                p = p.replacingOccurrences(of: pattern, with: replacement,
                                           options: [.regularExpression, .caseInsensitive])
            }
            return collapseSpaces(p)
        }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 2b: Imperative Completion                           │
    // └─────────────────────────────────────────────────────────────┘

    private static func fixImperatives(_ text: String) -> String {
        mapProse(text) { prose in
            var lines = prose.components(separatedBy: "\n")
            for i in lines.indices {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.first, first.isLowercase else { continue }

                for (gerund, imperative) in gerundMap {
                    if trimmed.hasPrefix(gerund) {
                        lines[i] = "\(imperative)\(trimmed.dropFirst(gerund.count))"
                        break
                    }
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 3: Sentence Normalization                           │
    // └─────────────────────────────────────────────────────────────┘

    private static func normalizeSentences(_ text: String) -> String {
        mapProse(text) { prose in
            var p = capitalizeFirstVisible(prose)
            p = regexCapitalize(p, pattern: #"([.!?])\s+([a-z])"#, group: 2)
            p = regexCapitalize(p, pattern: #"\n\s*([a-z])"#, group: 1)
            return p
        }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 4: Sentence-Level Intelligence  (NEW — CRITICAL)    │
    // └─────────────────────────────────────────────────────────────┘

    /// Sentence intent classification.
    enum SentenceIntent: String {
        case action      // Imperative: "Run this", "Boot it"
        case diagnosis   // Root-cause: "caused by", "error", "fails"
        case concept     // Architectural: "state", "boundary", "system"
        case flow        // Sequencing: "then", "next", "after", "once"
        case neutral     // Everything else
    }

    /// A classified sentence with its original text.
    private struct ClassifiedSentence {
        let text: String
        let intent: SentenceIntent
    }

    /// Classifies and micro-styles sentences based on intent.
    private static func refineSentences(_ text: String, context: NarrativeRenderContext) -> String {
        mapProse(text) { prose in
            // Work paragraph-by-paragraph to preserve structure.
            let paragraphs = prose.components(separatedBy: "\n\n")

            let refined = paragraphs.map { paragraph -> String in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip headings, lists, very short fragments.
                guard !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("- "),
                      !trimmed.hasPrefix("* "),
                      trimmed.count >= 10 else {
                    return paragraph
                }

                let sentences = splitSentences(trimmed)
                guard sentences.count > 1 else { return paragraph }

                let classified = sentences.map { s in
                    ClassifiedSentence(text: s, intent: classify(s))
                }

                return classified.map { cs in
                    let styled = microStyle(cs, context: context)
                    if debugShowClassification {
                        return "[\(cs.intent)] \(styled)"
                    }
                    return styled
                }.joined(separator: " ")
            }

            return refined.joined(separator: "\n\n")
        }
    }

    /// Splits text into sentences at `. ` / `! ` / `? ` boundaries,
    /// guarding against abbreviations and decimals.
    private static func splitSentences(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z])"#) else {
            return [text]
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [text] }

        var sentences: [String] = []
        var cursor = 0
        for match in matches {
            let end = match.range.location
            let sentence = nsText.substring(with: NSRange(location: cursor, length: end - cursor))
                .trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            cursor = match.range.location + match.range.length
        }
        let tail = nsText.substring(from: cursor).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        return sentences
    }

    /// Checks if `word` appears in `text` (case-insensitive).
    /// Currently uses simple `contains` — upgrade to `\b` word-boundary
    /// regex here when needed; every call site benefits automatically.
    private static func matchesWord(_ word: String, in text: String) -> Bool {
        text.lowercased().contains(word)
    }

    /// Heuristic sentence classification.
    private static func classify(_ sentence: String) -> SentenceIntent {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)

        // ACTION: starts with an imperative verb.
        if let firstWord = trimmed.split(separator: " ").first {
            let word = firstWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if imperativeVerbs.contains(word) { return .action }
        }

        // DIAGNOSIS: contains error/causal language.
        for marker in diagnosisMarkers {
            if matchesWord(marker, in: sentence) { return .diagnosis }
        }

        // CONCEPT: architectural / systemic language.
        for marker in conceptMarkers {
            if matchesWord(marker, in: sentence) { return .concept }
        }

        // FLOW: sequencing connectives.
        for marker in flowMarkers {
            if matchesWord(marker, in: sentence) { return .flow }
        }

        return .neutral
    }

    /// Per-intent micro-styling. Keeps changes minimal and deterministic.
    ///
    /// Rule budget (strict caps — do not exceed):
    ///   .action    → max 2 rules (punctuation + imperative enforcement)
    ///   .diagnosis → max 2 rules (softener stripping + tone adjustment)
    ///   .concept   → max 1 rule  (optional emphasis, currently none)
    ///   .flow      → 0 rules     (never transform)
    ///   .neutral   → 0 rules     (never transform)
    private static func microStyle(_ cs: ClassifiedSentence, context: NarrativeRenderContext) -> String {
        var text = cs.text.trimmingCharacters(in: .whitespaces)

        switch cs.intent {
        case .action:
            // Rule 1/2: Ensure terminal punctuation for crispness.
            if !text.hasSuffix(".") && !text.hasSuffix("!") && !text.hasSuffix("?") {
                text += "."
            }
            // Rule 2/2: (reserved — imperative enforcement)

        case .diagnosis:
            // Rule 1/2: In debug/failed, strip softeners for assertive tone.
            if context.isDebugging || context.isFailed {
                text = text.replacingOccurrences(
                    of: #"(?i)\blikely\s+"#, with: "",
                    options: .regularExpression)
            }
            // Rule 2/2: Strip probabilistic hedging in debug/failed.
            if context.isDebugging || context.isFailed {
                text = text.replacingOccurrences(
                    of: #"(?i)\bprobably\s+"#, with: "",
                    options: .regularExpression)
            }

        case .concept:
            // Budget: max 1 rule (currently unused — concepts flow naturally).
            break

        case .flow:
            // Budget: 0 rules — never transform sequencing.
            break

        case .neutral:
            // Budget: 0 rules — never transform.
            break
        }

        return text
    }

    // MARK: Classification Word Lists

    private static let imperativeVerbs: Set<String> = [
        "run", "use", "add", "set", "check", "open", "close", "build",
        "install", "create", "update", "remove", "delete", "move", "copy",
        "import", "export", "deploy", "push", "pull", "boot", "reset",
        "restart", "verify", "test", "configure", "enable", "disable",
        "replace", "fix", "resolve", "wrap", "call", "pass", "return",
        "commit", "merge", "rebase", "start", "stop", "ensure", "confirm",
        "inspect", "read", "write", "patch", "apply", "revert", "clean",
        "link", "unlink", "attach", "detach", "register", "sign",
    ]

    private static let diagnosisMarkers: [String] = [
        "caused by", "issue", "error", "fails", "failing", "failed",
        "missing", " not ", "isn't", "aren't", "doesn't", "didn't",
        "won't", "can't", "couldn't", "broken", "invalid", "mismatch",
        "unexpected", "crash", "fault", "bug", "wrong", "problem",
    ]

    private static let conceptMarkers: [String] = [
        "state", "system", "architecture", "flow", "boundary",
        "layer", "abstraction", "pattern", "model", "pipeline",
        "framework", "protocol", "interface", "hierarchy", "graph",
        "dependency", "coupling", "separation", "module",
    ]

    private static let flowMarkers: [String] = [
        " then ", " next ", " after ", " once ", " before ",
        " finally ", " first ", " second ", " last ",
        " followed by", " leads to", " which triggers",
    ]

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 5: Rhythm Shaper                                    │
    // └─────────────────────────────────────────────────────────────┘

    private static func shapeRhythm(_ text: String, context: NarrativeRenderContext) -> String {
        guard context.isDebugging || context.isFailed else { return text }

        return mapProse(text) { prose in
            var paragraphs = prose.components(separatedBy: "\n\n")

            paragraphs = paragraphs.map { paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("- "),
                      !trimmed.hasPrefix("* ") else { return paragraph }

                if trimmed.count <= 120 {
                    return splitAfterFirstSentence(paragraph)
                }
                return splitAtSentenceBoundary(paragraph)
            }

            return paragraphs.joined(separator: "\n\n")
        }
    }

    private static func splitAtSentenceBoundary(_ paragraph: String) -> String {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"[.!?]\s+"#) else { return paragraph }

        let nsText = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsText.length))
        let safe = matches.filter { $0.range.location >= 30 && (trimmed.count - $0.range.location) >= 30 }
        guard !safe.isEmpty else { return paragraph }

        let mid = trimmed.count / 2
        let best = safe.min(by: { abs($0.range.location - mid) < abs($1.range.location - mid) })!
        let splitIdx = trimmed.index(trimmed.startIndex, offsetBy: best.range.location + 1)
        let first = String(trimmed[..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let second = String(trimmed[splitIdx...]).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !second.isEmpty else { return paragraph }

        return "\(first)\n\n\(second)"
    }

    private static func splitAfterFirstSentence(_ paragraph: String) -> String {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"[.!?]\s+"#) else { return paragraph }

        let nsText = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsText.length))
        guard let first = matches.first, first.range.location >= 15 else { return paragraph }

        let splitIdx = trimmed.index(trimmed.startIndex, offsetBy: first.range.location + 1)
        let head = String(trimmed[..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let tail = String(trimmed[splitIdx...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return paragraph }

        return "\(head)\n\n\(tail)"
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  Duplicate Collapse                                        │
    // └─────────────────────────────────────────────────────────────┘

    private static func collapseDuplicates(_ text: String) -> String {
        mapProse(text) { prose in
            let lines = prose.components(separatedBy: "\n")
            guard lines.count > 1 else { return prose }

            var result: [String] = [lines[0]]
            for i in 1..<lines.count {
                let cur = lines[i].trimmingCharacters(in: .whitespaces).lowercased()
                let prev = lines[i - 1].trimmingCharacters(in: .whitespaces).lowercased()

                guard !cur.isEmpty else { result.append(lines[i]); continue }
                if cur == prev { continue }

                let shorter = min(cur.count, prev.count)
                let longer = max(cur.count, prev.count)
                if shorter > 10, longer > 0 {
                    let overlap = cur.commonPrefix(with: prev).count
                    if Double(overlap) / Double(longer) >= 0.8 { continue }
                }

                result.append(lines[i])
            }
            return result.joined(separator: "\n")
        }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 6: Structure                                        │
    // └─────────────────────────────────────────────────────────────┘

    private static func structure(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  LAYER 7: Expressive Emoji System v2                       │
    // └─────────────────────────────────────────────────────────────┘

    /// Maximum emoji count per response.
    private static let maxEmojisPerResponse = 5

    /// Injects semantically meaningful emojis based on sentence intent and turn context.
    /// Roles: anchor (first strong sentence), reinforcement, emphasis.
    private static func injectEmojis(_ text: String, context: NarrativeRenderContext) -> String {
        // If the model already placed emojis, respect them.
        if countExistingEmojis(text) >= 2 { return text }

        let segments = separateCodeBlocks(text)
        var totalInjected = 0

        return segments.map { segment in
            guard !segment.isCode else { return segment.text }

            var lines = segment.text.components(separatedBy: "\n")

            for i in lines.indices {
                guard totalInjected < maxEmojisPerResponse else { break }

                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

                // Skip blank, headings, lists, very short, already has emoji.
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("- ["),
                      !trimmed.hasPrefix("- "),
                      !trimmed.hasPrefix("* "),
                      trimmed.count >= 20,
                      !lineHasEmoji(trimmed) else { continue }

                let intent = classify(trimmed)
                guard let emoji = selectEmoji(
                    intent: intent,
                    context: context,
                    isAnchor: totalInjected == 0
                ) else { continue }

                let role = totalInjected == 0 ? "anchor" : "reinforcement"
                if debugLogEmoji {
                    print("emoji: \(role)=\(emoji)  intent=\(intent)  line=\(i)")
                }

                let clean = lines[i].hasSuffix(" ") ? String(lines[i].dropLast()) : lines[i]
                lines[i] = "\(clean) \(emoji)"
                totalInjected += 1
            }

            return lines.joined(separator: "\n")
        }.joined()
    }

    /// Select an emoji based on sentence intent and turn context.
    /// Returns nil to skip — not every sentence gets an emoji.
    private static func selectEmoji(
        intent: SentenceIntent,
        context: NarrativeRenderContext,
        isAnchor: Bool
    ) -> String? {

        // Anchor (first placement): always emit based on context.
        if isAnchor {
            if context.isFailed            { return "🔍" }
            if context.isDebugging         { return "🔍" }
            if context.isArchitecture      { return "🧩" }
            if context.hasTools            { return "⚡" }
            return "🧠"
        }

        // Reinforcement + emphasis: intent-driven, selective.
        switch intent {
        case .action:
            return context.isDebugging ? "▶️" : "⚡"

        case .diagnosis:
            if context.isFailed { return "❗" }
            return "⚠️"

        case .concept:
            return "🧠"

        case .flow:
            // Flow sentences rarely need emoji — skip most.
            return nil

        case .neutral:
            // Neutrals only get emoji if they follow a long gap (sparse reinforcement).
            return nil
        }
    }

    /// Counts emoji characters already present in the text.
    /// NOTE: Heuristic emoji detection — filters `isEmoji && value > 0x23F3`
    /// to skip common symbols (©, ®, #, digits) that Swift marks as emoji.
    /// Assumes typical LLM output ranges; may need adjustment if models
    /// start emitting rare Unicode pictographics below this threshold.
    private static func countExistingEmojis(_ text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isEmoji && $0.value > 0x23F3 }.count
    }

    /// Checks if a single line already contains an emoji.
    /// Same heuristic threshold as `countExistingEmojis` — see note there.
    private static func lineHasEmoji(_ line: String) -> Bool {
        line.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x23F3 }
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  Code Block Isolation                                      │
    // └─────────────────────────────────────────────────────────────┘

    private struct TextSegment {
        let text: String
        let isCode: Bool
    }

    private static func separateCodeBlocks(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var remaining = text[...]

        while let openRange = remaining.range(of: "```") {
            let prose = String(remaining[remaining.startIndex..<openRange.lowerBound])
            if !prose.isEmpty { segments.append(TextSegment(text: prose, isCode: false)) }

            let afterOpen = remaining[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: "```") {
                segments.append(TextSegment(
                    text: String(remaining[openRange.lowerBound..<closeRange.upperBound]),
                    isCode: true
                ))
                remaining = remaining[closeRange.upperBound...]
            } else {
                segments.append(TextSegment(
                    text: String(remaining[openRange.lowerBound...]),
                    isCode: true
                ))
                remaining = remaining[remaining.endIndex...]
            }
        }

        let tail = String(remaining)
        if !tail.isEmpty { segments.append(TextSegment(text: tail, isCode: false)) }

        return segments
    }

    /// Maps a transform over prose segments only, preserving code blocks untouched.
    private static func mapProse(_ text: String, _ transform: (String) -> String) -> String {
        separateCodeBlocks(text).map { segment in
            segment.isCode ? segment.text : transform(segment.text)
        }.joined()
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  Shared Utilities                                          │
    // └─────────────────────────────────────────────────────────────┘

    private static func collapseSpaces(_ text: String) -> String {
        var t = text
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    private static func capitalizeFirstVisible(_ text: String) -> String {
        guard let idx = text.firstIndex(where: { $0.isLetter && $0.isLowercase }) else { return text }
        let before = text[text.startIndex..<idx]
        guard before.allSatisfy({ $0.isWhitespace || $0.isNewline }) else { return text }
        var result = text
        result.replaceSubrange(idx...idx, with: String(text[idx]).uppercased())
        return result
    }

    /// Capitalizes the capture group in all matches, working backwards for index safety.
    private static func regexCapitalize(_ text: String, pattern: String, group: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let range = match.range(at: group)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: nsText.substring(with: range).uppercased())
        }
        return result
    }

    // ┌─────────────────────────────────────────────────────────────┐
    // │  Pattern Tables                                            │
    // └─────────────────────────────────────────────────────────────┘

    private static let openerPatterns: [String] = [
        #"(?i)^Sure[,.]?\s*"#,
        #"(?i)^Absolutely[.!,]?\s*"#,
        #"(?i)^Great question[.!,]?\s*"#,
        #"(?i)^Nice[.!,]?\s*"#,
        #"(?i)^Of course[.!,]?\s*"#,
        #"(?i)^I'd be happy to help[.!]?\s*"#,
        #"(?i)^I'll go ahead and\s+"#,
        #"(?i)^Let me\s+"#,
        #"(?i)^Alright[,.]?\s*"#,
    ]

    private static let inlineFillerPatterns: [String] = [
        #"(?i)\bhere'?s?\s+what'?s?\s+happening:?\s*"#,
        #"(?i)\blet me explain:?\s*"#,
        #"(?i)\bas you can see,?\s*"#,
        #"(?i)\bit'?s?\s+worth\s+noting\s+that\s+"#,
        #"(?i)\bbasically,?\s*"#,
        #"(?i)\bessentially,?\s*"#,
        #"(?i)\bin order to\b"#,
    ]

    private static let tighteningRules: [(String, String)] = [
        (#"(?i)\byou\s+should\s+try\s+"#, ""),
        (#"(?i)\byou\s+should\s+"#, ""),
        (#"(?i)\byou\s+can\s+"#, ""),
        (#"(?i)\byou\s+need\s+to\s+"#, ""),
        (#"(?i)\byou\s+might\s+want\s+to\s+"#, ""),
        (#"(?i)\bthis\s+is\s+likely\s+due\s+to\b"#, "This is caused by"),
        (#"(?i)\bthis\s+might\s+be\s+caused\s+by\b"#, "This is caused by"),
        (#"(?i)\bthis\s+could\s+be\s+caused\s+by\b"#, "This is caused by"),
        (#"(?i)\bit\s+seems?\s+like\s+"#, ""),
        (#"(?i)\bit\s+looks?\s+like\s+"#, ""),
        (#"(?i)\bi\s+think\s+"#, ""),
        (#"(?i)\bi\s+believe\s+"#, ""),
        (#"(?i)\bplease\s+note\s+that\s+"#, ""),
        (#"(?i)\bin\s+order\s+to\b"#, "To"),
        (#"(?i)\bmake\s+sure\s+to\s+"#, ""),
        (#"(?i)\bgo\s+ahead\s+and\s+"#, ""),
        (#"(?i)\bit'?s?\s+important\s+to\s+note\s+that\s+"#, ""),
    ]

    private static let gerundMap: [(String, String)] = [
        ("running ", "Run "),   ("using ", "Use "),       ("adding ", "Add "),
        ("removing ", "Remove "), ("updating ", "Update "), ("setting ", "Set "),
        ("checking ", "Check "), ("creating ", "Create "), ("opening ", "Open "),
        ("closing ", "Close "),  ("building ", "Build "),   ("installing ", "Install "),
        ("configuring ", "Configure "), ("enabling ", "Enable "), ("disabling ", "Disable "),
        ("replacing ", "Replace "), ("deleting ", "Delete "), ("moving ", "Move "),
        ("copying ", "Copy "),   ("importing ", "Import "), ("exporting ", "Export "),
        ("restarting ", "Restart "), ("resetting ", "Reset "), ("verifying ", "Verify "),
        ("testing ", "Test "),   ("deploying ", "Deploy "), ("pushing ", "Push "),
        ("pulling ", "Pull "),   ("committing ", "Commit "), ("merging ", "Merge "),
        ("rebasing ", "Rebase "), ("wrapping ", "Wrap "),   ("calling ", "Call "),
        ("passing ", "Pass "),   ("returning ", "Return "),
    ]
}
