import AVFoundation
import AppKit
import Security
import SwiftUI
import Translation
import _Translation_SwiftUI

enum CaptionSpeedMode: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case accurate = "Accurate"

    var id: String { rawValue }

    var settings: SpeechDispatchSettings {
        switch self {
        case .fast:
            return SpeechDispatchSettings(
                speechThreshold: 0.006,
                silenceMs: 320,
                minUtteranceMs: 350,
                maxUtteranceMs: 2_500,
                speakerChangeEnabled: true,
                speakerChangeSensitivity: 0.52,
                minSpeakerChangeIntervalMs: 850
            )
        case .balanced:
            return SpeechDispatchSettings(
                speechThreshold: 0.006,
                silenceMs: 720,
                minUtteranceMs: 900,
                maxUtteranceMs: 6_500,
                speakerChangeEnabled: true,
                speakerChangeSensitivity: 0.64,
                minSpeakerChangeIntervalMs: 1_400
            )
        case .accurate:
            return SpeechDispatchSettings(
                speechThreshold: 0.008,
                silenceMs: 1_150,
                minUtteranceMs: 1_000,
                maxUtteranceMs: 10_000,
                speakerChangeEnabled: true,
                speakerChangeSensitivity: 0.68,
                minSpeakerChangeIntervalMs: 1_500
            )
        }
    }

    var recommendedModelName: String {
        switch self {
        case .fast:
            return "ggml-base.bin"
        case .balanced:
            return "ggml-base.bin"
        case .accurate:
            return "ggml-small.bin"
        }
    }
}

enum AppleTranslationInstallState: Equatable {
    case unchecked
    case checking
    case installed
    case available
    case preparing
    case unsupported
    case failed(String)

    var statusText: String {
        switch self {
        case .unchecked:
            return "尚未檢查"
        case .checking:
            return "正在檢查..."
        case .installed:
            return "已安裝"
        case .available:
            return "尚未安裝"
        case .preparing:
            return "正在開啟下載/準備流程..."
        case .unsupported:
            return "不支援"
        case .failed(let message):
            return message.isEmpty ? "準備失敗" : message
        }
    }

    var canOpenInstaller: Bool {
        switch self {
        case .available, .failed, .unchecked:
            return true
        case .checking, .installed, .preparing, .unsupported:
            return false
        }
    }
}

@main
struct MacLiveTranslatorApp: App {
    @NSApplicationDelegateAdaptor(MacLiveTranslatorAppDelegate.self) private var appDelegate
    @StateObject private var controller = SharedTranslatorState.controller

    var body: some Scene {
        Settings {
            SettingsPanelView(controller: controller)
                .frame(width: 900, height: 620)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    SettingsWindowManager.shared.show(controller: controller)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
private enum SharedTranslatorState {
    static let controller = TranslatorController()
}

final class MacLiveTranslatorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            CaptionOverlayPanelManager.shared.show(controller: SharedTranslatorState.controller)
            await SharedTranslatorState.controller.checkAppleTranslationAvailability()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            SettingsWindowManager.shared.show(controller: SharedTranslatorState.controller)
        }
        return true
    }
}

