import XCTest
import Network
@testable import HomeTV

final class HomeTVAppTests: XCTestCase {
    func testAppShortcutBuildsNetflixDeepLinkForDetectedPackage() throws {
        var message = Remote_RemoteMessage()
        message.remoteImeKeyInject.appInfo.appPackage = "com.netflix.ninja"
        let reported = try XCTUnwrap(ReportedTVApp(message: message))
        let value = try XCTUnwrap(AppShortcut(reportedApp: reported))
        XCTAssertEqual(value.displayName, "Netflix")
        XCTAssertEqual(value.iconKind, .netflix)
        XCTAssertEqual(value.appLink, "netflix://")
    }

    func testAppShortcutUsesKnownDeepLinksAndAndroidAppURIForOtherPackages() {
        XCTAssertEqual(
            AppShortcut(packageName: "com.google.android.youtube.tv", displayName: "YouTube")?.appLink,
            "https://www.youtube.com"
        )
        XCTAssertEqual(
            AppShortcut(packageName: "com.example.tv", displayName: "Example")?.appLink,
            "android-app://com.example.tv"
        )
    }

    func testAppShortcutRejectsInvalidPackageNames() {
        XCTAssertNil(AppShortcut(packageName: "", displayName: ""))
        XCTAssertNil(AppShortcut(packageName: "com.netflix;end", displayName: "Netflix"))
        XCTAssertNil(AppShortcut(packageName: "com.example/path", displayName: "Example"))
        XCTAssertEqual(
            AppShortcut(packageName: "com.example.tv", displayName: "").map(\.displayName),
            "com.example.tv"
        )
    }

    func testAppShortcutUsesKnownIconsAndGenericFallback() {
        XCTAssertEqual(
            AppShortcut(packageName: "com.google.android.youtube.tv", displayName: "YouTube")?.iconKind,
            .youtube
        )
        XCTAssertEqual(
            AppShortcut(packageName: "com.example.tv", displayName: "Example")?.iconKind,
            .generic
        )
    }

    func testAppShortcutCollectionPersistsMultipleUniqueApps() throws {
        let shortcuts = [
            try XCTUnwrap(AppShortcut(packageName: "com.netflix.ninja", displayName: "Netflix")),
            try XCTUnwrap(AppShortcut(packageName: "com.google.android.youtube.tv", displayName: "YouTube")),
        ]
        let data = try JSONEncoder().encode(shortcuts)
        XCTAssertEqual(try JSONDecoder().decode([AppShortcut].self, from: data), shortcuts)
        XCTAssertEqual(Set(shortcuts.map(\.packageName)).count, shortcuts.count)
        XCTAssertEqual(AppShortcutCollection.adding(shortcuts[0], to: shortcuts), shortcuts)
        XCTAssertEqual(
            AppShortcutCollection.adding(
                try XCTUnwrap(AppShortcut(packageName: "com.example.tv", displayName: "Example")),
                to: shortcuts
            ).count,
            3
        )
        XCTAssertEqual(
            AppShortcutCollection.removing(id: shortcuts[0].id, from: shortcuts),
            [shortcuts[1]]
        )
        XCTAssertEqual(AppShortcutCollection.removing(id: "missing", from: shortcuts), shortcuts)
    }

    func testControlLayoutPreservesSavedOrderAndPinsNewControlsAfterward() {
        XCTAssertEqual(
            RemoteControlLayout.orderedIDs(
                availableIDs: ["back", "home", "volume", "shortcut:netflix"],
                storedIDs: ["volume", "removed", "back"]
            ),
            ["volume", "back", "home", "shortcut:netflix"]
        )
    }

    func testControlLayoutMovesTilesAndKeepsDirectionPadOutsideMovableIDs() {
        let initial = ["back", "shortcut:netflix", "home"]
        XCTAssertEqual(
            RemoteControlLayout.moving(initial, source: "shortcut:netflix", destination: "back"),
            ["shortcut:netflix", "back", "home"]
        )
        XCTAssertEqual(RemoteControlLayout.moving(initial, source: "missing", destination: "home"), initial)
    }

    func testJoystickCenterTapConfirmsButDragAndLongPressDoNot() {
        XCTAssertTrue(JoystickTap.isConfirmation(startDistance: 0, knobRadius: 32, maximumTravel: 0, duration: 0.1))
        XCTAssertTrue(JoystickTap.isConfirmation(startDistance: 32, knobRadius: 32, maximumTravel: 9, duration: 0.5))
        XCTAssertFalse(JoystickTap.isConfirmation(startDistance: 33, knobRadius: 32, maximumTravel: 0, duration: 0.1))
        XCTAssertFalse(JoystickTap.isConfirmation(startDistance: 0, knobRadius: 32, maximumTravel: 10, duration: 0.1))
        XCTAssertFalse(JoystickTap.isConfirmation(startDistance: 0, knobRadius: 32, maximumTravel: 80, duration: 0.2))
        XCTAssertFalse(JoystickTap.isConfirmation(startDistance: 0, knobRadius: 32, maximumTravel: 0, duration: 0.6))
    }

