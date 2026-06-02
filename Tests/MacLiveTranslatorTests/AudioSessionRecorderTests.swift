import Foundation
@testable import MacLiveTranslator
import XCTest

final class AudioSessionRecorderTests: XCTestCase {
    func testRecorderWritesPlayableWAVWithAllPCMBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = AudioSessionRecorder(outputDirectory: directory)

        let fileURL = try recorder.start(sampleRate: 16_000, channels: 1)
        let firstChunk = Data([0x01, 0x00, 0xff, 0x7f])
        let secondChunk = Data([0x00, 0x80, 0x00, 0x00, 0x34, 0x12])
        try recorder.append(firstChunk)
        try recorder.append(secondChunk)
        try recorder.stop()

        let wav = try Data(contentsOf: fileURL)
        XCTAssertEqual(wav.count, 44 + firstChunk.count + secondChunk.count)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(wav.littleEndianUInt32(at: 24), 16_000)
        XCTAssertEqual(wav.littleEndianUInt16(at: 22), 1)
        XCTAssertEqual(wav.littleEndianUInt16(at: 34), 16)
        XCTAssertEqual(wav.littleEndianUInt32(at: 40), UInt32(firstChunk.count + secondChunk.count))
        XCTAssertEqual(wav[44..<wav.count], firstChunk + secondChunk)
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