@MainActor
final class TranslatorController: ObservableObject {
    @Published var modelPath = TranslatorController.defaultModelPath() {
        didSet { AppSettingsStore.set(modelPath, for: .modelPath) }
    }
    @Published var recognitionEngine: SpeechRecognitionEngine = AppSettingsStore.recognitionEngine() {
        didSet { AppSettingsStore.set(recognitionEngine.rawValue, for: .recognitionEngine) }
    }
    @Published var openAIAPIKey = TranslatorController.defaultOpenAIAPIKey() {
        didSet {
            TranslatorController.saveOpenAIAPIKey(openAIAPIKey)
        }
    }
    @Published var openAITranscriptionModel = AppSettingsStore.openAITranscriptionModel() {
        didSet { AppSettingsStore.set(openAITranscriptionModel, for: .openAITranscriptionModel) }
    }
    @Published var sourceLanguageCode = AppSettingsStore.sourceLanguageCode() {
        didSet { AppSettingsStore.set(sourceLanguageCode, for: .sourceLanguageCode) }
    }
    @Published var speedMode: CaptionSpeedMode = AppSettingsStore.speedMode() {
        didSet { AppSettingsStore.set(speedMode.rawValue, for: .speedMode) }
    }
    @Published var speechThreshold = AppSettingsStore.double(for: .speechThreshold, default: AppSettingsStore.speedMode().settings.speechThreshold) {
        didSet { AppSettingsStore.set(speechThreshold, for: .speechThreshold) }
    }
    @Published var silenceMs = AppSettingsStore.double(for: .silenceMs, default: AppSettingsStore.speedMode().settings.silenceMs) {
        didSet { AppSettingsStore.set(silenceMs, for: .silenceMs) }
    }
    @Published var minUtteranceMs = AppSettingsStore.double(for: .minUtteranceMs, default: AppSettingsStore.speedMode().settings.minUtteranceMs) {
        didSet { AppSettingsStore.set(minUtteranceMs, for: .minUtteranceMs) }
    }
    @Published var maxUtteranceMs = AppSettingsStore.double(for: .maxUtteranceMs, default: AppSettingsStore.speedMode().settings.maxUtteranceMs) {
        didSet { AppSettingsStore.set(maxUtteranceMs, for: .maxUtteranceMs) }
    }
    @Published var speakerChangeEnabled = AppSettingsStore.bool(for: .speakerChangeEnabled, default: AppSettingsStore.speedMode().settings.speakerChangeEnabled) {
        didSet { AppSettingsStore.set(speakerChangeEnabled, for: .speakerChangeEnabled) }
    }
    @Published var speakerChangeSensitivity = AppSettingsStore.double(for: .speakerChangeSensitivity, default: AppSettingsStore.speedMode().settings.speakerChangeSensitivity) {
        didSet { AppSettingsStore.set(speakerChangeSensitivity, for: .speakerChangeSensitivity) }
    }
    @Published var minSpeakerChangeIntervalMs = AppSettingsStore.double(for: .minSpeakerChangeIntervalMs, default: AppSettingsStore.speedMode().settings.minSpeakerChangeIntervalMs) {
        didSet { AppSettingsStore.set(minSpeakerChangeIntervalMs, for: .minSpeakerChangeIntervalMs) }
    }
    @Published var translationEnabled = AppSettingsStore.bool(for: .translationEnabled, default: true) {
        didSet { AppSettingsStore.set(translationEnabled, for: .translationEnabled) }
    }
    @Published var isListening = false
    @Published var localStatus = "準備就緒"
    @Published var appleTranslationStatus = "尚未檢查 Apple 直翻"
    @Published var appleTranslationInstallState: AppleTranslationInstallState = .unchecked
    @Published var shouldPrepareAppleTranslation = false
    @Published var latestRecordingPath = ""

    let translator = LocalWhisperTranslator()
    private let capture = AudioCapture()
    private let recorder = AudioSessionRecorder()

    init() {
        Task {
            await checkAppleTranslationAvailability()
            await ArgosLocalTextTranslator.warmUp(sourceLanguageCode: "ja")
        }
    }

