import Combine
import Crypto
import Foundation
import Network
import Security
import SwiftProtobuf

enum TVRemoteState: Equatable {
    case idle
    case resolving
    case pairing
    case awaitingPairingCode
    case connecting
    case connected
    case failed(String)
}

private final class RSANumberBox: @unchecked Sendable {
    var value: (modulus: Data, exponent: Data)?
}

private final class CompletionBox: @unchecked Sendable {
    var value = false
}

private func configureTLSVerification(
    _ options: NWProtocolTLS.Options,
    serverNumbers: RSANumberBox,
    queue: DispatchQueue
) {
    sec_protocol_options_set_verify_block(
        options.securityProtocolOptions,
        { _, trust, complete in
            let trustReference = sec_trust_copy_ref(trust).takeUnretainedValue()
            if let certificate = (SecTrustCopyCertificateChain(trustReference) as? [SecCertificate])?.first {
                let data = SecCertificateCopyData(certificate) as Data
                serverNumbers.value = try? TVIdentityStore.rsaNumbers(fromCertificateData: data)
            }
            complete(true)
        },
        queue
    )
}

@MainActor
final class TVRemoteClient: ObservableObject {
    @Published private(set) var state: TVRemoteState = .idle

    private let identityStore = TVIdentityStore()
    private let networkQueue = DispatchQueue(label: "com.rexylin.hometv.network")
    private var identity: TVIdentity?
    private var host: NWEndpoint.Host?
    private var shouldFallbackToPairing = false
    private var serverNumbers: (modulus: Data, exponent: Data)?
    private var selectedDevice: AndroidTVDevice?
    private var pairingConnection: NWConnection?
    private var remoteConnection: NWConnection?
    private var pairingDecoder = ProtobufFrameDecoder()
    private var remoteDecoder = ProtobufFrameDecoder()

    func canReconnect(to device: AndroidTVDevice) -> Bool {
        identityStore.hasStoredIdentity() && identityStore.isPaired(for: device.id)
    }

