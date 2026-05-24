import Foundation

enum ArgosLocalTextTranslator {
    static func translateToTraditionalChinese(
        _ text: String,
        sourceLanguageCode: String?
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let source = normalize(sourceLanguageCode)
        guard source == "ja" || source == "en" || source == "zh" else {
            return ""
        }

        guard let scriptURL = Bundle.main.url(forResource: "translate_zt", withExtension: "py") else {
            return ""
        }

        let pythonCandidates = [
            "/Users/yihao.wang/.pyenv/versions/3.10.9/bin/python3",
            "/Users/yihao.wang/.pyenv/shims/python3",
            "/usr/bin/python3"
        ]
        guard let pythonPath = pythonCandidates.first(where: FileManager.default.isExecutableFile) else {
            return ""
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [scriptURL.path, source]

            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()

            try process.run()
            stdin.fileHandleForWriting.write(Data(trimmed.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return ""
            }

            return String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private static func normalize(_ sourceLanguageCode: String?) -> String {
        let code = sourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.isEmpty || code == "auto" {
            return "ja"
        }
        if code.hasPrefix("zh") {
            return "zh"
        }
        return code
    }
}
