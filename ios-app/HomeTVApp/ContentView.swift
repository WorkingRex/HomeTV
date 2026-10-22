import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var discovery = TVDiscovery()
    @StateObject private var remote = TVRemoteClient()
    @StateObject private var tilt = TiltRemoteController()
    @State private var controlMode = ControlMode.buttons
    @State private var isHintPopoverPresented = false
    @State private var status = "Not connected"
    @State private var selectedDevice: AndroidTVDevice?
    @State private var pairingCode = ""
    @State private var showPairingSheet = false
    @State private var isDiscoveryExpanded = true
    @State private var showConnectionSheet = false
    @State private var showRePairConfirmation = false
    @AppStorage("com.rexylin.hometv.last-device-id") private var lastDeviceID = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                connectionCard
                navigationControls
                volumeControls
                transportControls
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: verticalSizeClass == .compact ? 8 : 16) {
                directionControls

                HStack(spacing: 10) {
                    Picker("控制模式", selection: $controlMode) {
                        ForEach(ControlMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(remote.state != .connected)

                    hintButton
                }
            }
            .padding(verticalSizeClass == .compact ? 8 : 16)
            .background(.bar)
            .overlay(alignment: .bottomTrailing) {
                if isHintPopoverPresented {
                    hintPopover
                        .padding(.trailing, 52)
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(1)
                }
            }
        }
        .onChange(of: controlMode) { _, mode in
            tilt.isEnabled = mode == .tilt && scenePhase == .active && remote.state == .connected
        }
        .onChange(of: remote.reportedApp) { _, _ in
            isHintPopoverPresented = false
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
        Button {
            showConnectionSheet = true
        } label: {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(remote.state == .connected ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(remote.state == .connected ? selectedDevice?.name ?? "Android TV" : connectionSummary)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(connectionSummary)
                Spacer()
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showConnectionSheet, onDismiss: {
            if showPairingSheet, remote.state != .connected {
                remote.stop()
            }
            showPairingSheet = false
        }) {
            if showPairingSheet, let selectedDevice {
                PairingSheet(
                    deviceName: selectedDevice.name,
                    code: $pairingCode,
                    remote: remote
                )
            } else {
                connectionSettings
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
                showConnectionSheet = false
                isDiscoveryExpanded = false
            case .awaitingPairingCode:
                showPairingSheet = true
                showConnectionSheet = true
            case .resolving, .pairing, .connecting, .failed:
                tilt.isEnabled = false
            case .idle:
                break
            }
        }
    }

    private var connectionSettings: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(connectionSummary)
                        .font(.headline)
                    discoveryControls
                    if selectedDevice != nil {
                        Text(pairingDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("重新配對", systemImage: "arrow.triangle.2.circlepath") {
                            showRePairConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(remote.state == .resolving || remote.state == .pairing || remote.state == .connecting)
                    }
                }
                .padding()
            }
            .navigationTitle("連線設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showConnectionSheet = false }
                }
            }
            .confirmationDialog(
                "重新配對 \(selectedDevice?.name ?? "Android TV")？",
                isPresented: $showRePairConfirmation,
                titleVisibility: .visible
            ) {
                Button("開始重新配對", role: .destructive) {
                    guard let selectedDevice else { return }
                    pairingCode = ""
                    showPairingSheet = true
                    remote.startPairing(device: selectedDevice, forcePairing: true)
                }
            } message: {
                Text("目前連線會中斷，請依電視畫面輸入新的配對碼。")
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
        Group {
            if remote.reportedApp?.showsPlaybackControls == true {
                playbackButtons
            }
        }
    }

    private var playbackButtons: some View {
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
            JoystickControl(
                isActive: remote.state == .connected && scenePhase == .active,
                onCommand: { remote.send($0) },
                diameter: verticalSizeClass == .compact ? 144 : 224
            )
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

            if tilt.isEnabled {
                Label(
                    tilt.hasMotionSample ? tilt.detectedDirection : "等待感測器",
                    systemImage: tilt.isCalibrated ? "checkmark.circle.fill" : "arrow.up.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hintButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isHintPopoverPresented.toggle()
            }
        } label: {
            Image(systemName: "info.circle")
                .font(.title3)
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("提示與診斷")
    }

    private var hintPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("提示與狀態")
                        .font(.headline)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isHintPopoverPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("關閉提示")
                }

                Divider()

                Label(
                    "目前 App：\(remote.reportedApp?.displayName ?? "尚未辨識")",
                    systemImage: remote.reportedApp?.showsPlaybackControls == true ? "play.fill" : "tv"
                )

                if remote.supportsAppReporting == false {
                    Text("電視未回報 App 資訊，因此不會自動顯示 App 專屬播放鍵。")
                        .foregroundStyle(.secondary)
                } else if remote.reportedApp == nil {
                    Text("辨識到 YouTube 或 Netflix 時，播放控制會自動顯示。")
                        .foregroundStyle(.secondary)
                }

                if controlMode == .tilt {
                    Divider()
                    if !tilt.isAvailable {
                        Text("此裝置不支援動作感測，請切換至方向鍵或搖桿。")
                            .foregroundStyle(.secondary)
                    } else if let motionError = tilt.motionError {
                        Text("Motion unavailable: \(motionError)")
                            .foregroundStyle(.red)
                    } else if !tilt.hasMotionSample {
                        Text("正在等待動作感測器資料。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tilt.isCalibrated ? "Tilt 中心已校正。" : "保持手機平放、頂端朝向電視。")
                            .foregroundStyle(.secondary)
                        Text("中心：\(tilt.centerValue)\n目前：\(tilt.currentValue) · \(tilt.detectedDirection)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("切換至 Tilt 時會自動設定中心。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxWidth: 300, maxHeight: verticalSizeClass == .compact ? 160 : 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .padding(.leading, 12)
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
    let diameter: CGFloat
    @State private var offset = CGSize.zero
    @State private var input: JoystickInput?
    @State private var maximumTravel: CGFloat = 0
    @State private var gestureStartedAt: Date?

    private var radius: CGFloat { diameter * 0.36 }
    private var knobDiameter: CGFloat { min(64, diameter * 0.3) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Text("OK")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(offset)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isActive else { return }
                        if gestureStartedAt == nil {
                            gestureStartedAt = value.time
                        }
                        let distance = hypot(value.translation.width, value.translation.height)
                        maximumTravel = max(maximumTravel, distance)
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
                    .onEnded { value in
                        let startDistance = hypot(
                            value.startLocation.x - diameter / 2,
                            value.startLocation.y - diameter / 2
                        )
                        let travel = max(
                            maximumTravel,
                            hypot(value.translation.width, value.translation.height)
                        )
                        let confirms = isActive && JoystickTap.isConfirmation(
                            startDistance: Double(startDistance),
                            knobRadius: Double(knobDiameter / 2),
                            maximumTravel: Double(travel),
                            duration: gestureStartedAt.map { value.time.timeIntervalSince($0) } ?? .infinity
                        )
                        stop()
                        if confirms { onCommand(.select) }
                    }
            )
            .accessibilityLabel("方向搖桿")
            .accessibilityValue(input?.command.rawValue ?? "Center")
            .accessibilityAction {
                if isActive { onCommand(.select) }
            }
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
        maximumTravel = 0
        gestureStartedAt = nil
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