    func startPairing(device: AndroidTVDevice) {
        stop()
        selectedDevice = device
        state = .resolving
        Task {
            do {
                let reuseStoredIdentity = identityStore.hasStoredIdentity()
                let resolvedHost = try await resolveHost(for: device)
                let clientIdentity = try identityStore.loadOrCreate()
                host = resolvedHost
                identity = clientIdentity
                shouldFallbackToPairing = reuseStoredIdentity || identityStore.isPaired(for: device.id)
                if shouldFallbackToPairing {
                    try openRemoteConnection()
                } else {
                    try openPairingConnection()
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func finishPairing(code: String) {
        guard state == .awaitingPairingCode else { return }
        do {
            let secret = try pairingSecret(for: code)
            var message = basePairingMessage()
            message.secret.secret = secret
            try send(message, through: pairingConnection)
            state = .pairing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        do {
            try send(RemoteMessageFactory.key(command), through: remoteConnection)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func sendText(_ value: String) {
        guard state == .connected else { return }
        do {
            try send(RemoteMessageFactory.text(value), through: remoteConnection)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func launchApp(uri: String) {
        guard state == .connected else { return }
        do {
            try send(RemoteMessageFactory.launchApp(uri: uri), through: remoteConnection)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        cancel(pairingConnection)
        cancel(remoteConnection)
        pairingConnection = nil
        remoteConnection = nil
        pairingDecoder = ProtobufFrameDecoder()
        remoteDecoder = ProtobufFrameDecoder()
        state = .idle
    }

    private func resolveHost(for device: AndroidTVDevice) async throws -> NWEndpoint.Host {
        try await withCheckedThrowingContinuation { continuation in
            let endpoint = NWEndpoint.service(
                name: device.name,
                type: device.type,
                domain: device.domain,
                interface: nil
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let completed = CompletionBox()
            connection.stateUpdateHandler = { state in
                guard !completed.value else { return }
                switch state {
                case .ready:
                    guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint else {
                        completed.value = true
                        connection.cancel()
                        continuation.resume(throwing: TVRemoteError.hostResolutionFailed)
                        return
                    }
                    completed.value = true
                    connection.cancel()
                    continuation.resume(returning: host)
                case .failed(let error):
                    completed.value = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    private func openPairingConnection() throws {
        guard let host, let identity else {
            throw TVRemoteError.missingIdentity
        }

        let numberBox = RSANumberBox()
        let parameters = try makeTLSParameters(identity: identity, serverNumbers: numberBox)
        let connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: 6467)!,
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.serverNumbers = numberBox.value
                    self.state = .pairing
                    self.receive(on: connection, pairing: true)
                    var message = self.basePairingMessage()
                    message.pairingRequest.serviceName = "atvremote"
                    message.pairingRequest.clientName = "HomeTV Remote"
                    try? self.send(message, through: connection)
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    if self.state == .pairing {
                        self.state = .idle
                    }
                default:
                    break
                }
            }
        }
        pairingConnection = connection
        connection.start(queue: networkQueue)
    }

    private func openRemoteConnection() throws {
        guard let host, let identity else {
            throw TVRemoteError.missingIdentity
        }

        let numberBox = RSANumberBox()
        let parameters = try makeTLSParameters(identity: identity, serverNumbers: numberBox)
        let connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: 6466)!,
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    if self.shouldFallbackToPairing {
                        self.shouldFallbackToPairing = false
                        do {
                            try self.openPairingConnection()
                        } catch {
                            self.state = .failed(error.localizedDescription)
                        }
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                }
                if case .ready = state {
                    self.receive(on: connection, pairing: false)
                }
            }
        }
        remoteConnection = connection
        state = .connecting
        connection.start(queue: networkQueue)
    }

    private func makeTLSParameters(identity: TVIdentity, serverNumbers: RSANumberBox) throws -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = SecIdentityCreate(nil, identity.certificate, identity.privateKey),
              let localIdentity = sec_identity_create(secIdentity) else {
            throw TVRemoteError.identityCreationFailed
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, localIdentity)
        configureTLSVerification(tlsOptions, serverNumbers: serverNumbers, queue: networkQueue)
        return NWParameters(tls: tlsOptions)
    }

    private func receive(on connection: NWConnection, pairing: Bool) {
        networkQueue.async { [weak self] in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        if let data {
                            if pairing {
                                try self.handlePairingData(data)
                            } else {
                                try self.handleRemoteData(data)
                            }
                        }
                    } catch {
                        self.state = .failed(error.localizedDescription)
                    }
                    if error == nil && !isComplete {
                        self.receive(on: connection, pairing: pairing)
                    }
                }
            }
        }
    }

    private func handlePairingData(_ data: Data) throws {
        for frame in try pairingDecoder.append(data) {
            let message = try Polo_Wire_Protobuf_OuterMessage(serializedBytes: frame)
            guard message.status == .ok else {
                throw TVRemoteError.pairingRejected(message.status.rawValue)
            }
            if message.hasPairingRequestAck {
                var response = basePairingMessage()
                var options = Polo_Wire_Protobuf_Options()
                var encoding = Polo_Wire_Protobuf_Options.Encoding()
                encoding.type = .hexadecimal
                encoding.symbolLength = 6
                options.preferredRole = .input
                options.inputEncodings = [encoding]
                response.options = options
                try send(response, through: pairingConnection)
            } else if message.hasOptions {
                var response = basePairingMessage()
                var configuration = Polo_Wire_Protobuf_Configuration()
                configuration.clientRole = .input
                configuration.encoding.type = .hexadecimal
                configuration.encoding.symbolLength = 6
                response.configuration = configuration
                try send(response, through: pairingConnection)
            } else if message.hasConfigurationAck {
                state = .awaitingPairingCode
            } else if message.hasSecretAck {
                cancel(pairingConnection)
                pairingConnection = nil
                if let selectedDevice {
                    identityStore.markPaired(for: selectedDevice.id)
                }
                shouldFallbackToPairing = false
                try openRemoteConnection()
            }
        }
    }

    private func handleRemoteData(_ data: Data) throws {
        for frame in try remoteDecoder.append(data) {
            let message = try Remote_RemoteMessage(serializedBytes: frame)
            if message.hasRemoteConfigure {
                var response = Remote_RemoteMessage()
                response.remoteConfigure.code1 = 615
                response.remoteConfigure.deviceInfo.unknown1 = 1
                response.remoteConfigure.deviceInfo.unknown2 = "1"
                response.remoteConfigure.deviceInfo.packageName = "atvremote"
                response.remoteConfigure.deviceInfo.appVersion = "1.0.0"
                try send(response, through: remoteConnection)

                var active = Remote_RemoteMessage()
                active.remoteSetActive.active = 615
                try send(active, through: remoteConnection)
                state = .connected
            } else if message.hasRemotePingRequest {
                var response = Remote_RemoteMessage()
                response.remotePingResponse.val1 = message.remotePingRequest.val1
                try send(response, through: remoteConnection)
            }
        }
    }

    private func send<Message: SwiftProtobuf.Message>(_ message: Message, through connection: NWConnection?) throws {
        guard let connection else {
            throw TVRemoteError.notConnected
        }
        let content = try ProtobufFrameCodec.frame(message)
        networkQueue.async {
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func cancel(_ connection: NWConnection?) {
        guard let connection else { return }
        networkQueue.async {
            connection.cancel()
        }
    }

    private func basePairingMessage() -> Polo_Wire_Protobuf_OuterMessage {
        var message = Polo_Wire_Protobuf_OuterMessage()
        message.protocolVersion = 2
        message.status = .ok
        return message
    }

    private func pairingSecret(for code: String) throws -> Data {
        let normalized = code.uppercased()
        guard normalized.count == 6,
              let codeBytes = dataFromHex(normalized),
              let serverNumbers,
              let identity else {
            throw TVRemoteError.invalidPairingCode
        }

        var hashInput = Data()
        hashInput.append(dataFromInteger(identity.clientModulus))
        hashInput.append(dataFromInteger(identity.clientExponent))
        hashInput.append(dataFromInteger(serverNumbers.modulus))
        hashInput.append(dataFromInteger(serverNumbers.exponent))
        hashInput.append(codeBytes.dropFirst(1))

        let hash = Data(SHA256.hash(data: hashInput))
        guard hash.first == codeBytes.first else {
            throw TVRemoteError.invalidPairingCode
        }
        return hash
    }

    private func dataFromInteger(_ data: Data) -> Data {
        var normalized = data
        while normalized.count > 1, normalized.first == 0 {
            normalized.removeFirst()
        }
        return normalized
    }

    private func dataFromHex(_ value: String) -> Data? {
        guard value.count % 2 == 0 else { return nil }
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

private enum TVRemoteError: LocalizedError {
    case hostResolutionFailed
    case missingIdentity
    case identityCreationFailed
    case invalidPairingCode
    case notConnected
    case pairingRejected(Int)

    var errorDescription: String? {
        switch self {
        case .hostResolutionFailed: "Unable to resolve the Android TV address."
        case .missingIdentity: "The TV identity is not ready."
        case .identityCreationFailed: "Unable to configure the TLS identity."
        case .invalidPairingCode: "The pairing code is invalid."
        case .notConnected: "The Android TV is not connected."
        case .pairingRejected(let status): "The TV rejected pairing (status \(status))."
        }
    }
}