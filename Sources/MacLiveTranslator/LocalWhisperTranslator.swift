import Foundation

struct CaptionSegment: Identifiable {
    let id = UUID()
    let original: String
    let translation: String
}

@MainActor
final class LocalWhisperTranslator: ObservableObject {
    @Published var status = "尚未啟動"
    @Published var segments: [CaptionSegment] = []
    @Published var errorMessage: String?
    @Published var isReady = false

    var latestOriginal: String {
        segments.last?.original ?? ""
    }

    var latestTranslation: String {
        segments.last?.translation ?? ""
    }

    private let sampleRate = 16_000
    private let chunkSeconds = 5
    private let processingQueue = DispatchQueue(label: "local-whisper-translator")
    private var audioBuffer = Data()
    private var isProcessing = false
    private var modelPath = ""
    private var sourceLanguageCode = "auto"

    private var maxChunkBytes: Int {
        sampleRate * chunkSeconds * MemoryLayout<Int16>.size
    }

    func start(modelPath: String, sourceLanguageCode: String) {
        self.modelPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLanguageCode = sourceLanguageCode
        audioBuffer.removeAll()
        isProcessing = false
        segments.removeAll()

        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/whisper-cli") else {
            errorMessage = "找不到 /opt/homebrew/bin/whisper-cli。"
            status = "本地 Whisper 不可用"
            isReady = false
            return
        }

        guard FileManager.default.fileExists(atPath: self.modelPath) else {
            errorMessage = "找不到 Whisper 模型：\(self.modelPath)"
            status = "模型不存在"
            isReady = false
            return
        }

        isReady = true
        status = sourceLanguageCode == "auto" ? "本地 Whisper 已就緒：自動偵測語音" : "本地 Whisper 已就緒：\(sourceLanguageCode)"
    }

    func stop() {
        audioBuffer.removeAll()
        isProcessing = false
        isReady = false
        status = "已停止"
    }

    func appendAudio(_ data: Data) {
        guard isReady else { return }
        audioBuffer.append(data)

        guard audioBuffer.count >= maxChunkBytes, !isProcessing else { return }
        let chunk = audioBuffer.prefix(maxChunkBytes)
        audioBuffer.removeFirst(maxChunkBytes)
        processChunk(Data(chunk))
    }

    private func processChunk(_ pcm16: Data) {
        isProcessing = true
        status = "本地辨識中..."
        let modelPath = self.modelPath
        let sourceLanguageCode = self.sourceLanguageCode

        processingQueue.async { [sampleRate] in
            let result = Self.runWhisperOriginal(
                pcm16: pcm16,
                sampleRate: sampleRate,
                modelPath: modelPath,
                sourceLanguageCode: sourceLanguageCode
            )

            Task { @MainActor in
                switch result {
                case .success(let original):
                    let detectedSource = sourceLanguageCode == "auto" ? nil : sourceLanguageCode
                    let translation = await ArgosLocalTextTranslator.translateToTraditionalChinese(
                        original,
                        sourceLanguageCode: detectedSource
                    )
                    self.isProcessing = false
                    self.appendSegment(original: original, translation: translation)
                case .failure(let error):
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    self.status = "本地辨識失敗"
                }

                if self.audioBuffer.count >= self.maxChunkBytes, self.isReady {
                    let next = self.audioBuffer.prefix(self.maxChunkBytes)
                    self.audioBuffer.removeFirst(self.maxChunkBytes)
                    self.processChunk(Data(next))
                }
            }
        }
    }

    private func appendSegment(original: String, translation: String) {
        if !original.isEmpty || !translation.isEmpty {
            segments.append(CaptionSegment(original: original, translation: translation))
            if segments.count > 20 {
                segments.removeFirst(segments.count - 20)
            }
        }
        status = isReady ? "正在聽預設輸入裝置" : "已停止"
    }

    nonisolated private static func runWhisperOriginal(
        pcm16: Data,
        sampleRate: Int,
        modelPath: String,
        sourceLanguageCode: String
    ) -> Result<String, Error> {
        do {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacLiveTranslator", isDirectory: true)
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )

            let base = tempDirectory.appendingPathComponent(UUID().uuidString)
            let wavURL = base.appendingPathExtension("wav")
            try makeWAV(pcm16: pcm16, sampleRate: sampleRate).write(to: wavURL)
            defer { try? FileManager.default.removeItem(at: wavURL) }

            let original = try runWhisperCommand(
                wavURL: wavURL,
                modelPath: modelPath,
                languageCode: sourceLanguageCode,
                translateToEnglish: false
            )

            let visibleOriginal = shouldSkip(original) ? "" : original
            return .success(visibleOriginal)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func runWhisperCommand(
        wavURL: URL,
        modelPath: String,
        languageCode: String,
        translateToEnglish: Bool
    ) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
            process.arguments = [
                "-m", modelPath,
                "-f", wavURL.path,
                "-l", languageCode,
                "-nt",
                "-np"
            ]

            if translateToEnglish {
                process.arguments?.append("--translate")
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let output = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let diagnostics = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            guard process.terminationStatus == 0 else {
                throw LocalWhisperError.processFailed(diagnostics)
            }

            return clean(output)
    }

    nonisolated private static func clean(_ output: String) -> String {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func shouldSkip(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let scalars = Array(trimmed.unicodeScalars)
        let uniqueScalars = Set(scalars)
        if scalars.count >= 4, uniqueScalars.count <= 2 {
            return true
        }

        let lower = trimmed.lowercased()
        let knownNoise = [
            "thank you",
            "thanks for watching",
            "字幕",
            "ご視聴ありがとうございました"
        ]
        return knownNoise.contains { lower.contains($0) }
    }

    nonisolated private static func makeWAV(pcm16: Data, sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let chunkSize = UInt32(36 + pcm16.count)

        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(chunkSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(pcm16.count))
        data.append(pcm16)
        return data
    }
}

private enum LocalWhisperError: LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let diagnostics):
            return diagnostics.isEmpty ? "whisper-cli 執行失敗。" : diagnostics
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
