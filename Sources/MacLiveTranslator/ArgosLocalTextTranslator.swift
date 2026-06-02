import Foundation

enum ArgosLocalTextTranslator {
    static func warmUp(sourceLanguageCode: String?) async {
        let requestedSource = normalize(sourceLanguageCode, text: "")
        let sources = requestedSource == "auto" ? ["ja", "en"] : [requestedSource]
        for source in sources where source == "ja" || source == "en" || source == "zh" {
            let sample = source == "en" ? "Hello" : "はい"
            if source == "ja" || source == "en" {
                _ = await AppleLocalTextTranslator.translateToTraditionalChinese(sample, sourceLanguageCode: source)
            }
            _ = try? await PersistentArgosTranslator.shared.translate(sample, source: source)
        }
    }

    static func translateToTraditionalChinese(
        _ text: String,
        sourceLanguageCode: String?
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let source = normalize(sourceLanguageCode, text: trimmed)
        guard source == "ja" || source == "en" || source == "zh" else {
            return ""
        }

        let cacheKey = "\(source):\(trimmed)"
        if let cached = await TranslationMemory.shared.value(for: cacheKey) {
            return cached
        }

        if source == "ja" || source == "en" {
            let appleTranslated = await AppleLocalTextTranslator.translateToTraditionalChinese(
                trimmed,
                sourceLanguageCode: source
            )
            if !appleTranslated.isEmpty {
                await TranslationMemory.shared.set(appleTranslated, for: cacheKey)
                return appleTranslated
            }
        }

        do {
            let translated = try await PersistentArgosTranslator.shared.translate(
                trimmed,
                source: source
            )
            await TranslationMemory.shared.set(translated, for: cacheKey)
            return translated
        } catch {
            return ""
        }
    }

    private static func normalize(_ sourceLanguageCode: String?, text: String) -> String {
        let code = sourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.isEmpty || code == "auto" {
            return inferSourceLanguage(from: text)
        }
        if code.hasPrefix("zh") {
            return "zh"
        }
        return code
    }

    private static func inferSourceLanguage(from text: String) -> String {
        let scalars = text.unicodeScalars
        let latinCount = scalars.filter {
            (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value))
        }.count
        let kanaCount = scalars.filter {
            (0x3040...0x30FF).contains(Int($0.value))
        }.count
        let hanCount = scalars.filter {
            (0x4E00...0x9FFF).contains(Int($0.value))
        }.count

        if latinCount >= max(4, kanaCount + hanCount) {
            return "en"
        }
        if kanaCount > 0 {
            return "ja"
        }
        if hanCount > 0 {
            return "zh"
        }
        return text.isEmpty ? "auto" : "ja"
    }
}

private actor PersistentArgosTranslator {
    static let shared = PersistentArgosTranslator()

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?

    func translate(_ text: String, source: String) throws -> String {
        try ensureProcess()
        guard let stdin, let stdout else { return "" }

        let request: [String: String] = [
            "source": source,
            "text": text
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        stdin.write(requestData)
        stdin.write(Data([0x0A]))

        let responseLine = try readLine(from: stdout)
        guard
            let responseData = responseLine.data(using: .utf8),
            let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            response["ok"] as? Bool == true
        else {
            restart()
            return ""
        }

        return response["text"] as? String ?? ""
    }

    private func ensureProcess() throws {
        if let process, process.isRunning {
            return
        }

        guard let scriptURL = Bundle.main.url(forResource: "translate_zt_server", withExtension: "py") else {
            throw TranslationProcessError.missingScript
        }

        let pythonCandidates = [
            "/Users/yihao.wang/.pyenv/versions/3.10.9/bin/python3",
            "/Users/yihao.wang/.pyenv/shims/python3",
            "/usr/bin/python3"
        ]
        guard let pythonPath = pythonCandidates.first(where: FileManager.default.isExecutableFile) else {
            throw TranslationProcessError.missingPython
        }

        let newProcess = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        newProcess.executableURL = URL(fileURLWithPath: pythonPath)
        newProcess.arguments = [scriptURL.path]
        newProcess.standardInput = inputPipe
        newProcess.standardOutput = outputPipe
        newProcess.standardError = FileHandle.nullDevice

        try newProcess.run()
        process = newProcess
        stdin = inputPipe.fileHandleForWriting
        stdout = outputPipe.fileHandleForReading
    }

    private func restart() {
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
    }

    private func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                throw TranslationProcessError.closedPipe
            }
            if byte[0] == 0x0A {
                break
            }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum TranslationProcessError: Error {
    case missingScript
    case missingPython
    case closedPipe
}

private actor TranslationMemory {
    static let shared = TranslationMemory()

    private var values: [String: String] = [:]
    private var keys: [String] = []
    private let limit = 300

    func value(for key: String) -> String? {
        values[key]
    }

    func set(_ value: String, for key: String) {
        guard !value.isEmpty else { return }
        if values[key] == nil {
            keys.append(key)
        }
        values[key] = value

        while keys.count > limit, let oldest = keys.first {
            keys.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}
