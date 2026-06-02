import Foundation

enum SpeechRecognitionEngine: String, CaseIterable, Identifiable {
    case localWhisper = "Local Whisper"
    case openAICloud = "OpenAI Cloud"

    var id: String { rawValue }
}

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
    var speakerChangeEnabled: Bool = true
    var speakerChangeSensitivity: Double = 0.58
    var minSpeakerChangeIntervalMs: Double = 1_150

    static let balanced = SpeechDispatchSettings(
        speechThreshold: 0.012,
        silenceMs: 900,
        minUtteranceMs: 900,
        maxUtteranceMs: 8_000,
        speakerChangeEnabled: true,
        speakerChangeSensitivity: 0.58,
        minSpeakerChangeIntervalMs: 1_150
    )
}

private struct VoiceFeature {
    let logRMS: Double
    let zeroCrossingRate: Double
    let peakToRMS: Double

    func distance(to other: VoiceFeature) -> Double {
        let rmsDistance = min(1.0, abs(logRMS - other.logRMS) / 1.6)
        let zcrDistance = min(1.0, abs(zeroCrossingRate - other.zeroCrossingRate) / 0.18)
        let crestDistance = min(1.0, abs(peakToRMS - other.peakToRMS) / 3.5)
        return rmsDistance * 0.20 + zcrDistance * 0.55 + crestDistance * 0.25
    }

    func blended(with other: VoiceFeature, weight: Double) -> VoiceFeature {
        VoiceFeature(
            logRMS: logRMS * (1 - weight) + other.logRMS * weight,
            zeroCrossingRate: zeroCrossingRate * (1 - weight) + other.zeroCrossingRate * weight,
            peakToRMS: peakToRMS * (1 - weight) + other.peakToRMS * weight
        )
    }
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
    private var recentSpeechBuffer = Data()
    private var utteranceBuffer = Data()
    private var pendingUtterances: [Data] = []
    private var isCapturingSpeech = false
    private var silenceBytes = 0
    private var speakerChangeStreak = 0
    private var bytesSinceLastSpeakerBoundary = 0
    private var speakerFeatureProfile: VoiceFeature?
    private var isProcessing = false
    private var modelPath = ""
    private var sourceLanguageCode = "auto"
    private var recognitionEngine: SpeechRecognitionEngine = .localWhisper
    private var openAIAPIKey = ""
    private var openAITranscriptionModel = "gpt-4o-mini-transcribe"
    private var translationEnabled = true
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