    func testRemoteHandshakeWaitsForActivationAndNegotiatesIME() throws {
        var handshake = RemoteHandshake()
        var configuration = Remote_RemoteMessage()
        configuration.remoteConfigure.code1 = 615
        let response = try XCTUnwrap(handshake.response(to: configuration))
        XCTAssertEqual(response.remoteConfigure.code1, 615)
        XCTAssertFalse(response.hasRemoteSetActive)
        XCTAssertTrue(handshake.supportsAppReporting)

        var activation = Remote_RemoteMessage()
        activation.remoteSetActive.active = 0
        let activeResponse = try XCTUnwrap(handshake.response(to: activation))
        XCTAssertEqual(activeResponse.remoteSetActive.active, 615)
        XCTAssertFalse(activeResponse.hasRemoteConfigure)
        XCTAssertNil(handshake.response(to: RemoteMessageFactory.key(.home)))
    }

    func testRemoteHandshakeDoesNotAdvertiseUnsupportedFeatures() throws {
        var handshake = RemoteHandshake()
        var configuration = Remote_RemoteMessage()
        configuration.remoteConfigure.code1 = 611
        XCTAssertEqual(handshake.response(to: configuration)?.remoteConfigure.code1, 611)
        XCTAssertFalse(handshake.supportsAppReporting)

        var activation = Remote_RemoteMessage()
        activation.remoteSetActive.active = 1023
        XCTAssertEqual(handshake.response(to: activation)?.remoteSetActive.active, 611)
    }

    func testAppReportDecodesAfterActivationAndAcrossSplitFrames() throws {
        var activation = Remote_RemoteMessage()
        activation.remoteSetActive.active = 615
        var appReport = Remote_RemoteMessage()
        appReport.remoteImeKeyInject.appInfo.appPackage = "com.netflix.ninja"
        let activationFrame = try ProtobufFrameCodec.frame(activation)
        let appFrame = try ProtobufFrameCodec.frame(appReport)
        var decoder = ProtobufFrameDecoder()
        var handshake = RemoteHandshake()
        let firstFrames = try decoder.append(activationFrame + appFrame.prefix(2))
        XCTAssertEqual(firstFrames.count, 1)
        let activationMessage = try Remote_RemoteMessage(serializedBytes: XCTUnwrap(firstFrames.first))
        XCTAssertNotNil(handshake.response(to: activationMessage))
        let remainingFrames = try decoder.append(Data(appFrame.dropFirst(2)))
        let receivedApp = try Remote_RemoteMessage(serializedBytes: XCTUnwrap(remainingFrames.first))
        XCTAssertEqual(ReportedTVApp(message: receivedApp)?.displayName, "Netflix")
    }

    func testReportedPlaybackAppsAreRecognizedFromTVMessages() throws {
        for (package, name) in [
            ("com.google.android.youtube.tv", "YouTube"),
            ("com.google.android.youtube", "YouTube"),
            ("com.netflix.ninja", "Netflix"),
            ("com.netflix.mediaclient", "Netflix")
        ] {
            var message = Remote_RemoteMessage()
            message.remoteImeKeyInject.appInfo.appPackage = package
            let decoded = try Remote_RemoteMessage(serializedBytes: message.serializedData())
            let app = try XCTUnwrap(ReportedTVApp(message: decoded))
            XCTAssertEqual(app.packageName, package)
            XCTAssertEqual(app.displayName, name)
            XCTAssertTrue(app.showsPlaybackControls)
        }
    }

    func testOtherAndUnknownAppsDoNotAutomaticallyShowPlaybackControls() throws {
        XCTAssertNil(ReportedTVApp(message: RemoteMessageFactory.key(.home)))
        var message = Remote_RemoteMessage()
        message.remoteImeKeyInject.textFieldStatus.value = "Search"
        XCTAssertNil(ReportedTVApp(message: message))

        for package in ["com.google.android.tvlauncher", "", "com.netflix.ninja.fake"] {
            message.remoteImeKeyInject.appInfo.appPackage = package
            let app = try XCTUnwrap(ReportedTVApp(message: message))
            XCTAssertFalse(app.showsPlaybackControls)
            XCTAssertEqual(app.displayName, package.isEmpty ? "未知" : package)
        }
    }

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

    func testBackMessageUsesAndroidBackKeyCode() throws {
        let message = RemoteMessageFactory.key(.back)
        XCTAssertEqual(RemoteCommand.back.androidTVKeyCode, "BACK")
        XCTAssertEqual(message.remoteKeyInject.keyCode, .keycodeBack)
        XCTAssertEqual(message.remoteKeyInject.keyCode.rawValue, 4)
        XCTAssertEqual(message.remoteKeyInject.direction, .short)

        let framed = try ProtobufFrameCodec.frame(message)
        let decoded = try Remote_RemoteMessage(serializedBytes: framed.dropFirst())
        XCTAssertEqual(decoded.remoteKeyInject.keyCode, .keycodeBack)
        XCTAssertEqual(decoded.remoteKeyInject.direction, .short)
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