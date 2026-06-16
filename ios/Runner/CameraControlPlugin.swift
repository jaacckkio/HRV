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
        case "setHighFrameRate":
            result(setHighFrameRate())
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

    /// Request the highest safe supported frame rate on the rear camera.
    ///
    /// Iterates device.formats, finds the format whose
    /// videoSupportedFrameRateRanges has the highest maxFrameRate
    /// (preferring 120, else 60, else best available), sets
    /// device.activeFormat FIRST, THEN activeVideoMin/MaxFrameDuration.
    ///
    /// SAFETY (Apple docs): activeFormat must be set BEFORE frame duration,
    /// and the chosen format must actually support the target rate —
    /// otherwise the app crashes. Every step is guarded; on failure the
    /// camera stays at its current (default) settings.
    private func setHighFrameRate() -> [String: Any] {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            return ["requestedFps": 0.0, "error": "Could not acquire rear camera device"]
        }

        // Scan all formats for the highest supported frame rate
        var bestFormat: AVCaptureDevice.Format? = nil
        var bestMaxFps: Float64 = 0

        for format in device.formats {
            let mediaType = CMFormatDescriptionGetMediaType(format.formatDescription)
            guard mediaType == kCMMediaType_Video else { continue }

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > bestMaxFps {
                    bestMaxFps = range.maxFrameRate
                    bestFormat = format
                }
            }
        }

        // Target: prefer 120, then 60, else best available
        let targetFps: Float64
        if bestMaxFps >= 120 {
            targetFps = 120
        } else if bestMaxFps >= 60 {
            targetFps = 60
        } else if bestMaxFps > 0 {
            targetFps = bestMaxFps
        } else {
            return ["requestedFps": 0.0, "error": "No supported frame rates found"]
        }

        guard let chosenFormat = bestFormat else {
            return ["requestedFps": 0.0, "error": "No suitable format found"]
        }

        // Verify the chosen format actually supports the target rate
        var supportsTarget = false
        for range in chosenFormat.videoSupportedFrameRateRanges {
            if range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps {
                supportsTarget = true
                break
            }
        }
        if !supportsTarget {
            return [
                "requestedFps": 0.0,
                "error": "Best format does not support \(targetFps) fps"
            ]
        }

        do {
            try device.lockForConfiguration()
            // CRITICAL: set activeFormat BEFORE frame duration (Apple docs).
            device.activeFormat = chosenFormat
            device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(targetFps))
            device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(targetFps))
            device.unlockForConfiguration()

            let dims = CMVideoFormatDescriptionGetDimensions(chosenFormat.formatDescription)
            NSLog("CameraControlPlugin: set format \(dims.width)x\(dims.height) @ \(targetFps) fps")

            return ["requestedFps": targetFps, "error": NSNull()]
        } catch {
            return [
                "requestedFps": 0.0,
                "error": "lockForConfiguration failed: \(error.localizedDescription)"
            ]
        }
    }
}