    func start() {
        Task {
            await ArgosLocalTextTranslator.warmUp(sourceLanguageCode: sourceLanguageCode)
        }

        translator.start(
            modelPath: modelPath,
            sourceLanguageCode: sourceLanguageCode,
            recognitionEngine: recognitionEngine,
            openAIAPIKey: openAIAPIKey,
            openAITranscriptionModel: openAITranscriptionModel,
            translationEnabled: translationEnabled,
            settings: currentDispatchSettings
        )
        guard translator.isReady else {
            localStatus = "本地模型不可用"
            return
        }

        do {
            let recordingURL = try recorder.start(sampleRate: 16_000, channels: 1)
            latestRecordingPath = recordingURL.path
        } catch {
            translator.stop()
            translator.errorMessage = error.localizedDescription
            localStatus = "無法建立錄音檔"
            isListening = false
            return
        }

        capture.onPCM16Chunk = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.recorder.append(data)
                } catch {
                    self.translator.errorMessage = error.localizedDescription
                    self.localStatus = "錄音寫入失敗"
                }
                self.translator.appendAudio(data)
            }
        }

        do {
            try capture.start()
            isListening = true
            localStatus = "正在擷取系統輸出音訊"
        } catch {
            try? recorder.stop()
            translator.stop()
            translator.errorMessage = error.localizedDescription
            localStatus = "無法開始錄音"
            isListening = false
        }
    }

    func stop() {
        capture.stop()
        do {
            try recorder.stop()
        } catch {
            translator.errorMessage = error.localizedDescription
            localStatus = "錄音檔收尾失敗"
        }
        translator.stop()
        isListening = false
        if localStatus != "錄音檔收尾失敗" {
            localStatus = "已停止"
        }
    }

    func clearCaptions() {
        translator.segments = []
    }

    func prepareAppleTranslationLanguagePack() {
        guard let source = appleTranslationPackageSource else {
            appleTranslationStatus = "Apple 語言包目前支援日文或英文 → 繁中"
            appleTranslationInstallState = .failed("請先把語音設為日文或英文")
            return
        }
        appleTranslationStatus = "正在準備 Apple \(languageDisplayName(source)) → 繁中..."
        appleTranslationInstallState = .preparing
        shouldPrepareAppleTranslation = true
    }

    func checkAppleTranslationAvailability() async {
        guard #available(macOS 15.0, *) else {
            appleTranslationStatus = "此 macOS 不支援 Apple Translation"
            appleTranslationInstallState = .unsupported
            return
        }

        appleTranslationInstallState = .checking
        let availability = LanguageAvailability()
        guard let sourceCode = appleTranslationPackageSource else {
            appleTranslationStatus = "Apple 語言包目前支援日文或英文 → 繁中"
            appleTranslationInstallState = .unsupported
            return
        }

        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: "zh-Hant")
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            appleTranslationStatus = "Apple \(languageDisplayName(sourceCode)) → 繁中已安裝"
            appleTranslationInstallState = .installed
        case .supported:
            appleTranslationStatus = "可安裝 Apple \(languageDisplayName(sourceCode)) → 繁中"
            appleTranslationInstallState = .available
        case .unsupported:
            appleTranslationStatus = "Apple 不支援此語言組合"
            appleTranslationInstallState = .unsupported
        @unknown default:
            appleTranslationStatus = "Apple 翻譯狀態未知"
            appleTranslationInstallState = .failed("Apple 翻譯狀態未知")
        }
    }

    func finishAppleTranslationPreparation(success: Bool, error: Error? = nil) async {
        shouldPrepareAppleTranslation = false
        if success {
            let source = appleTranslationPackageSource ?? "ja"
            appleTranslationStatus = "Apple \(languageDisplayName(source)) → 繁中已安裝"
            appleTranslationInstallState = .installed
            await ArgosLocalTextTranslator.warmUp(sourceLanguageCode: source)
        } else {
            appleTranslationStatus = error?.localizedDescription ?? "Apple 語言包準備失敗"
            appleTranslationInstallState = .failed(appleTranslationStatus)
        }
    }

    var currentDispatchSettings: SpeechDispatchSettings {
        SpeechDispatchSettings(
            speechThreshold: speechThreshold,
            silenceMs: silenceMs,
            minUtteranceMs: minUtteranceMs,
            maxUtteranceMs: maxUtteranceMs,
            speakerChangeEnabled: speakerChangeEnabled,
            speakerChangeSensitivity: speakerChangeSensitivity,
            minSpeakerChangeIntervalMs: minSpeakerChangeIntervalMs
        )
    }

    var appleTranslationPackageSource: String? {
        if sourceLanguageCode == "en" {
            return "en"
        }
        if sourceLanguageCode == "ja" || sourceLanguageCode == "auto" {
            return "ja"
        }
        return nil
    }

    func languageDisplayName(_ code: String) -> String {
        switch code {
        case "en":
            return "英文"
        case "ja":
            return "日文"
        default:
            return code
        }
    }

    var availableModelPaths: [String] {
        let directory = "\(NSHomeDirectory())/.whisper-models"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return [modelPath]
        }

        let preferredOrder = [
            "ggml-tiny.bin",
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-medium.bin"
        ]

        let paths = names
            .filter { $0.hasPrefix("ggml") && $0.hasSuffix(".bin") }
            .sorted { lhs, rhs in
                let lhsIndex = preferredOrder.firstIndex(of: lhs) ?? Int.max
                let rhsIndex = preferredOrder.firstIndex(of: rhs) ?? Int.max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs < rhs
            }
            .map { "\(directory)/\($0)" }

        return paths.isEmpty ? [modelPath] : paths
    }

    func applyMode(_ mode: CaptionSpeedMode) {
        speedMode = mode
        let settings = mode.settings
        speechThreshold = settings.speechThreshold
        silenceMs = settings.silenceMs
        minUtteranceMs = settings.minUtteranceMs
        maxUtteranceMs = settings.maxUtteranceMs
        speakerChangeEnabled = settings.speakerChangeEnabled
        speakerChangeSensitivity = settings.speakerChangeSensitivity
        minSpeakerChangeIntervalMs = settings.minSpeakerChangeIntervalMs

        let recommended = "\(NSHomeDirectory())/.whisper-models/\(mode.recommendedModelName)"
        if FileManager.default.fileExists(atPath: recommended) {
            modelPath = recommended
        }
    }

    private static func defaultModelPath() -> String {
        if let saved = AppSettingsStore.string(for: .modelPath), FileManager.default.fileExists(atPath: saved) {
            return saved
        }

        let directory = "\(NSHomeDirectory())/.whisper-models"
        let preferred = [
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-tiny.bin"
        ]

        for name in preferred {
            let path = "\(directory)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return "\(directory)/ggml-small.bin"
    }

    private static func defaultOpenAIAPIKey() -> String {
        if let keychainValue = KeychainSecretStore.read(account: "openai-api-key"), !keychainValue.isEmpty {
            return keychainValue
        }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    private static func saveOpenAIAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainSecretStore.delete(account: "openai-api-key")
        } else {
            KeychainSecretStore.save(trimmed, account: "openai-api-key")
        }
    }
}

