import Foundation

enum JoystickTap {
    static func isConfirmation(
        startDistance: Double,
        knobRadius: Double,
        maximumTravel: Double,
        duration: TimeInterval
    ) -> Bool {
        startDistance <= knobRadius && maximumTravel < 10 && duration >= 0 && duration <= 0.5
    }
}

struct JoystickInput: Equatable {
    let command: RemoteCommand
    let repeatInterval: TimeInterval

    init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        let magnitude = min(1, hypot(x, y))
        let deadZone = 0.18
        guard magnitude > deadZone else { return nil }

        if abs(x) >= abs(y) {
            command = x >= 0 ? .right : .left
        } else {
            command = y >= 0 ? .down : .up
        }
        let intensity = (magnitude - deadZone) / (1 - deadZone)
        repeatInterval = 0.48 - intensity * 0.38
    }
}

enum RemoteCommand: String, CaseIterable, Identifiable {
    case power
    case back
    case home
    case up
    case down
    case left
    case right
    case select
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case rewind
    case fastForward

    var id: String { rawValue }

    var androidTVKeyCode: String {
        switch self {
        case .power: "POWER"
        case .back: "BACK"
        case .home: "HOME"
        case .up: "DPAD_UP"
        case .down: "DPAD_DOWN"
        case .left: "DPAD_LEFT"
        case .right: "DPAD_RIGHT"
        case .select: "DPAD_CENTER"
        case .volumeUp: "VOLUME_UP"
        case .volumeDown: "VOLUME_DOWN"
        case .mute: "MUTE"
        case .playPause: "MEDIA_PLAY_PAUSE"
        case .rewind: "MEDIA_REWIND"
        case .fastForward: "MEDIA_FAST_FORWARD"
        }
    }

    var protocolKeyCode: Remote_RemoteKeyCode {
        switch self {
        case .power: .keycodePower
        case .back: .keycodeBack
        case .home: .keycodeHome
        case .up: .keycodeDpadUp
        case .down: .keycodeDpadDown
        case .left: .keycodeDpadLeft
        case .right: .keycodeDpadRight
        case .select: .keycodeDpadCenter
        case .volumeUp: .keycodeVolumeUp
        case .volumeDown: .keycodeVolumeDown
        case .mute: .keycodeMute
        case .playPause: .keycodeMediaPlayPause
        case .rewind: .keycodeMediaRewind
        case .fastForward: .keycodeMediaFastForward
        }
    }

    var symbolName: String {
        switch self {
        case .power: "power"
        case .back: "chevron.backward"
        case .home: "house.fill"
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .select: "circle.fill"
        case .volumeUp: "speaker.wave.2.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .mute: "speaker.slash.fill"
        case .playPause: "playpause.fill"
        case .rewind: "backward.fill"
        case .fastForward: "forward.fill"
        }
    }
}