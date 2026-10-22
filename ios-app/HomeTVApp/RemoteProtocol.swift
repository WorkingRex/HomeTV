import Foundation
import SwiftProtobuf

struct RemoteHandshake {
    private(set) var activeFeatures: Int32 = 615

    var supportsAppReporting: Bool { activeFeatures & 4 != 0 }

    mutating func response(to message: Remote_RemoteMessage) -> Remote_RemoteMessage? {
        var response = Remote_RemoteMessage()
        if message.hasRemoteConfigure {
            activeFeatures &= message.remoteConfigure.code1
            response.remoteConfigure.code1 = activeFeatures
            response.remoteConfigure.deviceInfo.unknown1 = 1
            response.remoteConfigure.deviceInfo.unknown2 = "1"
            response.remoteConfigure.deviceInfo.packageName = "atvremote"
            response.remoteConfigure.deviceInfo.appVersion = "1.0.0"
        } else if message.hasRemoteSetActive {
            response.remoteSetActive.active = activeFeatures
        } else {
            return nil
        }
        return response
    }
}

struct ReportedTVApp: Equatable {
    let packageName: String

    init?(message: Remote_RemoteMessage) {
        guard message.hasRemoteImeKeyInject,
              message.remoteImeKeyInject.hasAppInfo else { return nil }
        packageName = message.remoteImeKeyInject.appInfo.appPackage
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsPlaybackControls: Bool {
        switch packageName {
        case "com.google.android.youtube.tv", "com.google.android.youtube",
             "com.netflix.ninja", "com.netflix.mediaclient":
            true
        default:
            false
        }
    }

    var displayName: String {
        switch packageName {
        case "com.google.android.youtube.tv", "com.google.android.youtube":
            "YouTube"
        case "com.netflix.ninja", "com.netflix.mediaclient":
            "Netflix"
        case "":
            "未知"
        default:
            packageName
        }
    }
}

struct AppShortcut: Equatable {
    let packageName: String
    let displayName: String

    init?(packageName: String, displayName: String) {
        guard packageName.range(
            of: #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        self.packageName = packageName
        self.displayName = displayName.isEmpty ? packageName : displayName
    }

    init?(reportedApp: ReportedTVApp) {
        self.init(packageName: reportedApp.packageName, displayName: reportedApp.displayName)
    }

    var appLink: String {
        switch packageName {
        case "com.google.android.youtube.tv", "com.google.android.youtube":
            "https://www.youtube.com"
        case "com.netflix.ninja", "com.netflix.mediaclient":
            "netflix://"
        default:
            "android-app://\(packageName)"
        }
    }

    var iconKind: AppShortcutIconKind {
        switch packageName {
        case "com.google.android.youtube.tv", "com.google.android.youtube":
            .youtube
        case "com.netflix.ninja", "com.netflix.mediaclient":
            .netflix
        default:
            .generic
        }
    }
}

enum AppShortcutIconKind: Equatable {
    case youtube
    case netflix
    case generic
}

enum RemoteProtocolError: Error, Equatable {
    case invalidFrameLength
    case frameTooLarge
    case emptyText
}

struct ProtobufFrameCodec {
    static let maximumFrameLength = 1_048_576

    static func frame<Message: SwiftProtobuf.Message>(_ message: Message) throws -> Data {
        let payload = try message.serializedData()
        guard payload.count <= maximumFrameLength else {
            throw RemoteProtocolError.frameTooLarge
        }
        return encodeVarint(UInt64(payload.count)) + payload
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func decodeVarint(_ data: Data) throws -> (value: UInt64, bytes: Int)? {
        var value: UInt64 = 0
        for (index, byte) in data.enumerated() {
            guard index < 10 else {
                throw RemoteProtocolError.invalidFrameLength
            }
            let shift = UInt64(index * 7)
            if index == 9 && byte > 1 {
                throw RemoteProtocolError.invalidFrameLength
            }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return (value, index + 1)
            }
        }
        return nil
    }
}

struct ProtobufFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while !buffer.isEmpty {
            guard let header = try ProtobufFrameCodec.decodeVarint(buffer) else {
                break
            }
            guard header.value <= UInt64(ProtobufFrameCodec.maximumFrameLength) else {
                throw RemoteProtocolError.frameTooLarge
            }
            let payloadLength = Int(header.value)
            guard header.bytes <= buffer.count,
                  payloadLength <= buffer.count - header.bytes else {
                break
            }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: header.bytes)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLength)
            frames.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }

        return frames
    }
}

enum RemoteMessageFactory {
    static func key(_ command: RemoteCommand) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteKeyInject.keyCode = command.protocolKeyCode
        message.remoteKeyInject.direction = .short
        return message
    }

    static func text(_ value: String, imeCounter: Int32 = 0, fieldCounter: Int32 = 0) throws -> Remote_RemoteMessage {
        guard !value.isEmpty else {
            throw RemoteProtocolError.emptyText
        }

        let cursor = Int32(value.count - 1)
        var edit = Remote_RemoteEditInfo()
        edit.insert = 1
        edit.textFieldStatus.start = cursor
        edit.textFieldStatus.end = cursor
        edit.textFieldStatus.value = value

        var batch = Remote_RemoteImeBatchEdit()
        batch.imeCounter = imeCounter
        batch.fieldCounter = fieldCounter
        batch.editInfo = [edit]

        var message = Remote_RemoteMessage()
        message.remoteImeBatchEdit = batch
        return message
    }

    static func launchApp(uri: String) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteAppLinkLaunchRequest.appLink = uri
        return message
    }
}