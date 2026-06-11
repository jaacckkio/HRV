import 'package:flutter/services.dart';

/// Thin wrapper around the native iOS platform channel for locking/unlocking
/// AVFoundation camera settings (exposure, focus, white balance).
class CameraControl {
  static const _channel = MethodChannel('vagal_hrv_camera/camera_control');

  /// Lock exposure, focus, and white balance at their current values.
  /// Returns which locks succeeded.
  static Future<CameraLockResult> lockCameraSettings() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'lockCameraSettings');
      if (result == null) {
        return const CameraLockResult(
          exposureLocked: false,
          focusLocked: false,
          whiteBalanceLocked: false,
          error: 'Null response from platform channel',
        );
      }
      return CameraLockResult(
        exposureLocked: result['exposureLocked'] as bool? ?? false,
        focusLocked: result['focusLocked'] as bool? ?? false,
        whiteBalanceLocked: result['whiteBalanceLocked'] as bool? ?? false,
        error: result['error'] as String?,
      );
    } on PlatformException catch (e) {
      return CameraLockResult(
        exposureLocked: false,
        focusLocked: false,
        whiteBalanceLocked: false,
        error: 'PlatformException: ${e.message}',
      );
    } on MissingPluginException {
      return const CameraLockResult(
        exposureLocked: false,
        focusLocked: false,
        whiteBalanceLocked: false,
        error: 'Plugin not registered (non-iOS platform?)',
      );
    }
  }

  /// Unlock camera settings back to continuous auto modes.
  static Future<void> unlockCameraSettings() async {
    try {
      await _channel.invokeMethod('unlockCameraSettings');
    } catch (_) {
      // Best-effort unlock — don't crash if it fails
    }
  }
}

/// Result of a camera lock attempt.
class CameraLockResult {
  final bool exposureLocked;
  final bool focusLocked;
  final bool whiteBalanceLocked;
  final String? error;

  const CameraLockResult({
    required this.exposureLocked,
    required this.focusLocked,
    required this.whiteBalanceLocked,
    this.error,
  });

  bool get anyLocked => exposureLocked || focusLocked || whiteBalanceLocked;
}
