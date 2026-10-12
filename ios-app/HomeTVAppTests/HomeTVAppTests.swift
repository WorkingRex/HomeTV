import XCTest
import Network
@testable import HomeTV

final class HomeTVAppTests: XCTestCase {
    func testRemoteCommandKeyCodesMatchAndroidTVProtocolNames() {
        XCTAssertEqual(RemoteCommand.home.androidTVKeyCode, "HOME")
        XCTAssertEqual(RemoteCommand.select.androidTVKeyCode, "DPAD_CENTER")
        XCTAssertEqual(RemoteCommand.playPause.androidTVKeyCode, "MEDIA_PLAY_PAUSE")
    }

    func testEveryRemoteCommandHasAnAccessibilitySymbol() {
        for command in RemoteCommand.allCases {
            XCTAssertFalse(command.symbolName.isEmpty)
        }
    }

    func testKeyMessageUsesShortPressAndExpectedKeyCode() throws {
        let message = RemoteMessageFactory.key(.home)
        XCTAssertEqual(message.remoteKeyInject.keyCode, .keycodeHome)
        XCTAssertEqual(message.remoteKeyInject.direction, .short)

        let framed = try ProtobufFrameCodec.frame(message)
        XCTAssertEqual(framed.first, 6)
        XCTAssertEqual(try Remote_RemoteMessage(serializedBytes: framed.dropFirst()), message)
    }

    func testFrameDecoderHandlesSplitFrames() throws {
        let first = try ProtobufFrameCodec.frame(RemoteMessageFactory.key(.back))
        let second = try ProtobufFrameCodec.frame(RemoteMessageFactory.launchApp(uri: "https://www.youtube.com"))
        var decoder = ProtobufFrameDecoder()

        XCTAssertEqual(try decoder.append(first.prefix(1)), [])
        let frames: [Data]
        do {
            frames = try decoder.append(Data(first.dropFirst()) + second)
        } catch {
            XCTFail("Unexpected frame decoding error: \(error)")
            return
        }
        XCTAssertEqual(frames.count, 2)
        guard frames.count == 2 else { return }
        XCTAssertEqual(frames[0], Data(first.dropFirst()))
        XCTAssertEqual(frames[1], Data(second.dropFirst()))
    }

    func testTextMessageRejectsEmptyInput() {
        XCTAssertThrowsError(try RemoteMessageFactory.text("")) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .emptyText)
        }
    }

    func testAndroidTVServiceResultBecomesDevice() {
        let endpoint = NWEndpoint.service(
            name: "Living Room TV",
            type: "_androidtvremote2._tcp",
            domain: "local.",
            interface: nil
        )
        let device = TVDiscovery.device(from: endpoint)

        XCTAssertEqual(device?.name, "Living Room TV")
        XCTAssertEqual(device?.type, "_androidtvremote2._tcp")
        XCTAssertEqual(device?.domain, "local.")
    }
}