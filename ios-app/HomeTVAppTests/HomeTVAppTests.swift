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

    func testPowerMessageUsesPowerToggleKeyCode() throws {
        let message = RemoteMessageFactory.key(.power)
        XCTAssertEqual(RemoteCommand.power.androidTVKeyCode, "POWER")
        XCTAssertEqual(message.remoteKeyInject.keyCode.rawValue, 26)
        XCTAssertEqual(message.remoteKeyInject.direction, .short)

        let framed = try ProtobufFrameCodec.frame(message)
        var decoder = ProtobufFrameDecoder()
        let frames = try decoder.append(framed)
        XCTAssertEqual(frames.count, 1)
        let payload = try XCTUnwrap(frames.first)
        XCTAssertEqual(try Remote_RemoteMessage(serializedBytes: payload), message)
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

    func testJoystickDeadZoneAndDirections() {
        XCTAssertNil(JoystickInput(x: 0, y: 0))
        XCTAssertNil(JoystickInput(x: 0.18, y: 0))
        XCTAssertNil(JoystickInput(x: .nan, y: 0))
        XCTAssertEqual(JoystickInput(x: 0.19, y: 0)?.command, .right)
        XCTAssertEqual(JoystickInput(x: -0.6, y: 0.2)?.command, .left)
        XCTAssertEqual(JoystickInput(x: 0.2, y: -0.6)?.command, .up)
        XCTAssertEqual(JoystickInput(x: 0, y: 1)?.command, .down)
    }

    func testJoystickRepeatsFasterAwayFromCenter() throws {
        let nearCenter = try XCTUnwrap(JoystickInput(x: 0.2, y: 0))
        let middle = try XCTUnwrap(JoystickInput(x: 0.6, y: 0))
        let edge = try XCTUnwrap(JoystickInput(x: 1, y: 0))
        XCTAssertGreaterThan(nearCenter.repeatInterval, middle.repeatInterval)
        XCTAssertGreaterThan(middle.repeatInterval, edge.repeatInterval)
        XCTAssertEqual(edge.repeatInterval, 0.1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(nearCenter.repeatInterval, 0.48)
        XCTAssertEqual(JoystickInput(x: 2, y: 0)?.repeatInterval, edge.repeatInterval)
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