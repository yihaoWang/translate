import Foundation
import Translation

enum AppleLocalTextTranslator {
    static func translateToTraditionalChinese(
        _ text: String,
        sourceLanguageCode: String?
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard #available(macOS 26.0, *) else {
            return ""
        }

        guard let sourceLanguageCode, !sourceLanguageCode.isEmpty else {
            return ""
        }

        do {
            let source = Locale.Language(identifier: sourceLanguageCode)
            let target = Locale.Language(identifier: "zh-Hant")
            let availability = LanguageAvailability()
            let status = await availability.status(from: source, to: target)
            guard status == .installed else {
                return ""
            }

            let session = TranslationSession(installedSource: source, target: target)
            try await session.prepareTranslation()
            let response = try await session.translate(trimmed)
            return response.targetText
        } catch {
            return ""
        }
    }
}
