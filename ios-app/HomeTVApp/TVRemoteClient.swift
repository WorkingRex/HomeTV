import Combine
import Crypto
import Foundation
import Network
import OSLog
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
    @Published private(set) var state: TVRemoteState = .idle {
        didSet {
            if state != .connected {
                reportedApp = nil
            }
        }
    }
    @Published private(set) var reportedApp: ReportedTVApp?
    @Published private(set) var supportsAppReporting: Bool?

    private let identityStore = TVIdentityStore()
    private let networkQueue = DispatchQueue(label: "com.rexylin.hometv.network")
    private var identity: TVIdentity?
    private var host: NWEndpoint.Host?
    private var shouldFallbackToPairing = false
    private var serverNumbers: (modulus: Data, exponent: Data)?
    private var selectedDevice: AndroidTVDevice?
    private var pairingConnection: NWConnection?
    private var remoteConnection: NWConnection?
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var remoteReconnectAttempts = 0
    private var pairingDecoder = ProtobufFrameDecoder()
    private var remoteDecoder = ProtobufFrameDecoder()
    private var remoteHandshake = RemoteHandshake()
    private let logger = Logger(subsystem: "com.rexylin.hometv", category: "RemoteSession")

    func canReconnect(to device: AndroidTVDevice) -> Bool {
        identityStore.hasStoredIdentity() && identityStore.isPaired(for: device.id)
    }

    func startPairing(device: AndroidTVDevice, forcePairing: Bool = false) {
        stop()
        selectedDevice = device
        state = .resolving
        Task {
            do {
                let reuseStoredIdentity = identityStore.hasStoredIdentity()
                let resolvedHost = try await resolveHost(for: device)
                let clientIdentity = try identityStore.loadOrCreate(upgradeLegacyCertificate: forcePairing)
                host = resolvedHost
                identity = clientIdentity
                shouldFallbackToPairing = !forcePairing &&
                    (reuseStoredIdentity || identityStore.isPaired(for: device.id))
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
            logger.debug("Sending remote key: \(command.androidTVKeyCode, privacy: .public)")
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
            logger.debug("Sending app launch link: \(uri, privacy: .public)")
            try send(RemoteMessageFactory.launchApp(uri: uri), through: remoteConnection)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        remoteReconnectAttempts = 0
        cancel(pairingConnection)
        cancel(remoteConnection)
        pairingConnection = nil
        remoteConnection = nil
        pairingDecoder = ProtobufFrameDecoder()
        remoteDecoder = ProtobufFrameDecoder()
        supportsAppReporting = nil
        remoteHandshake = RemoteHandshake()
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
                guard let self, self.pairingConnection === connection else { return }
                switch state {
                case .ready:
                    self.serverNumbers = numberBox.value
                    self.state = .pairing
                    self.receive(on: connection, pairing: true)
                    var message = self.basePairingMessage()
                    message.pairingRequest.serviceName = "atvremote"
                    guard let identity = self.identity,
                          let clientName = SecCertificateCopySubjectSummary(identity.certificate) as String? else {
                        self.state = .failed(TVRemoteError.missingIdentity.localizedDescription)
                        return
                    }
                    message.pairingRequest.clientName = clientName
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

        remoteDecoder = ProtobufFrameDecoder()
        remoteHandshake = RemoteHandshake()
        supportsAppReporting = nil
        let numberBox = RSANumberBox()
        let parameters = try makeTLSParameters(identity: identity, serverNumbers: numberBox)
        let connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: 6466)!,
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.remoteConnection === connection else { return }
                if case .failed(let error) = state {
                    self.remoteConnectionFailed(error, connection: connection)
                }
                if case .ready = state {
                    self.logger.debug("Remote TLS ready; waiting for protocol handshake")
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.receive(on: connection, pairing: false)
                }
            }
        }
        remoteConnection = connection
        state = .connecting
        connection.start(queue: networkQueue)
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                return
            } catch {
                self?.remoteConnectionFailed(error, connection: connection)
                return
            }
            guard let self, self.state == .connecting else { return }
            self.remoteConnectionFailed(TVRemoteError.handshakeTimedOut, connection: connection)
        }
    }

    private func remoteConnectionFailed(_ error: Error, connection: NWConnection) {
        guard remoteConnection === connection else { return }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        remoteConnection = nil
        cancel(connection)
        logger.error("Remote connection ended: \(error.localizedDescription, privacy: .public)")
        if let networkError = error as? NWError, case .tls(-9825) = networkError {
            state = .failed("電視不再接受這支手機的配對憑證。請點「重新配對」；若使用多支手機，請將各手機更新後各自重新配對一次。")
            return
        }
        guard state == .connecting || state == .connected else {
            state = .failed(error.localizedDescription)
            return
        }
        state = .connecting
        retryRemoteConnection(after: error)
    }

    private func retryRemoteConnection(after error: Error) {
        guard remoteReconnectAttempts < 2 else {
            state = .failed(error.localizedDescription)
            return
        }

        remoteReconnectAttempts += 1
        let delay = UInt64(remoteReconnectAttempts) * 500_000_000
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self, self.state == .connecting else { return }
            do {
                self.logger.debug("Retrying existing paired remote connection (\(self.remoteReconnectAttempts, privacy: .public)/2)")
                try self.openRemoteConnection()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
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
                    guard pairing ? self.pairingConnection === connection : self.remoteConnection === connection else {
                        return
                    }
                    do {
                        if let data {
                            if pairing {
                                try self.handlePairingData(data)
                            } else {
                                try self.handleRemoteData(data)
                            }
                        }
                    } catch {
                        if pairing {
                            self.state = .failed(error.localizedDescription)
                        } else {
                            self.remoteConnectionFailed(error, connection: connection)
                        }
                        return
                    }
                    if !pairing, let error {
                        self.remoteConnectionFailed(error, connection: connection)
                        return
                    }
                    if !pairing, isComplete {
                        self.remoteConnectionFailed(TVRemoteError.connectionClosed, connection: connection)
                        return
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
            if let app = ReportedTVApp(message: message) {
                reportedApp = app
                logger.debug("TV reported app: \(app.packageName, privacy: .public)")
            }
            if let response = remoteHandshake.response(to: message) {
                try send(response, through: remoteConnection)
                if message.hasRemoteConfigure {
                    supportsAppReporting = remoteHandshake.supportsAppReporting
                    logger.debug("Negotiated remote features: \(self.remoteHandshake.activeFeatures)")
                    if !remoteHandshake.supportsAppReporting {
                        logger.warning("TV did not advertise IME app reporting support")
                    }
                } else {
                    logger.debug("Replied to TV remote activation request")
                }
            } else if message.hasRemoteStart {
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                remoteReconnectAttempts = 0
                state = .connected
                logger.debug("TV remote session started")
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
        networkQueue.async { [weak self] in
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        if self.remoteConnection === connection {
                            self.remoteConnectionFailed(error, connection: connection)
                        } else if self.pairingConnection === connection {
                            self.logger.error("Pairing send failed: \(error.localizedDescription, privacy: .public)")
                            self.state = .failed(error.localizedDescription)
                        }
                    }
                }
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
    case handshakeTimedOut
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .hostResolutionFailed: "Unable to resolve the Android TV address."
        case .missingIdentity: "The TV identity is not ready."
        case .identityCreationFailed: "Unable to configure the TLS identity."
        case .invalidPairingCode: "The pairing code is invalid."
        case .notConnected: "The Android TV is not connected."
        case .pairingRejected(let status): "The TV rejected pairing (status \(status))."
        case .handshakeTimedOut: "電視未在 10 秒內完成連線。請先關閉另一支手機的 HomeTV 再重試；配對資料仍保留。"
        case .connectionClosed: "電視已關閉遙控連線，可能有其他裝置連入。請重新連線；不需要先刪除配對。"
        }
    }
}