    private var speakerCarryoverBytes: Int {
        bytes(forMilliseconds: 180)
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

    private var minSpeakerChangeIntervalBytes: Int {
        bytes(forMilliseconds: settings.minSpeakerChangeIntervalMs)
    }

    func start(
        modelPath: String,
        sourceLanguageCode: String,
        recognitionEngine: SpeechRecognitionEngine,
        openAIAPIKey: String,
        openAITranscriptionModel: String,
        translationEnabled: Bool,
        settings: SpeechDispatchSettings
    ) {
        self.modelPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLanguageCode = sourceLanguageCode
        self.recognitionEngine = recognitionEngine
        self.openAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAITranscriptionModel = openAITranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translationEnabled = translationEnabled
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

        switch recognitionEngine {
        case .localWhisper:
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
        case .openAICloud:
            guard !self.openAIAPIKey.isEmpty else {
                errorMessage = "請在 Settings 輸入 OPENAI_API_KEY。"
                status = "OpenAI Cloud 不可用"
                isReady = false
                return
            }
        }

        isReady = true
        let languageStatus = sourceLanguageCode == "auto" ? "自動偵測語音" : sourceLanguageCode
        status = recognitionEngine == .localWhisper ? "本地 Whisper 已就緒：\(languageStatus)" : "OpenAI Cloud 已就緒：\(languageStatus)"
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
        let currentFeature = isSpeech ? Self.voiceFeature(data, rms: rms) : nil

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
            speakerFeatureProfile = currentFeature
            speakerChangeStreak = 0
            bytesSinceLastSpeakerBoundary = utteranceBuffer.count
            appendRecentSpeech(data)
            status = "收音中..."
            return
        }

        if shouldEndForSpeakerChange(feature: currentFeature) {
            enqueueUtterance(utteranceBuffer)
            startNewUtteranceAfterSpeakerChange(with: data, feature: currentFeature, now: now)
            return
        }

        utteranceBuffer.append(data)
        bytesSinceLastSpeakerBoundary += data.count
        if isSpeech {
            appendRecentSpeech(data)
        }

        if isSpeech {
            lastSpeechAt = now
            silenceBytes = 0
            updateSpeakerProfile(with: currentFeature)
        } else {
            silenceBytes += data.count
            speakerChangeStreak = 0
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
        let recognitionEngine = self.recognitionEngine
        let openAIAPIKey = self.openAIAPIKey
        let openAITranscriptionModel = self.openAITranscriptionModel
        let translationEnabled = self.translationEnabled
        let utteranceStartedAt = Date()
        let token = sessionToken

        processingQueue.async { [sampleRate] in
            let whisperStartedAt = Date()
            let result = Self.runWhisperOriginal(
                pcm16: pcm16,
                sampleRate: sampleRate,
                modelPath: modelPath,
                sourceLanguageCode: sourceLanguageCode,
                recognitionEngine: recognitionEngine,
                openAIAPIKey: openAIAPIKey,
                openAITranscriptionModel: openAITranscriptionModel
            )
            let whisperMs = Self.elapsedMilliseconds(since: whisperStartedAt)

            Task { @MainActor in
                guard self.sessionToken == token, self.isReady else {
                    self.isProcessing = false
                    return
                }

                switch result {
                case .success(let original):
                    self.status = original.isEmpty ? "靜音已略過" : (translationEnabled ? "翻譯中..." : "完成")
                    guard !original.isEmpty else {
                        self.isProcessing = false
                        self.lastWhisperMs = whisperMs
                        self.lastTranslationMs = nil
                        self.lastTotalMs = Self.elapsedMilliseconds(since: utteranceStartedAt)
                        self.processNextUtteranceIfNeeded()
                        return
                    }

                    if !translationEnabled {
                        self.isProcessing = false
                        self.lastWhisperMs = whisperMs
                        self.lastTranslationMs = nil
                        self.lastTotalMs = Self.elapsedMilliseconds(since: utteranceStartedAt)
                        self.appendSegment(original: original, translation: "")
                        self.processNextUtteranceIfNeeded()
                        return
                    }

                    self.appendSegment(original: original, translation: "翻譯中...")
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

    private func appendRecentSpeech(_ data: Data) {
        recentSpeechBuffer.append(data)
        if recentSpeechBuffer.count > speakerCarryoverBytes {
            recentSpeechBuffer.removeFirst(recentSpeechBuffer.count - speakerCarryoverBytes)
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
        speakerChangeStreak = 0
        bytesSinceLastSpeakerBoundary = 0
        speakerFeatureProfile = nil
        recentSpeechBuffer.removeAll(keepingCapacity: true)
        preSpeechBuffer.removeAll(keepingCapacity: true)
    }

    private func startNewUtteranceAfterSpeakerChange(with data: Data, feature: VoiceFeature?, now: Date) {
        utteranceBuffer = recentSpeechBuffer
        utteranceBuffer.append(data)
        silenceBytes = 0
        speakerChangeStreak = 0
        bytesSinceLastSpeakerBoundary = utteranceBuffer.count
        speakerFeatureProfile = feature
        recentSpeechBuffer.removeAll(keepingCapacity: true)
        appendRecentSpeech(data)
        lastSpeechAt = now
        status = "偵測到換人，切分字幕..."
    }

    private func shouldEndForSpeakerChange(feature: VoiceFeature?) -> Bool {
        guard
            settings.speakerChangeEnabled,
            let feature,
            let profile = speakerFeatureProfile,
            utteranceBuffer.count >= minUtteranceBytes,
            bytesSinceLastSpeakerBoundary >= minSpeakerChangeIntervalBytes
        else {
            updateSpeakerProfile(with: feature)
            return false
        }

        let distance = feature.distance(to: profile)
        let threshold = max(0.25, min(0.85, settings.speakerChangeSensitivity))
        if distance >= threshold {
            speakerChangeStreak += 1
        } else {
            speakerChangeStreak = 0
            updateSpeakerProfile(with: feature)
        }

        return speakerChangeStreak >= 2
    }

    private func updateSpeakerProfile(with feature: VoiceFeature?) {
        guard let feature else { return }
        if let profile = speakerFeatureProfile {
            speakerFeatureProfile = profile.blended(with: feature, weight: 0.12)
        } else {
            speakerFeatureProfile = feature
        }
    }

    private func bytes(forMilliseconds milliseconds: Double) -> Int {
        max(bytesPerMillisecond, Int(milliseconds) * bytesPerMillisecond)
    }

    nonisolated private static func runWhisperOriginal(
        pcm16: Data,
        sampleRate: Int,
        modelPath: String,
        sourceLanguageCode: String,
        recognitionEngine: SpeechRecognitionEngine,
        openAIAPIKey: String,
        openAITranscriptionModel: String
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

            if recognitionEngine == .openAICloud {
                let original = try runOpenAITranscription(
                    wavURL: wavURL,
                    apiKey: openAIAPIKey,
                    model: openAITranscriptionModel.isEmpty ? "gpt-4o-mini-transcribe" : openAITranscriptionModel,
                    languageCode: sourceLanguageCode
                )
                return .success(shouldSkip(original) ? "" : original)
            }

            var original = try runWhisperCommand(
                wavURL: wavURL,
                modelPath: modelPath,
                languageCode: sourceLanguageCode,
                translateToEnglish: false
            )

            if shouldRetryWithAccuracyModel(
                original,
                pcm16ByteCount: pcm16.count,
                sampleRate: sampleRate,
                modelPath: modelPath,
                sourceLanguageCode: sourceLanguageCode
            ), let accuracyModelPath = accuracyModelPath(excluding: modelPath) {
                let retried = try runWhisperCommand(
                    wavURL: wavURL,
                    modelPath: accuracyModelPath,
                    languageCode: sourceLanguageCode,
                    translateToEnglish: false
                )
                if !shouldSkip(retried) {
                    original = retried
                }
            }

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
                "-np",
                "-sns",
                "--prompt", prompt(for: languageCode)
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

    nonisolated private static func runOpenAITranscription(
        wavURL: URL,
        apiKey: String,
        model: String,
        languageCode: String
    ) throws -> String {
        guard !apiKey.isEmpty else {
            throw LocalWhisperError.missingOpenAIAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "MacLiveTranslator-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(
            boundary: boundary,
            fields: openAITranscriptionFields(model: model, languageCode: languageCode),
            fileURL: wavURL
        )

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(LocalWhisperError.openAIRequestFailed("OpenAI transcription returned no HTTP response."))
                return
            }

            let responseData = data ?? Data()
            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                result = .failure(LocalWhisperError.openAIRequestFailed("OpenAI transcription failed (\(httpResponse.statusCode)): \(body)"))
                return
            }

            result = .success(responseData)
        }.resume()

        if semaphore.wait(timeout: .now() + 50) == .timedOut {
            throw LocalWhisperError.openAIRequestFailed("OpenAI transcription timed out.")
        }

        let responseData = try result?.get() ?? Data()
        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let text = json["text"] as? String
        else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw LocalWhisperError.openAIRequestFailed("OpenAI transcription returned unexpected response: \(body)")
        }

        return clean(text)
    }

    nonisolated private static func openAITranscriptionFields(model: String, languageCode: String) -> [String: String] {
        var fields = [
            "model": model,
            "response_format": "json",
            "prompt": prompt(for: languageCode)
        ]

        if languageCode != "auto" {
            fields["language"] = languageCode
        }

        return fields
    }

    nonisolated private static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileURL: URL
    ) throws -> Data {
        var body = Data()

        for (name, value) in fields {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }

        let fileData = try Data(contentsOf: fileURL)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(fileData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    nonisolated private static func prompt(for languageCode: String) -> String {
        if languageCode == "ja" || languageCode == "auto" {
            return "これは日本語の自然な会話です。聞こえた発話だけを字幕として正確に書き起こしてください。音楽、笑い声、効果音、説明文は書かないでください。"
        }

        if languageCode == "zh" {
            return "這是自然對話。只輸出聽到的人聲字幕，不要輸出音樂、笑聲或說明。"
        }

        return "Transcribe only the spoken dialogue. Do not output music, laughter, sound effects, or descriptions."
    }

    nonisolated private static func shouldRetryWithAccuracyModel(
        _ original: String,
        pcm16ByteCount: Int,
        sampleRate: Int,
        modelPath: String,
        sourceLanguageCode: String
    ) -> Bool {
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        guard modelName.contains("tiny") || modelName.contains("base") else {
            return false
        }

        let durationSeconds = Double(pcm16ByteCount) / Double(sampleRate * MemoryLayout<Int16>.size)
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }

        if shouldSkip(trimmed) {
            return true
        }

        let expectsJapanese = sourceLanguageCode == "ja" || sourceLanguageCode == "auto"
        if expectsJapanese {
            let japaneseScalars = trimmed.unicodeScalars.filter {
                (0x3040...0x30FF).contains(Int($0.value)) || (0x4E00...0x9FFF).contains(Int($0.value))
            }
            if durationSeconds >= 1.2, japaneseScalars.count < 2 {
                return true
            }
        }

        let words = trimmed
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
        if words.count >= 6 {
            let uniqueRatio = Double(Set(words).count) / Double(words.count)
            if uniqueRatio < 0.45 {
                return true
            }
        }

        return false
    }

    nonisolated private static func accuracyModelPath(excluding currentModelPath: String) -> String? {
        let directory = "\(NSHomeDirectory())/.whisper-models"
        let candidates = [
            "\(directory)/ggml-small.bin",
            "\(directory)/ggml-medium.bin"
        ]

        return candidates.first {
            $0 != currentModelPath && FileManager.default.fileExists(atPath: $0)
        }
    }

    nonisolated private static func clean(_ output: String) -> String {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func voiceFeature(_ data: Data, rms: Double) -> VoiceFeature {
        var previousSample: Int16?
        var zeroCrossings = 0
        var sampleCount = 0
        var peak = 0

        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Int(sample)
                let magnitude = abs(value)
                if magnitude > peak {
                    peak = magnitude
                }
                if let previousSample {
                    if (previousSample < 0 && sample >= 0) || (previousSample >= 0 && sample < 0) {
                        zeroCrossings += 1
                    }
                }
                previousSample = sample
                sampleCount += 1
            }
        }

        let safeRMS = max(rms, 0.000_001)
        let peakNormalized = Double(peak) / 32768.0
        return VoiceFeature(
            logRMS: log10(safeRMS),
            zeroCrossingRate: sampleCount > 1 ? Double(zeroCrossings) / Double(sampleCount - 1) : 0,
            peakToRMS: peakNormalized / safeRMS
        )
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
    case missingOpenAIAPIKey
    case openAIRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let diagnostics):
            return diagnostics.isEmpty ? "whisper-cli 執行失敗。" : diagnostics
        case .missingOpenAIAPIKey:
            return "請在 Settings 輸入 OPENAI_API_KEY。"
        case .openAIRequestFailed(let message):
            return message
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
