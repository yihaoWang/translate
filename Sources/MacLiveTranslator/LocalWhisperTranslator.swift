import Foundation

struct CaptionSegment: Identifiable {
    let id = UUID()
    let original: String
    let translation: String
}

struct SpeechDispatchSettings {
    var speechThreshold: Double
    var silenceMs: Double
    var minUtteranceMs: Double
    var maxUtteranceMs: Double

    static let balanced = SpeechDispatchSettings(
        speechThreshold: 0.012,
        silenceMs: 900,
        minUtteranceMs: 900,
        maxUtteranceMs: 8_000
    )
}

@MainActor
final class LocalWhisperTranslator: ObservableObject {
    @Published var status = "尚未啟動"
    @Published var segments: [CaptionSegment] = []
    @Published var errorMessage: String?
    @Published var isReady = false
    @Published var lastWhisperMs: Int?
    @Published var lastTranslationMs: Int?
    @Published var lastTotalMs: Int?

    var latestOriginal: String {
        segments.last?.original ?? ""
    }

    var latestTranslation: String {
        segments.last?.translation ?? ""
    }

    var visibleSegments: [CaptionSegment] {
        Array(segments.suffix(2))
    }

    private let sampleRate = 16_000
    private let processingQueue = DispatchQueue(label: "local-whisper-translator")
    private var preSpeechBuffer = Data()
    private var utteranceBuffer = Data()
    private var pendingUtterances: [Data] = []
    private var isCapturingSpeech = false
    private var silenceBytes = 0
    private var isProcessing = false
    private var modelPath = ""
    private var sourceLanguageCode = "auto"
    private var settings = SpeechDispatchSettings.balanced
    private var sessionToken = UUID()
    private var lastAudioAt: Date?
    private var lastSpeechAt: Date?
    private var lastStatusUpdateAt = Date.distantPast

    private var bytesPerMillisecond: Int {
        sampleRate * MemoryLayout<Int16>.size / 1_000
    }

    private var preSpeechBytes: Int {
        bytes(forMilliseconds: 220)
    }

    private var minUtteranceBytes: Int {
        bytes(forMilliseconds: settings.minUtteranceMs)
    }

    private var maxUtteranceBytes: Int {
        bytes(forMilliseconds: settings.maxUtteranceMs)
    }

    private var silenceLimitBytes: Int {
        bytes(forMilliseconds: settings.silenceMs)
    }

    func start(
        modelPath: String,
        sourceLanguageCode: String,
        settings: SpeechDispatchSettings
    ) {
        self.modelPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLanguageCode = sourceLanguageCode
        self.settings = settings
        sessionToken = UUID()
        resetAudioState()
        isProcessing = false
        segments.removeAll()
        lastWhisperMs = nil
        lastTranslationMs = nil
        lastTotalMs = nil
        lastAudioAt = nil
        lastSpeechAt = nil
        lastStatusUpdateAt = .distantPast

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
        sessionToken = UUID()
        resetAudioState()
        isProcessing = false
        isReady = false
        status = "已停止"
    }

    func appendAudio(_ data: Data) {
        guard isReady else { return }
        let rms = Self.rmsNormalized(data)
        let now = Date()
        lastAudioAt = now
        let isSpeech = rms >= settings.speechThreshold

        if !isCapturingSpeech {
            appendPreSpeech(data)
            guard isSpeech else {
                updateListeningStatusIfNeeded(rms: rms, now: now)
                return
            }

            lastSpeechAt = now
            isCapturingSpeech = true
            silenceBytes = 0
            utteranceBuffer = preSpeechBuffer
            status = "收音中..."
            return
        }

        utteranceBuffer.append(data)

        if isSpeech {
            lastSpeechAt = now
            silenceBytes = 0
        } else {
            silenceBytes += data.count
        }

        let isLongEnough = utteranceBuffer.count >= minUtteranceBytes
        let shouldEndForPause = isLongEnough && silenceBytes >= silenceLimitBytes
        let shouldEndForLength = utteranceBuffer.count >= maxUtteranceBytes

        if shouldEndForPause || shouldEndForLength {
            enqueueUtterance(utteranceBuffer)
            resetCurrentUtterance()
        }
    }

    private func updateListeningStatusIfNeeded(rms: Double, now: Date) {
        guard !isProcessing, now.timeIntervalSince(lastStatusUpdateAt) > 0.5 else { return }
        lastStatusUpdateAt = now

        if let lastSpeechAt, now.timeIntervalSince(lastSpeechAt) < 2.5 {
            status = "等待下一句..."
            return
        }

        if rms < 0.0001 {
            status = "未收到系統音訊"
        } else {
            status = "正在擷取系統輸出音訊"
        }
    }

    private func enqueueUtterance(_ pcm16: Data) {
        guard pcm16.count >= minUtteranceBytes else { return }
        guard Self.rmsNormalized(pcm16) >= settings.speechThreshold * 0.45 else {
            status = "靜音已略過"
            return
        }

        pendingUtterances.append(pcm16)
        processNextUtteranceIfNeeded()
    }

