import AVFoundation
import AppKit
import SwiftUI

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
                maxUtteranceMs: 2_500
            )
        case .balanced:
            return SpeechDispatchSettings(
                speechThreshold: 0.006,
                silenceMs: 560,
                minUtteranceMs: 700,
                maxUtteranceMs: 5_500
            )
        case .accurate:
            return SpeechDispatchSettings(
                speechThreshold: 0.008,
                silenceMs: 1_150,
                minUtteranceMs: 1_000,
                maxUtteranceMs: 10_000
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

@main
struct MacLiveTranslatorApp: App {
    @StateObject private var controller = TranslatorController()

    var body: some Scene {
        WindowGroup {
            CaptionOverlayView(controller: controller)
                .frame(minWidth: 520, minHeight: 88)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class TranslatorController: ObservableObject {
    @Published var modelPath = TranslatorController.defaultModelPath()
    @Published var sourceLanguageCode = "ja"
    @Published var speedMode: CaptionSpeedMode = .balanced
    @Published var speechThreshold = CaptionSpeedMode.balanced.settings.speechThreshold
    @Published var silenceMs = CaptionSpeedMode.balanced.settings.silenceMs
    @Published var minUtteranceMs = CaptionSpeedMode.balanced.settings.minUtteranceMs
    @Published var maxUtteranceMs = CaptionSpeedMode.balanced.settings.maxUtteranceMs
    @Published var isListening = false
    @Published var localStatus = "準備就緒"

    let translator = LocalWhisperTranslator()
    private let capture = AudioCapture()

    init() {
        Task {
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
            settings: currentDispatchSettings
        )
        guard translator.isReady else {
            localStatus = "本地模型不可用"
            return
        }

        capture.onPCM16Chunk = { [weak self] data in
            Task { @MainActor in
                self?.translator.appendAudio(data)
            }
        }

        do {
            try capture.start()
            isListening = true
            localStatus = "正在擷取系統輸出音訊"
        } catch {
            translator.stop()
            translator.errorMessage = error.localizedDescription
            localStatus = "無法開始錄音"
            isListening = false
        }
    }

    func stop() {
        capture.stop()
        translator.stop()
        isListening = false
        localStatus = "已停止"
    }

    func clearCaptions() {
        translator.segments = []
    }

    var currentDispatchSettings: SpeechDispatchSettings {
        SpeechDispatchSettings(
            speechThreshold: speechThreshold,
            silenceMs: silenceMs,
            minUtteranceMs: minUtteranceMs,
            maxUtteranceMs: maxUtteranceMs
        )
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

        let recommended = "\(NSHomeDirectory())/.whisper-models/\(mode.recommendedModelName)"
        if FileManager.default.fileExists(atPath: recommended) {
            modelPath = recommended
        }
    }

    private static func defaultModelPath() -> String {
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
    }

    private var captionPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                if translator.visibleSegments.isEmpty {
                    captionPair(
                        original: "Original detected speech",
                        translation: "繁體中文翻譯",
                        isLatest: true
                    )
                } else {
                    ForEach(translator.visibleSegments) { segment in
                        captionPair(
                            original: segment.original,
                            translation: segment.translation,
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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 332),
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Live Translator")
                        .font(.system(size: 15, weight: .bold))
                    Text(controller.isListening ? "Capturing system output" : "Configure local caption translation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    controller.isListening ? controller.stop() : controller.start()
                } label: {
                    Label(controller.isListening ? "Stop" : "Start", systemImage: controller.isListening ? "stop.fill" : "play.fill")
                        .frame(width: 86)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    controller.clearCaptions()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MODE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: $controller.speedMode) {
                        ForEach(CaptionSpeedMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: controller.speedMode) { mode in
                        controller.applyMode(mode)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("MODEL")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: $controller.modelPath) {
                        ForEach(controller.availableModelPaths, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("SPEECH LANGUAGE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Picker("Speech", selection: $controller.sourceLanguageCode) {
                        Text("自動偵測").tag("auto")
                        Text("英文").tag("en")
                        Text("日文").tag("ja")
                        Text("韓文").tag("ko")
                        Text("中文").tag("zh")
                        Text("西文").tag("es")
                        Text("法文").tag("fr")
                        Text("德文").tag("de")
                    }
                    .labelsHidden()
                    .frame(width: 128)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("TRANSLATION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("→ 繁體中文")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
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

                HStack(alignment: .center, spacing: 16) {
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
            }

            HStack(spacing: 10) {
                Text("Whisper \(translator.lastWhisperMs.map { "\($0)ms" } ?? "-")")
                Text("Translate \(translator.lastTranslationMs.map { "\($0)ms" } ?? "-")")
                Text("Total \(translator.lastTotalMs.map { "\($0)ms" } ?? "-")")
                Spacer()
                Text("日文 → 英文 → 繁中，重複翻譯會快取")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
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
                .frame(width: 360)
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
