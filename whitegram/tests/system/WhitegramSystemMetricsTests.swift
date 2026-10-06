import AVFoundation
@testable import Display
import Foundation
@testable import TelegramUI
import XCTest

final class WhitegramSystemMetricsTests: XCTestCase {
    func testRAMUsesTruncatedBinaryMegabytes() {
        XCTAssertEqual(WhitegramRAMUsage.text(physicalFootprint: 1048575), "0 MB")
        XCTAssertEqual(WhitegramRAMUsage.text(physicalFootprint: 1048576), "1 MB")
        XCTAssertEqual(WhitegramRAMUsage.text(physicalFootprint: 2097151), "1 MB")
        XCTAssertEqual(WhitegramRAMUsage.text(physicalFootprint: 4294967296), "4096 MB")
    }

    func testPhysicalFootprintReadsTheLiveDarwinProcess() throws {
        XCTAssertGreaterThan(try XCTUnwrap(WhitegramRAMUsage.physicalFootprint()), 0)
    }

    func testRAMPlacementAccountsForSafeAreaAndCeilsLabelSize() {
        let portrait = WhitegramRAMUsage.frame(labelSize: CGSize(width: 27.2, height: 15.3), statusBarHeight: 59, leftInset: 0, scale: 3)
        XCTAssertEqual(portrait, CGRect(x: 6, y: 42, width: 28, height: 16))
        let landscape = WhitegramRAMUsage.frame(labelSize: CGSize(width: 28, height: 16), statusBarHeight: 0, leftInset: 44, scale: 3)
        XCTAssertEqual(landscape.origin, CGPoint(x: 50, y: 12))
    }

    func testRAMPlacementFloorsToPhysicalPixels() {
        let frame = WhitegramRAMUsage.frame(labelSize: CGSize(width: 34.1, height: 14.1), statusBarHeight: 54.8, leftInset: 3.25, scale: 3)
        XCTAssertEqual(frame.minX, 9.0, accuracy: 0.000001)
        XCTAssertEqual(frame.minY, 116.0 / 3.0, accuracy: 0.000001)
        XCTAssertEqual(frame.size, CGSize(width: 35, height: 15))
    }

    func testRecoveredSilentWaveDecodesAsOneSecondMonoEightKilohertz() throws {
        let data = WhitegramSilentAudio.waveData()
        let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        XCTAssertEqual(data.count, 16044)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(player.format.sampleRate, 8000)
        XCTAssertEqual(player.duration, 1.0, accuracy: 0.000001)
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }
}