private enum AppSettingsStore {
    enum Key: String {
        case modelPath = "modelPath"
        case recognitionEngine = "recognitionEngine"
        case openAITranscriptionModel = "openAITranscriptionModel"
        case sourceLanguageCode = "sourceLanguageCode"
        case speedMode = "speedMode"
        case speechThreshold = "speechThreshold"
        case silenceMs = "silenceMs"
        case minUtteranceMs = "minUtteranceMs"
        case maxUtteranceMs = "maxUtteranceMs"
        case speakerChangeEnabled = "speakerChangeEnabled"
        case speakerChangeSensitivity = "speakerChangeSensitivity"
        case minSpeakerChangeIntervalMs = "minSpeakerChangeIntervalMs"
        case translationEnabled = "translationEnabled"
    }

    private static let prefix = "MacLiveTranslator."
    private static let defaults = UserDefaults.standard

    static func recognitionEngine() -> SpeechRecognitionEngine {
        guard let raw = string(for: .recognitionEngine), let value = SpeechRecognitionEngine(rawValue: raw) else {
            return .localWhisper
        }
        return value
    }

    static func openAITranscriptionModel() -> String {
        string(for: .openAITranscriptionModel) ?? "gpt-4o-mini-transcribe"
    }

    static func sourceLanguageCode() -> String {
        string(for: .sourceLanguageCode) ?? "ja"
    }

    static func speedMode() -> CaptionSpeedMode {
        guard let raw = string(for: .speedMode), let value = CaptionSpeedMode(rawValue: raw) else {
            return .balanced
        }
        return value
    }

    static func string(for key: Key) -> String? {
        defaults.string(forKey: storageKey(key))
    }

    static func double(for key: Key, default defaultValue: Double) -> Double {
        let storageKey = storageKey(key)
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return defaults.double(forKey: storageKey)
    }

    static func bool(for key: Key, default defaultValue: Bool) -> Bool {
        let storageKey = storageKey(key)
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: storageKey)
    }

    static func set(_ value: String, for key: Key) {
        defaults.set(value, forKey: storageKey(key))
    }

    static func set(_ value: Double, for key: Key) {
        defaults.set(value, forKey: storageKey(key))
    }

    static func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: storageKey(key))
    }

    private static func storageKey(_ key: Key) -> String {
        "\(prefix)\(key.rawValue)"
    }
}

private enum KeychainSecretStore {
    private static let service = "local.mac-live-translator"

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard
            status == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let update = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}

struct CaptionOverlayView: View {
    @ObservedObject var controller: TranslatorController
    @ObservedObject private var translator: LocalWhisperTranslator

    init(controller: TranslatorController) {
        self.controller = controller
        self.translator = controller.translator
    }

    var body: some View {
        captionPanel
            .background(Color.clear)
            .background(AppleTranslationPreparationHost(controller: controller).frame(width: 0, height: 0))
            .alert("發生錯誤", isPresented: Binding(
                get: { translator.errorMessage != nil },
                set: { if !$0 { translator.errorMessage = nil } }
            )) {
                Button("好") { translator.errorMessage = nil }
            } message: {
                Text(translator.errorMessage ?? "")
            }
            .onDisappear {
                controller.stop()
            }
            .task {
                await controller.checkAppleTranslationAvailability()
            }
    }

