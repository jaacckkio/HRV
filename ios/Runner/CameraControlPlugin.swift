import Flutter
import AVFoundation

/// Platform channel handler for locking/unlocking AVFoundation camera settings.
/// Acquires the rear wide-angle camera device directly (the same physical device
/// the Flutter camera package uses) and locks exposure, focus, and white balance
/// so the only brightness variation is the true PPG pulse signal.
///
/// Assumption: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
/// position: .back) returns the same device instance the camera package is using,
/// because iOS shares device state. If locking via this path does not affect the
/// running capture session, we will need to reach into the session directly.
class CameraControlPlugin {
    static let channelName = "vagal_hrv_camera/camera_control"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = CameraControlPlugin()
        channel.setMethodCallHandler(instance.handle)
    }

    /// Also supports registration from AppDelegate (non-plugin registrar path).
    static func register(withMessenger messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        let instance = CameraControlPlugin()
        channel.setMethodCallHandler(instance.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "lockCameraSettings":
            result(lockCameraSettings())
        case "unlockCameraSettings":
            result(unlockCameraSettings())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func lockCameraSettings() -> [String: Any] {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            return [
                "exposureLocked": false,
                "focusLocked": false,
                "whiteBalanceLocked": false,
                "error": "Could not acquire rear camera device"
            ]
        }

        do {
            try device.lockForConfiguration()
        } catch {
            return [
                "exposureLocked": false,
                "focusLocked": false,
                "whiteBalanceLocked": false,
                "error": "lockForConfiguration failed: \(error.localizedDescription)"
            ]
        }

        var exposureLocked = false
        var focusLocked = false
        var whiteBalanceLocked = false

        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
            exposureLocked = true
        }

        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
            focusLocked = true
        }

        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
            whiteBalanceLocked = true
        }

        // Do not disturb torch state — leave it as-is (camera package manages torch)

        device.unlockForConfiguration()

        return [
            "exposureLocked": exposureLocked,
            "focusLocked": focusLocked,
            "whiteBalanceLocked": whiteBalanceLocked
        ]
    }

    private func unlockCameraSettings() -> [String: Any] {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            return [
                "success": false,
                "error": "Could not acquire rear camera device"
            ]
        }

        do {
            try device.lockForConfiguration()
        } catch {
            return [
                "success": false,
                "error": "lockForConfiguration failed: \(error.localizedDescription)"
            ]
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        device.unlockForConfiguration()

        return ["success": true]
    }
}
