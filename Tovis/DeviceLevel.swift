// The device-level (horizon) signal for the AI photographer. A real camera app
// shows you when the phone is tilted off-level; inferring that from the subject's
// shoulders (the old PoseCoach branch) is unreliable. CoreMotion's gravity vector
// gives the true roll in the screen plane, which drives both the on-screen level
// line and the "straighten the camera" coaching.
import CoreMotion
import Foundation

/// Streams the device's roll — its rotation in the screen plane — for the level /
/// horizon indicator. Portrait-oriented: 0° = held upright, signed degrees as it
/// tilts left/right. Polled on the main run loop so there are no cross-actor hops.
@MainActor
final class DeviceLevelProvider {
    private let motion = CMMotionManager()
    private var timer: Timer?

    /// Called ~15×/s with the current roll in degrees (nil if motion is
    /// unavailable, e.g. the Simulator). Set before `start()`.
    var onUpdate: ((Double?) -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable else { onUpdate?(nil); return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates()
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let gravity = self.motion.deviceMotion?.gravity else { return }
                // Roll in the screen plane; 0 when the phone is held upright in
                // portrait, signed as it rolls left/right.
                let roll = atan2(gravity.x, -gravity.y) * 180 / .pi
                self.onUpdate?(roll)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }
}
