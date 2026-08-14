import Foundation
import MLXLMCommon
import Tokenizers

/// Adapts swift-transformers' tokenizer to the one `MLXLMCommon` expects.
///
/// The two packages each declare their own `Tokenizer` protocol with the same
/// job and slightly different spellings, so something has to sit between them.
/// MLX ships a `#huggingFaceTokenizerLoader()` macro that generates this exact
/// bridge; it is written out here instead because the macro arrives with a
/// swift-syntax compiler plugin attached and is bundled with a downloader whose
/// destination cannot be changed. See the note in `project.yml`.
///
/// If `MLXLMCommon.Tokenizer` ever gains a requirement, this stops compiling.
/// That is the intended failure: a build error rather than a silent divergence.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    /// swift-transformers spells this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
