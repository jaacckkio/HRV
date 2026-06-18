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

  /// Request the highest safe supported frame rate on the rear camera.
  /// Returns the FPS that was set on the device, or 0 on failure.
  /// Logs any error but never throws.
  static Future<double> setHighFrameRate() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'setHighFrameRate');
      if (result == null) return 0;
      final error = result['error'];
      if (error != null && error is String) {
        // ignore: avoid_print
        print('setHighFrameRate error: $error');
      }
      return (result['requestedFps'] as num?)?.toDouble() ?? 0;
    } catch (e) {
      // ignore: avoid_print
      print('setHighFrameRate exception: $e');
      return 0;
    }
  }

  /// Request a specific frame rate (30, 60, or 120).
  /// Returns the FPS that was actually set on the device, or 0 on failure.
  static Future<double> setFrameRate(int fps) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'setFrameRate', {'fps': fps});
      if (result == null) return 0;
      final error = result['error'];
      if (error != null && error is String) {
        // ignore: avoid_print
        print('setFrameRate error: $error');
      }
      return (result['requestedFps'] as num?)?.toDouble() ?? 0;
    } catch (e) {
      // ignore: avoid_print
      print('setFrameRate exception: $e');
      return 0;
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
