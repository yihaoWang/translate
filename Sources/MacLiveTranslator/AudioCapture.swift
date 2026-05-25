import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioCapture {
    private let systemOutputCapture = SystemOutputAudioCapture()

    var onPCM16Chunk: ((Data) -> Void)?

    func start() throws {
        stop()
        systemOutputCapture.onPCM16Chunk = onPCM16Chunk
        try systemOutputCapture.start()
    }

    func stop() {
        systemOutputCapture.stop()
    }
}

private final class SystemOutputAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputQueue = DispatchQueue(label: "system-output-audio-capture")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    var onPCM16Chunk: ((Data) -> Void)?

    func start() throws {
        stop()

        let content = try waitForShareableContent()
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let currentApp = content.applications.first { app in
            app.processID == ProcessInfo.processInfo.processIdentifier
        }
        let excludedApps = currentApp.map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try waitForStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        converter = nil
        stream.stopCapture { _ in }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let inputBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        convertAndEmit(inputBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop()
    }

    private func waitForShareableContent() throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SCShareableContent, Error>?

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { content, error in
            if let content {
                result = .success(content)
            } else {
                result = .failure(Self.mapCaptureError(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try result?.get() ?? { throw AudioCaptureError.systemAudioUnavailable }()
    }

    private func waitForStart(_ stream: SCStream) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        stream.startCapture { error in
            startError = error
            semaphore.signal()
        }

        semaphore.wait()
        if let startError {
            throw Self.mapCaptureError(startError)
        }
    }

    private static func mapCaptureError(_ error: Error?) -> Error {
        guard let error else { return AudioCaptureError.systemAudioUnavailable }
        let message = error.localizedDescription.lowercased()
        if message.contains("tcc") || message.contains("denied") || message.contains("拒絕") {
            return AudioCaptureError.screenRecordingPermissionDenied
        }
        return error
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )

        guard status == noErr else {
            return nil
        }

        return buffer
    }

    private func convertAndEmit(_ inputBuffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != inputBuffer.format {
            converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = max(1, AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var conversionError: NSError?
        var didProvideBuffer = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideBuffer = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            return
        }

        if let pcm = Self.floatBufferToPCM16(outputBuffer) {
            onPCM16Chunk?(pcm)
        }
    }

    private static func floatBufferToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }

        var data = Data(capacity: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        for index in 0..<Int(buffer.frameLength) {
            let clipped = max(-1.0, min(1.0, samples[index]))
            let scaled = clipped < 0 ? clipped * 32768.0 : clipped * 32767.0
            var sample = Int16(scaled).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }
}

enum AudioCaptureError: LocalizedError {
    case noDisplay
    case screenRecordingPermissionDenied
    case systemAudioUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "找不到可擷取的螢幕。"
        case .screenRecordingPermissionDenied:
            return "無法擷取系統輸出音訊：macOS 尚未允許螢幕錄製權限。請到「系統設定 > 隱私權與安全性 > 螢幕錄製」允許 MacLiveTranslator，然後重新啟動 app。"
        case .systemAudioUnavailable:
            return "無法擷取系統輸出音訊。請到「系統設定 > 隱私權與安全性 > 螢幕錄製」允許 MacLiveTranslator，然後重新啟動 app。"
        case .converterUnavailable:
            return "無法建立音訊格式轉換器。"
        }
    }
}
