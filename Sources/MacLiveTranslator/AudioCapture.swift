import AVFoundation
import Foundation

final class AudioCapture {
    private let engine = AVAudioEngine()
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

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard converter != nil else {
            throw AudioCaptureError.converterUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
    }

    private func convertAndEmit(_ inputBuffer: AVAudioPCMBuffer) {
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
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "找不到可用的音訊輸入裝置。"
        case .converterUnavailable:
            return "無法建立音訊格式轉換器。"
        }
    }
}
