import Foundation

final class AudioSessionRecorder {
    private let outputDirectory: URL
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt32 = 0
    private var sampleRate: UInt32 = 16_000
    private var channels: UInt16 = 1

    private(set) var currentFileURL: URL?

    init(outputDirectory: URL = AudioSessionRecorder.defaultOutputDirectory) {
        self.outputDirectory = outputDirectory
    }

    func start(sampleRate: UInt32 = 16_000, channels: UInt16 = 1) throws -> URL {
        try stop()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        self.sampleRate = sampleRate
        self.channels = channels
        bytesWritten = 0

        let url = outputDirectory.appendingPathComponent(Self.timestampedFileName())
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.wavHeader(
            pcmByteCount: 0,
            sampleRate: sampleRate,
            channels: channels
        ))

        fileHandle = handle
        currentFileURL = url
        return url
    }

    func append(_ pcm16: Data) throws {
        guard let fileHandle else { return }
        try fileHandle.write(contentsOf: pcm16)
        bytesWritten = bytesWritten.addingReportingOverflow(UInt32(pcm16.count)).partialValue
    }

    func stop() throws {
        guard let fileHandle else { return }
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.wavHeader(
            pcmByteCount: bytesWritten,
            sampleRate: sampleRate,
            channels: channels
        ))
        try fileHandle.close()
        self.fileHandle = nil
    }

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLiveTranslator Recordings", isDirectory: true)
    }

    private static func timestampedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        return "\(formatter.string(from: now))-\(suffix).wav"
    }

    private static func wavHeader(
        pcmByteCount: UInt32,
        sampleRate: UInt32,
        channels: UInt16
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffSize = 36 + pcmByteCount

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(pcmByteCount)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
