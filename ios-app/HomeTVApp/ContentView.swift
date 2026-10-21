import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = TVDiscovery()
    @StateObject private var remote = TVRemoteClient()
    @StateObject private var tilt = TiltRemoteController()
    @State private var controlMode = ControlMode.buttons
    @State private var status = "Not connected"
    @State private var selectedDevice: AndroidTVDevice?
    @State private var pairingCode = ""
    @State private var showPairingSheet = false
    @State private var isDiscoveryExpanded = true
    @State private var isConnectionExpanded = true
    @AppStorage("com.rexylin.hometv.last-device-id") private var lastDeviceID = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                connectionCard
                transportControls
                navigationControls
                volumeControls
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 16) {
                directionControls

                Picker("控制模式", selection: $controlMode) {
                    ForEach(ControlMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(remote.state != .connected)
            }
            .padding()
            .background(.bar)
        }
        .onChange(of: controlMode) { _, mode in
            tilt.isEnabled = mode == .tilt && scenePhase == .active && remote.state == .connected
        }
        .task {
            tilt.onCommand = { command in
                remote.send(command)
            }
            guard !isPreview, discovery.state == .idle else { return }
            discovery.start()
        }
        .onChange(of: discovery.devices) { _, devices in
            restoreLastDevice(from: devices)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                tilt.isEnabled = false
                controlMode = .buttons
                return
            }
        }
        .onDisappear {
            tilt.isEnabled = false
            controlMode = .buttons
        }
    }

    private var connectionCard: some View {
        DisclosureGroup(isExpanded: $isConnectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                discoveryControls

                if let selectedDevice {
                    Label("Selected \(selectedDevice.name)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Text(pairingDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(connectionSummary, systemImage: connectionSymbol)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showPairingSheet, onDismiss: {
            if remote.state != .connected {
                remote.stop()
            }
        }) {
            if let selectedDevice {
                PairingSheet(
                    deviceName: selectedDevice.name,
                    code: $pairingCode,
                    remote: remote
                )
            }
        }
        .onChange(of: remote.state) { _, newState in
            if newState != .connected {
                controlMode = .buttons
                tilt.isEnabled = false
            }
            switch newState {
            case .connected:
                showPairingSheet = false
                isConnectionExpanded = false
                isDiscoveryExpanded = false
            case .awaitingPairingCode:
                showPairingSheet = true
                isConnectionExpanded = true
            case .resolving, .pairing, .connecting, .failed:
                tilt.isEnabled = false
                isConnectionExpanded = true
            case .idle:
                break
            }
        }
    }

    private var discoveryControls: some View {
        DisclosureGroup(isExpanded: $isDiscoveryExpanded) {
            Text("Search for Android TV devices on this Wi-Fi network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Find Android TV") {
                    isDiscoveryExpanded = true
                    discovery.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(discovery.state == .searching)

                if discovery.state == .searching {
                    ProgressView("Searching...")
                }

                if discovery.devices.isEmpty, discovery.state == .ready {
                    Text("No Android TV found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(discovery.devices) { device in
                    Button {
                        selectedDevice = device
                        lastDeviceID = device.id
                        pairingCode = ""
                        status = "Selected \(device.name)"
                        showPairingSheet = true
                        remote.startPairing(device: device)
                    } label: {
                        Label(
                            device.name,
                            systemImage: selectedDevice?.id == device.id ? "checkmark.circle.fill" : "tv"
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }

                if case .failed(let message) = discovery.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
        } label: {
            Label("Find Android TV", systemImage: "magnifyingglass")
                .font(.headline)
        }
    }

    private var connectionSummary: String {
        if remote.state == .connected {
            return "Connected to \(selectedDevice?.name ?? "Android TV")"
        }
        return connectionStatus
    }

    private var connectionSymbol: String {
        remote.state == .connected ? "checkmark.circle.fill" : "tv"
    }

    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private func restoreLastDevice(from devices: [AndroidTVDevice]) {
        guard selectedDevice == nil,
              let device = devices.first(where: {
                  $0.id == lastDeviceID || remote.canReconnect(to: $0)
              }) else {
            return
        }

        selectedDevice = device
        lastDeviceID = device.id
        pairingCode = ""
        isConnectionExpanded = true
        showPairingSheet = false
        remote.startPairing(device: device)
    }

    private var connectionStatus: String {
        switch remote.state {
        case .resolving:
            return "Resolving \(selectedDevice?.name ?? "Android TV")"
        case .pairing:
            return "Pairing with Android TV"
        case .awaitingPairingCode:
            return "Enter the pairing code"
        case .connecting:
            return "Connecting to Android TV"
        case .connected:
            return "Connected to \(selectedDevice?.name ?? "Android TV")"
        case .failed:
            return "Connection failed"
        case .idle:
            break
        }

        if let selectedDevice {
            return "Selected \(selectedDevice.name)"
        }

        switch discovery.state {
        case .idle:
            return status
        case .searching:
            return "Searching for Android TV"
        case .ready:
            return discovery.devices.isEmpty ? "No Android TV found" : "Android TV found"
        case .failed:
            return "Discovery failed"
        }
    }

    private var pairingDescription: String {
        switch remote.state {
        case .awaitingPairingCode:
            return "請輸入電視畫面顯示的 6 位配對碼。"
        case .connected:
            return "已連線，可以使用遙控按鍵。"
        case .failed(let message):
            return message
        default:
            return "正在建立安全連線，請稍候。"
        }
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            commandButton(.rewind)
            commandButton(.playPause)
            commandButton(.fastForward)
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 12) {
            commandButton(.back)
            commandButton(.home)
            commandButton(.power)
        }
    }

    private var directionPad: some View {
        VStack(spacing: 12) {
            commandButton(.up)
            HStack(spacing: 12) {
                commandButton(.left)
                commandButton(.select)
                commandButton(.right)
            }

            commandButton(.down)
        }
    }

    @ViewBuilder
    private var directionControls: some View {
        switch controlMode {
        case .buttons:
            directionPad
        case .tilt:
            VStack(spacing: 12) {
                tiltControls
                commandButton(.select)
            }
        case .joystick:
            VStack(spacing: 12) {
                JoystickControl(isActive: remote.state == .connected && scenePhase == .active) {
                    remote.send($0)
                }
                commandButton(.select)
            }
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 12) {
            commandButton(.volumeDown)
            commandButton(.mute)
            commandButton(.volumeUp)
        }
    }

    private var tiltControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tilt controls", systemImage: "iphone")
                .font(.headline)

            if !tilt.isAvailable {
                Text("此裝置不支援動作感測，請使用方向鍵或搖桿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let motionError = tilt.motionError {
                Text("Motion unavailable: \(motionError)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if tilt.isEnabled {
                if !tilt.hasMotionSample {
                    ProgressView("Waiting for motion sensor…")
                        .font(.footnote)
                }

                Label(
                    tilt.isCalibrated
                        ? "Center calibrated"
                        : "Hold phone flat, top toward TV",
                    systemImage: tilt.isCalibrated ? "checkmark.circle.fill" : "arrow.up.circle"
                )
                .font(.footnote)
                .foregroundStyle(tilt.isCalibrated ? .green : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Center: \(tilt.centerValue)")
                    Text("Current: \(tilt.currentValue) · \(tilt.detectedDirection)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text("切換至 Tilt 時會自動設定中心。切換其他模式後再回來即可重新校正。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commandButton(_ command: RemoteCommand) -> some View {
        Button {
            if remote.state == .connected {
                remote.send(command)
                status = "Sent \(command.rawValue)"
            } else {
                status = "Pair the TV before using the remote"
            }
        } label: {
            Image(systemName: command.symbolName)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(command.rawValue)
        .disabled(remote.state != .connected)
    }
}

private enum ControlMode: String, CaseIterable, Identifiable {
    case buttons = "方向鍵"
    case tilt = "Tilt"
    case joystick = "搖桿"

    var id: String { rawValue }
}

private struct JoystickControl: View {
    let isActive: Bool
    let onCommand: (RemoteCommand) -> Void
    @State private var offset = CGSize.zero
    @State private var input: JoystickInput?
    private let radius: CGFloat = 80

    var body: some View {
        VStack(spacing: 12) {
            Text("拖曳搖桿，離中心越遠連發越快；放手停止。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .fill(.quaternary)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .offset(offset)
            }
            .frame(width: 224, height: 224)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isActive else { return }
                        let distance = hypot(value.translation.width, value.translation.height)
                        let scale = distance > radius ? radius / distance : 1
                        offset = CGSize(
                            width: value.translation.width * scale,
                            height: value.translation.height * scale
                        )
                        input = JoystickInput(
                            x: Double(offset.width / radius),
                            y: Double(offset.height / radius)
                        )
                    }
                    .onEnded { _ in stop() }
            )
            .accessibilityLabel("方向搖桿")
            .accessibilityValue(input?.command.rawValue ?? "Center")
        }
        .disabled(!isActive)
        .task(id: input != nil && isActive) {
            guard isActive, input != nil else { return }
            let clock = ContinuousClock()
            var lastSentAt: ContinuousClock.Instant?
            var lastCommand: RemoteCommand?
            while !Task.isCancelled, isActive, let input {
                let now = clock.now
                if lastCommand != input.command ||
                    lastSentAt.map({ $0.duration(to: now) >= .seconds(input.repeatInterval) }) != false {
                    onCommand(input.command)
                    lastCommand = input.command
                    lastSentAt = now
                }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("Unexpected joystick timer error: \(error)")
                    return
                }
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { stop() }
        }
        .onDisappear(perform: stop)
    }

    private func stop() {
        input = nil
        offset = .zero
    }
}

private struct PairingSheet: View {
    let deviceName: String
    @Binding var code: String
    @ObservedObject var remote: TVRemoteClient
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tv.and.hifispeaker.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)

                Text("配對 \(deviceName)")
                    .font(.title2.bold())

                statusView

                if remote.state == .awaitingPairingCode {
                    TextField("輸入 6 位配對碼", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.oneTimeCode)
                        .focused($codeFocused)
                        .submitLabel(.done)
                        .onSubmit(finishPairing)
                        .onAppear {
                            DispatchQueue.main.async {
                                codeFocused = true
                            }
                        }

                    Button("完成配對", action: finishPairing)
                        .buttonStyle(.borderedProminent)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        remote.stop()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: remote.state) { _, newState in
            if newState == .awaitingPairingCode {
                DispatchQueue.main.async {
                    codeFocused = true
                }
            } else if newState == .connected {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch remote.state {
        case .resolving:
            ProgressView("尋找電視位址…")
        case .pairing:
            ProgressView("正在與電視建立安全連線…")
        case .awaitingPairingCode:
            Text("請查看電視畫面上的 6 位配對碼。")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView("配對成功，正在連線…")
        case .connected:
            Label("已連線", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        case .idle:
            Text("準備開始配對")
                .foregroundStyle(.secondary)
        }
    }

    private func finishPairing() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        codeFocused = false
        remote.finishPairing(code: value)
    }
}

#Preview {
    ContentView()
}