    private func processNextUtteranceIfNeeded() {
        guard !isProcessing, !pendingUtterances.isEmpty else { return }
        let next = pendingUtterances.removeFirst()
        processChunk(next)
    }

    private func processChunk(_ pcm16: Data) {
        isProcessing = true
        status = "本地辨識中..."
        let modelPath = self.modelPath
        let sourceLanguageCode = self.sourceLanguageCode
        let utteranceStartedAt = Date()
        let token = sessionToken

        processingQueue.async { [sampleRate] in
            let whisperStartedAt = Date()
            let result = Self.runWhisperOriginal(
                pcm16: pcm16,
                sampleRate: sampleRate,
                modelPath: modelPath,
                sourceLanguageCode: sourceLanguageCode
            )
            let whisperMs = Self.elapsedMilliseconds(since: whisperStartedAt)

            Task { @MainActor in
                guard self.sessionToken == token, self.isReady else {
                    self.isProcessing = false
                    return
                }

                switch result {
                case .success(let original):
                    self.status = original.isEmpty ? "靜音已略過" : "翻譯中..."
                    if !original.isEmpty {
                        self.appendSegment(original: original, translation: "翻譯中...")
                    }
                    let detectedSource = sourceLanguageCode == "auto" ? nil : sourceLanguageCode
                    let translationStartedAt = Date()
                    let translation = await ArgosLocalTextTranslator.translateToTraditionalChinese(
                        original,
                        sourceLanguageCode: detectedSource
                    )
                    let translationMs = Self.elapsedMilliseconds(since: translationStartedAt)
                    self.isProcessing = false
                    self.lastWhisperMs = whisperMs
                    self.lastTranslationMs = translationMs
                    self.lastTotalMs = Self.elapsedMilliseconds(since: utteranceStartedAt)
                    self.replaceLatestSegment(original: original, translation: translation)
                case .failure(let error):
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    self.status = "本地辨識失敗"
                }

                self.processNextUtteranceIfNeeded()
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
        if let lastTotalMs {
            status = isReady ? "完成 \(lastTotalMs)ms" : "已停止"
        } else {
            status = isReady ? "正在擷取系統輸出音訊" : "已停止"
        }
    }

    private func replaceLatestSegment(original: String, translation: String) {
        guard !original.isEmpty || !translation.isEmpty else {
            appendSegment(original: original, translation: translation)
            return
        }

        if let last = segments.last, last.original == original {
            segments[segments.count - 1] = CaptionSegment(original: original, translation: translation)
        } else {
            appendSegment(original: original, translation: translation)
            return
        }

        if let lastTotalMs {
            status = isReady ? "完成 \(lastTotalMs)ms" : "已停止"
        } else {
            status = isReady ? "正在擷取系統輸出音訊" : "已停止"
        }
    }

    private func appendPreSpeech(_ data: Data) {
        preSpeechBuffer.append(data)
        if preSpeechBuffer.count > preSpeechBytes {
            preSpeechBuffer.removeFirst(preSpeechBuffer.count - preSpeechBytes)
        }
    }

    private func resetAudioState() {
        preSpeechBuffer.removeAll()
        utteranceBuffer.removeAll()
        pendingUtterances.removeAll()
        resetCurrentUtterance()
    }

    private func resetCurrentUtterance() {
        utteranceBuffer.removeAll()
        isCapturingSpeech = false
        silenceBytes = 0
        preSpeechBuffer.removeAll(keepingCapacity: true)
    }

    private func bytes(forMilliseconds milliseconds: Double) -> Int {
        max(bytesPerMillisecond, Int(milliseconds) * bytesPerMillisecond)
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
        let bracketedNoise = [
            "(笑)",
            "（笑）",
            "(笑い)",
            "（笑い）",
            "(笑い声)",
            "（笑い声）",
            "[笑]",
            "【笑】",
            "(音楽)",
            "（音楽）",
            "[音楽]",
            "【音楽】",
            "(拍手)",
            "（拍手）",
            "[拍手]",
            "【拍手】",
            "(沈黙)",
            "（沈黙）",
            "[沈黙]",
            "【沈黙】",
            "(laughs)",
            "[laughs]",
            "(laughter)",
            "[laughter]",
            "(music)",
            "[music]",
            "(applause)",
            "[applause]"
        ]
        if bracketedNoise.contains(where: { lower == $0.lowercased() }) {
            return true
        }

        let knownNoise = [
            "笑",
            "笑い",
            "笑い声",
            "thank you",
            "thanks for watching",
            "字幕",
            "音楽",
            "ご視聴ありがとうございました"
        ]
        return knownNoise.contains { lower.contains($0) }
    }

    nonisolated private static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    nonisolated private static func rmsNormalized(_ data: Data) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(Int16(littleEndian: sample)) / 32768.0
                sumSquares += normalized * normalized
            }
        }

        return sqrt(sumSquares / Double(sampleCount))
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
