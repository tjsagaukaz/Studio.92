import Foundation

struct ToolResultContentBlockCodable: Codable {
    let block: ToolResultContentBlock

    init(_ block: ToolResultContentBlock) {
        self.block = block
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
        case title
        case content
        case citations
    }

    struct CitationConfig: Codable, Equatable {
        let enabled: Bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            block = .text(try container.decode(String.self, forKey: .text))
        case "search_result":
            let source = try container.decode(String.self, forKey: .source)
            let title = try container.decode(String.self, forKey: .title)
            let nested = try container.decode([ToolResultContentBlockCodable].self, forKey: .content)
            let texts = nested.compactMap { nestedBlock -> String? in
                if case .text(let value) = nestedBlock.block {
                    return value
                }
                return nil
            }
            let citations = try container.decodeIfPresent(CitationConfig.self, forKey: .citations)
            block = .searchResult(
                ToolResultSearchResult(
                    source: source,
                    title: title,
                    texts: texts,
                    citationsEnabled: citations?.enabled ?? false
                )
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown tool result content block type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch block {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .searchResult(let result):
            try container.encode("search_result", forKey: .type)
            try container.encode(result.source, forKey: .source)
            try container.encode(result.title, forKey: .title)
            try container.encode(
                result.texts.map { ToolResultContentBlockCodable(.text($0)) },
                forKey: .content
            )
            try container.encode(CitationConfig(enabled: result.citationsEnabled), forKey: .citations)
        }
    }
}