    private var captionPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                if translator.visibleSegments.isEmpty {
                    captionPair(
                        original: "Original detected speech",
                        translation: controller.translationEnabled ? "繁體中文翻譯" : "",
                        isLatest: true
                    )
                } else {
                    ForEach(translator.visibleSegments) { segment in
                        captionPair(
                            original: segment.original,
                            translation: controller.translationEnabled ? segment.translation : "",
                            isLatest: segment.id == translator.visibleSegments.last?.id
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 62)

            HStack(spacing: 6) {
                statusDot(controller.isListening ? .green : .gray, size: 7)
                Button {
                    controller.isListening ? controller.stop() : controller.start()
                } label: {
                    Image(systemName: controller.isListening ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help(controller.isListening ? "Stop" : "Start")

                Button {
                    SettingsWindowManager.shared.show(controller: controller)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.64))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 8)
    }

    private func captionPair(original: String, translation: String, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(original)
                .font(.system(size: isLatest ? 15 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isLatest ? 0.94 : 0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .textSelection(.enabled)

            Text(translation)
                .font(.system(size: isLatest ? 15 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(isLatest ? 0.96 : 0.64))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .textSelection(.enabled)
                .opacity(translation.isEmpty ? 0 : 1)
                .frame(height: translation.isEmpty ? 0 : nil)
        }
    }

    private func statusDot(_ color: Color, size: CGFloat = 10) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
    }
}

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?

    func show(controller: TranslatorController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsPanelView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Live Translator Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct SettingsPanelView: View {
    @ObservedObject var controller: TranslatorController
    @ObservedObject private var translator: LocalWhisperTranslator

    init(controller: TranslatorController) {
        self.controller = controller
        self.translator = controller.translator
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader
                recognitionSection
                captionSection
                segmentationSection
                metricsFooter
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(AppleTranslationPreparationHost(controller: controller).frame(width: 0, height: 0))
        .task {
            await controller.checkAppleTranslationAvailability()
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Live Translator")
                    .font(.system(size: 15, weight: .bold))
                Text(controller.isListening ? "正在擷取系統輸出音訊" : "設定辨識、字幕與翻譯")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                controller.isListening ? controller.stop() : controller.start()
            } label: {
                Label(controller.isListening ? "停止" : "開始", systemImage: controller.isListening ? "stop.fill" : "play.fill")
                    .frame(width: 86)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                controller.clearCaptions()
            } label: {
                Label("清除", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var recognitionSection: some View {
        settingsSection(title: "語音辨識", systemImage: "waveform") {
            HStack(alignment: .top, spacing: 16) {
                settingField("ASR 引擎") {
                    Picker("ASR 引擎", selection: $controller.recognitionEngine) {
                        ForEach(SpeechRecognitionEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }

                settingField("語音語言") {
                    speechLanguagePicker
                        .frame(width: 150)
                }

                Spacer()
            }

            Divider()
            recordingStatusRow
            Divider()

            if controller.recognitionEngine == .localWhisper {
                localRecognitionControls
            } else {
                cloudRecognitionControls
            }
        }
    }

    private var recordingStatusRow: some View {
        HStack(spacing: 10) {
            Label("錄音保存", systemImage: "record.circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(controller.latestRecordingPath.isEmpty ? Color.secondary : Color.red)
                .frame(width: 92, alignment: .leading)

            Text(controller.latestRecordingPath.isEmpty ? "尚未建立錄音檔" : controller.latestRecordingPath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localRecognitionControls: some View {
        HStack(alignment: .top, spacing: 16) {
            settingField("本地 Whisper 模型") {
                Picker("本地 Whisper 模型", selection: $controller.modelPath) {
                    ForEach(controller.availableModelPaths, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 210)
            }

            settingField("速度 / 準確") {
                Picker("速度 / 準確", selection: $controller.speedMode) {
                    ForEach(CaptionSpeedMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: controller.speedMode) { mode in
                    controller.applyMode(mode)
                }
            }

            Text("Fast 用較短分段；Balanced 是預設；Accurate 會保留較長語句。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
        }
    }

    private var cloudRecognitionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                settingField("OpenAI Transcribe 模型") {
                    Picker("OpenAI Transcribe 模型", selection: $controller.openAITranscriptionModel) {
                        Text("gpt-4o-transcribe").tag("gpt-4o-transcribe")
                        Text("gpt-4o-mini-transcribe").tag("gpt-4o-mini-transcribe")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 220)
                }

                settingField("API Key") {
                    SecureField("OPENAI_API_KEY", text: $controller.openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 390)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("狀態")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(controller.openAIAPIKey.isEmpty ? "需要 API key" : "已設定")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(controller.openAIAPIKey.isEmpty ? .red : .green)
                        .padding(.top, 4)
                }
            }

            Text("Cloud 模式只替換語音辨識；下方翻譯開關仍可獨立決定是否翻成繁中。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var captionSection: some View {
        settingsSection(title: "字幕與翻譯", systemImage: "character.bubble") {
            HStack(alignment: .top, spacing: 16) {
                settingField("翻譯") {
                    Picker("翻譯", selection: $controller.translationEnabled) {
                        Text("雙語字幕").tag(true)
                        Text("只顯示原文").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("目標語言")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("繁體中文")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(height: 22, alignment: .center)
                }

                Spacer()
            }

            if controller.translationEnabled {
                Divider()
                appleTranslationInstallerRow
            }
        }
    }

    private var segmentationSection: some View {
        settingsSection(title: "斷句與即時性", systemImage: "timeline.selection") {
            HStack(alignment: .center, spacing: 18) {
                vadSlider(
                    title: "敏感度",
                    value: $controller.speechThreshold,
                    range: 0.006...0.030,
                    display: String(format: "%.3f", controller.speechThreshold)
                )

                vadSlider(
                    title: "停頓判定",
                    value: $controller.silenceMs,
                    range: 400...1_500,
                    display: "\(Int(controller.silenceMs))ms"
                )
            }

            HStack(alignment: .center, spacing: 18) {
                vadSlider(
                    title: "最短語句",
                    value: $controller.minUtteranceMs,
                    range: 400...1_500,
                    display: "\(Int(controller.minUtteranceMs))ms"
                )

                vadSlider(
                    title: "最長語句",
                    value: $controller.maxUtteranceMs,
                    range: 4_000...12_000,
                    display: String(format: "%.1fs", controller.maxUtteranceMs / 1_000)
                )
            }

            HStack(alignment: .center, spacing: 18) {
                Toggle("換人斷點", isOn: $controller.speakerChangeEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

                vadSlider(
                    title: "換人敏感度",
                    value: $controller.speakerChangeSensitivity,
                    range: 0.35...0.80,
                    display: String(format: "%.2f", controller.speakerChangeSensitivity)
                )

                vadSlider(
                    title: "最短換人間隔",
                    value: $controller.minSpeakerChangeIntervalMs,
                    range: 700...2_000,
                    display: String(format: "%.1fs", controller.minSpeakerChangeIntervalMs / 1_000)
                )
            }
        }
    }

    private var metricsFooter: some View {
        HStack(spacing: 10) {
            Text("ASR \(translator.lastWhisperMs.map { "\($0)ms" } ?? "-")")
            Text("Translate \(controller.translationEnabled ? (translator.lastTranslationMs.map { "\($0)ms" } ?? "-") : "off")")
            Text("Total \(translator.lastTotalMs.map { "\($0)ms" } ?? "-")")
            Spacer()
            Text(controller.translationEnabled ? "Apple \(controller.appleTranslationInstallState.statusText)" : "翻譯已關閉")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var speechLanguagePicker: some View {
        Picker("語音語言", selection: $controller.sourceLanguageCode) {
            Text("自動偵測").tag("auto")
            Text("日文").tag("ja")
            Text("英文").tag("en")
            Text("韓文").tag("ko")
            Text("中文").tag("zh")
            Text("西文").tag("es")
            Text("法文").tag("fr")
            Text("德文").tag("de")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: controller.sourceLanguageCode) { languageCode in
            Task {
                await controller.checkAppleTranslationAvailability()
                await ArgosLocalTextTranslator.warmUp(sourceLanguageCode: languageCode)
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func settingField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var appleTranslationInstallerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: appleTranslationIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(appleTranslationTint)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(appleTranslationTint.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple 本地直翻：\(controller.languageDisplayName(controller.appleTranslationPackageSource ?? controller.sourceLanguageCode)) → 繁體中文")
                    .font(.system(size: 12, weight: .bold))
                Text(controller.appleTranslationStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task {
                    await controller.checkAppleTranslationAvailability()
                    if controller.appleTranslationInstallState.canOpenInstaller {
                        controller.prepareAppleTranslationLanguagePack()
                    }
                }
            } label: {
                Label(appleTranslationButtonTitle, systemImage: appleTranslationButtonIcon)
                    .frame(width: 120)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!controller.appleTranslationInstallState.canOpenInstaller)
            .help("未安裝時會開啟 macOS 的 Apple Translation 語言下載/準備流程")
        }
    }

    private var appleTranslationIconName: String {
        switch controller.appleTranslationInstallState {
        case .installed:
            return "checkmark.circle.fill"
        case .available:
            return "arrow.down.circle.fill"
        case .checking, .preparing:
            return "clock.fill"
        case .unsupported, .failed:
            return "exclamationmark.triangle.fill"
        case .unchecked:
            return "questionmark.circle.fill"
        }
    }

    private var appleTranslationTint: Color {
        switch controller.appleTranslationInstallState {
        case .installed:
            return .green
        case .available, .unchecked:
            return .blue
        case .checking, .preparing:
            return .orange
        case .unsupported, .failed:
            return .red
        }
    }

    private var appleTranslationButtonTitle: String {
        switch controller.appleTranslationInstallState {
        case .installed:
            return "已安裝"
        case .checking:
            return "檢查中"
        case .preparing:
            return "準備中"
        default:
            return "下載語言包"
        }
    }

    private var appleTranslationButtonIcon: String {
        controller.appleTranslationInstallState == .installed ? "checkmark" : "arrow.down.circle"
    }

    private func vadSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .frame(width: 260)
        }
    }
}

struct AppleTranslationPreparationHost: View {
    @ObservedObject var controller: TranslatorController

    var body: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationPreparationTaskHost(controller: controller)
        } else {
            Color.clear
                .onChange(of: controller.shouldPrepareAppleTranslation) { shouldPrepare in
                    guard shouldPrepare else { return }
                    Task {
                        await controller.finishAppleTranslationPreparation(success: false)
                    }
                }
        }
    }
}

@MainActor
final class CaptionOverlayPanelManager {
    static let shared = CaptionOverlayPanelManager()

    private var panel: CaptionOverlayPanel?
    private var visibilityTimer: Timer?
    private var lastScreenFrame: NSRect?

    func show(controller: TranslatorController) {
        if let panel {
            panel.orderFrontRegardless()
            startKeepingOverlayVisible()
            return
        }

        let panel = CaptionOverlayPanel(
            contentRect: defaultFrame(on: NSScreen.main),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: CaptionOverlayView(controller: controller)
                .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity, minHeight: 88, idealHeight: 102, maxHeight: .infinity)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 520, height: 88)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.panel = panel
        panel.orderFrontRegardless()
        startKeepingOverlayVisible()
    }

    func verifyVisibleForTesting() -> Bool {
        guard let panel else { return false }
        panel.orderFrontRegardless()
        return panel.isVisible && panel.level.rawValue >= Int(CGWindowLevelForKey(.screenSaverWindow))
    }

    private func startKeepingOverlayVisible() {
        guard visibilityTimer == nil else { return }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.orderFrontRegardless()
            }
        }
        if let visibilityTimer {
            RunLoop.main.add(visibilityTimer, forMode: .common)
        }
    }

    private func movePanelToActiveScreen(force: Bool) {
        guard let panel else { return }
        let screen = activeApplicationScreen() ?? panel.screen ?? NSScreen.main
        guard let screen else { return }

        let currentSize = panel.frame.size.width >= panel.minSize.width && panel.frame.size.height >= panel.minSize.height
            ? panel.frame.size
            : NSSize(width: 720, height: 102)
        let visibleFrame = screen.visibleFrame
        let size = NSSize(
            width: min(max(currentSize.width, 520), visibleFrame.width - 48),
            height: min(max(currentSize.height, 88), visibleFrame.height - 48)
        )
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 110,
            width: size.width,
            height: size.height
        )
        if force || abs(panel.frame.origin.x - frame.origin.x) > 2 || abs(panel.frame.origin.y - frame.origin.y) > 2 || abs(panel.frame.width - frame.width) > 2 || abs(panel.frame.height - frame.height) > 2 {
            panel.setFrame(frame, display: true)
        }
        lastScreenFrame = screen.frame
    }

    private func defaultFrame(on screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(width: 720, height: 102)
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 110,
            width: size.width,
            height: size.height
        )
    }

    private func activeApplicationScreen() -> NSScreen? {
        guard
            let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        let activeWindows = windowList.compactMap { info -> CGRect? in
            guard
                info[kCGWindowOwnerPID as String] as? pid_t == activePID,
                info[kCGWindowLayer as String] as? Int == 0,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let x = bounds["X"] as? CGFloat,
                let y = bounds["Y"] as? CGFloat,
                let width = bounds["Width"] as? CGFloat,
                let height = bounds["Height"] as? CGFloat,
                width > 120,
                height > 120
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        guard let activeWindow = activeWindows.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }

        let center = CGPoint(x: activeWindow.midX, y: activeWindow.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(center)
        }
    }
}

private final class CaptionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct BootstrapWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrame(NSRect(x: -20_000, y: -20_000, width: 1, height: 1), display: false)
            window.alphaValue = 0.01
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            window.ignoresMouseEvents = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@available(macOS 15.0, *)
private struct AppleTranslationPreparationTaskHost: View {
    @ObservedObject var controller: TranslatorController
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onChange(of: controller.shouldPrepareAppleTranslation) { shouldPrepare in
                guard shouldPrepare else { return }
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "ja"),
                    target: Locale.Language(identifier: "zh-Hant")
                )
            }
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    _ = try await session.translate("今日はいい天気ですね。")
                    await controller.finishAppleTranslationPreparation(success: true)
                } catch {
                    await controller.finishAppleTranslationPreparation(success: false, error: error)
                }
            }
    }
}

/*
struct ContentView: View {
    @StateObject private var translator = LocalWhisperTranslator()
    @State private var capture = AudioCapture()
    @State private var modelPath = "\(NSHomeDirectory())/.whisper-models/ggml-small.bin"
    @State private var sourceLanguageCode = "auto"
    @State private var isListening = false
    @State private var localStatus = "準備就緒"

    var body: some View {
        VStack(spacing: 12) {
            captionPanel
            toolbar
        }
        .padding(16)
        .background(Color.clear)
        .alert("發生錯誤", isPresented: Binding(
            get: { translator.errorMessage != nil },
            set: { if !$0 { translator.errorMessage = nil } }
        )) {
            Button("好") { translator.errorMessage = nil }
        } message: {
            Text(translator.errorMessage ?? "")
        }
        .onDisappear {
            stop()
        }
    }

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statusDot(isListening ? .green : .gray, size: 8)
                Text(isListening ? "LOCAL LIVE" : localStatus.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text(translator.status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(translator.latestOriginal.isEmpty ? "Original detected speech" : translator.latestOriginal)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .textSelection(.enabled)

                Divider()
                    .overlay(Color.white.opacity(0.14))

                Text(translator.latestTranslation.isEmpty ? "繁體中文翻譯" : translator.latestTranslation)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 14)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                statusDot(isListening ? .green : .gray, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Live Translator")
                        .font(.system(size: 12, weight: .bold))
                    Text(isListening ? "Capturing default input" : "Ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 142, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("MODEL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                TextField("Whisper model path", text: $modelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minWidth: 292)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SPEECH")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("語音", selection: $sourceLanguageCode) {
                        Text("自動").tag("auto")
                        Text("英文").tag("en")
                        Text("日文").tag("ja")
                        Text("韓文").tag("ko")
                        Text("中文").tag("zh")
                        Text("西文").tag("es")
                        Text("法文").tag("fr")
                        Text("德文").tag("de")
                    }
                    .labelsHidden()
                    .frame(width: 90)

                    Text("TO")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text("繁中")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }

            Spacer(minLength: 4)

            Button {
                isListening ? stop() : start()
            } label: {
                Label(isListening ? "Stop" : "Start", systemImage: isListening ? "stop.fill" : "play.fill")
                    .frame(width: 76)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                translator.segments = []
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Clear captions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
    }

    private func start() {
        translator.start(modelPath: modelPath, sourceLanguageCode: sourceLanguageCode)
        guard translator.isReady else {
            localStatus = "本地模型不可用"
            return
        }

        capture.onPCM16Chunk = { data in
            Task { @MainActor in
                translator.appendAudio(data)
            }
        }

        do {
            try capture.start()
            isListening = true
            localStatus = "正在聽預設輸入裝置"
        } catch {
            translator.stop()
            translator.errorMessage = error.localizedDescription
            localStatus = "無法開始錄音"
            isListening = false
        }
    }

    private func stop() {
        capture.stop()
        translator.stop()
        isListening = false
        localStatus = "已停止"
    }

    private func statusDot(_ color: Color, size: CGFloat = 10) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
    }
}
*/

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask = [.borderless, .resizable, .nonactivatingPanel]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.level = .statusBar
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            window.isMovableByWindowBackground = true
            window.hidesOnDeactivate = false
            window.hasShadow = false
            window.minSize = NSSize(width: 520, height: 88)
            Self.resize(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.resize(window)
                window.orderFrontRegardless()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                window.orderFrontRegardless()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func resize(_ window: NSWindow) {
        let size = NSSize(width: 720, height: 102)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 110
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}
