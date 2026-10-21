import Combine
import CoreMotion
import Foundation

@MainActor
final class TiltRemoteController: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    var onCommand: ((RemoteCommand) -> Void)?
    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }
    var canCalibrate: Bool { latestSample != nil }

    @Published private(set) var hasCenterCalibration = false
    @Published private(set) var centerValue = "Not set"
    @Published private(set) var currentValue = "Waiting for motion"
    @Published private(set) var detectedDirection = "Center"
    @Published private(set) var motionError: String?
    @Published private(set) var hasMotionSample = false
    @Published private(set) var isFlat = true

    var isCalibrated: Bool { hasCenterCalibration }

    private let motionManager = CMMotionManager()
    private var latestSample: MotionSample?
    private var centerSample: MotionSample?
    private var lastCommand: RemoteCommand?
    private var lastSentAt = 0.0

    func calibrateCenter() {
        centerSample = latestSample
        hasCenterCalibration = centerSample != nil
        centerValue = formatted(centerSample)
        detectedDirection = "Center"
        lastCommand = nil
    }

    func resetCalibration() {
        centerSample = nil
        hasCenterCalibration = false
        centerValue = "Not set"
        detectedDirection = "Center"
        lastCommand = nil
    }

    private func start() {
        guard motionManager.isDeviceMotionAvailable else {
            isEnabled = false
            return
        }

        resetCalibration()
        latestSample = nil
        motionError = nil
        hasMotionSample = false
        isFlat = true
        lastCommand = nil
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                if let error {
                    self.motionError = error.localizedDescription
                    self.isEnabled = false
                    return
                }
                guard let motion else { return }
                self.hasMotionSample = true
                self.handle(motion)
            }
        }
    }

    private func stop() {
        motionManager.stopDeviceMotionUpdates()
        resetCalibration()
        latestSample = nil
        currentValue = "Waiting for motion"
        motionError = nil
        hasMotionSample = false
        isFlat = true
        lastCommand = nil
    }

    private func handle(_ motion: CMDeviceMotion) {
        let sample = MotionSample(
            x: motion.gravity.x,
            y: motion.gravity.y,
            z: motion.gravity.z,
            yaw: motion.attitude.yaw
        )
        latestSample = sample
        currentValue = formatted(sample)
        isFlat = abs(sample.z) >= 0.75

        guard let centerSample else {
            calibrateCenter()
            return
        }

        let horizontalPosition = normalizedAngle(sample.yaw - centerSample.yaw) / (.pi / 2)
        let verticalPosition = sample.y - centerSample.y
        let horizontalMagnitude = abs(horizontalPosition)
        let verticalMagnitude = abs(verticalPosition)
        let activationThreshold = 0.18
        let distanceFromCenter = max(horizontalMagnitude, verticalMagnitude)

        guard distanceFromCenter >= activationThreshold else {
            detectedDirection = "Center"
            lastCommand = nil
            return
        }

        let command: RemoteCommand
        if horizontalMagnitude >= verticalMagnitude {
            command = horizontalPosition >= 0 ? .left : .right
        } else {
            command = verticalPosition >= 0 ? .down : .up
        }

        detectedDirection = command.rawValue
        let intensity = min(1, max(0, (distanceFromCenter - activationThreshold) / (1 - activationThreshold)))
        let repeatInterval = 0.48 - intensity * 0.38
        let now = Date.timeIntervalSinceReferenceDate
        let isNewDirection = lastCommand?.rawValue != command.rawValue
        guard isNewDirection || now - lastSentAt >= repeatInterval else { return }

        lastCommand = command
        lastSentAt = now
        onCommand?(command)
    }

    private func formatted(_ sample: MotionSample?) -> String {
        guard let sample else { return "Not set" }
        return String(format: "x %.2f / y %.2f / z %.2f / yaw %.2f", sample.x, sample.y, sample.z, sample.yaw)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > .pi {
            normalized -= 2 * .pi
        }
        while normalized < -.pi {
            normalized += 2 * .pi
        }
        return normalized
    }

    private struct MotionSample {
        let x: Double
        let y: Double
        let z: Double
        let yaw: Double
    }
}
