import AVFoundation
import Foundation

/// Uses the active rear camera light; it does not start a competing capture session.
@MainActor enum CaptureLight {
    private static var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back)
    }
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription:String? { "Фонарь недоступен на этом устройстве или временно отключён системой." }
    }
    static func toggle()throws->Bool {
        guard let camera=device, camera.hasTorch else { throw Failure.unavailable }
        let enable=camera.torchMode != .on
        guard !enable || camera.isTorchAvailable else { throw Failure.unavailable }
        try camera.lockForConfiguration();defer{camera.unlockForConfiguration()}
        if enable { try camera.setTorchModeOn(level:0.5) } else { camera.torchMode = .off }
        return camera.torchMode == .on
    }
    static func turnOff()throws {
        guard let camera=device, camera.hasTorch, camera.torchMode != .off else{return}
        // Turning off must still be attempted when the system reports the torch unavailable.
        try camera.lockForConfiguration();defer{camera.unlockForConfiguration()}
        camera.torchMode = .off
    }
}
