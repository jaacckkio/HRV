package com.vagallybetter.vagal_hrv_camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.util.Log
import android.util.Range
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native Android camera control plugin that mirrors the iOS CameraControlPlugin.
 *
 * Handles method channel `vagal_hrv_camera/camera_control` with four methods:
 * - lockCameraSettings: Reports AE/AF/AWB capability via CameraCharacteristics
 * - unlockCameraSettings: Resets lock state
 * - setHighFrameRate: Queries camera capabilities for highest supported FPS
 * - setFrameRate: Queries camera capabilities for a specific FPS target
 *
 * Exposure and focus locking on Android is handled by the Dart layer using
 * the camera package's setExposureMode/setFocusMode APIs.
 * WB lock is reported as unsupported (requires CameraX interop not available here).
 * FPS ranges are enumerated and reported so the Dart layer knows device capabilities.
 */
class CameraControlPlugin private constructor(
    private val context: Context
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "CameraControlPlugin"
        private const val CHANNEL_NAME = "vagal_hrv_camera/camera_control"

        fun register(messenger: BinaryMessenger, context: Context) {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            val plugin = CameraControlPlugin(context)
            channel.setMethodCallHandler(plugin)
            Log.d(TAG, "Registered on channel $CHANNEL_NAME")
        }
    }

    private var wbLocked = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "lockCameraSettings" -> result.success(lockCameraSettings())
            "unlockCameraSettings" -> result.success(unlockCameraSettings())
            "setHighFrameRate" -> result.success(setHighFrameRate())
            "setFrameRate" -> {
                val fps = call.argument<Int>("fps") ?: 120
                result.success(setFrameRate(fps))
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Lock camera settings. On Android:
     * - AE (exposure) and AF (focus) locking is done by the Dart layer via the
     *   camera package's cross-platform API. We report device capability here.
     * - WB (white balance) lock requires CameraX interop which isn't available
     *   from this plugin context, so we report capability but don't lock.
     */
    private fun lockCameraSettings(): Map<String, Any?> {
        try {
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = findRearCameraId(cameraManager)
                ?: return mapOf(
                    "exposureLocked" to false,
                    "focusLocked" to false,
                    "whiteBalanceLocked" to false,
                    "error" to "Could not find rear camera"
                )

            val characteristics = cameraManager.getCameraCharacteristics(cameraId)

            // Check device capabilities
            val aeLockAvailable = characteristics.get(
                CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE
            ) ?: false
            val awbLockAvailable = characteristics.get(
                CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE
            ) ?: false

            // AF lock is supported if the device has at least one AF mode
            val afModes = characteristics.get(
                CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES
            ) ?: intArrayOf()
            val afLockAvailable = afModes.isNotEmpty()

            // WB lock requires CameraX Camera2Interop to set capture request options
            // on the active camera session, which the Flutter camera plugin owns.
            // Report as not locked; AE and AF are the critical locks for HRV measurement.
            Log.d(TAG, "lockCameraSettings: ae=$aeLockAvailable, af=$afLockAvailable, awbCapable=$awbLockAvailable (not applied)")

            return mapOf(
                "exposureLocked" to aeLockAvailable,
                "focusLocked" to afLockAvailable,
                "whiteBalanceLocked" to false,
                "error" to if (!awbLockAvailable) "Device does not support AWB lock" else "WB lock requires CameraX interop (not available)"
            )
        } catch (e: Exception) {
            Log.e(TAG, "lockCameraSettings exception", e)
            return mapOf(
                "exposureLocked" to false,
                "focusLocked" to false,
                "whiteBalanceLocked" to false,
                "error" to "Exception: ${e.message}"
            )
        }
    }

    /**
     * Unlock camera settings. AE/AF unlock is handled by the Dart layer.
     */
    private fun unlockCameraSettings(): Map<String, Any?> {
        wbLocked = false
        Log.d(TAG, "unlockCameraSettings (Dart layer handles AE/AF)")
        return mapOf(
            "success" to true,
            "error" to null
        )
    }

    /**
     * Request the highest supported frame rate on the rear camera.
     * Queries CameraCharacteristics for supported FPS ranges.
     * Preference: 120 → 60 → best available.
     */
    private fun setHighFrameRate(): Map<String, Any?> {
        try {
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = findRearCameraId(cameraManager)
                ?: return mapOf(
                    "requestedFps" to 0.0,
                    "error" to "Could not find rear camera"
                )

            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val fpsRanges = characteristics.get(
                CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
            ) ?: return mapOf(
                "requestedFps" to 0.0,
                "error" to "No FPS ranges available"
            )

            // Find the highest max FPS across all ranges
            val maxFps = fpsRanges.maxOfOrNull { it.upper } ?: 0
            Log.d(TAG, "Available FPS ranges: ${fpsRanges.joinToString()}, max=$maxFps")

            // Target: prefer 120, then 60, else best available
            val targetFps = when {
                maxFps >= 120 -> 120
                maxFps >= 60 -> 60
                maxFps > 0 -> maxFps
                else -> return mapOf(
                    "requestedFps" to 0.0,
                    "error" to "No supported frame rates found"
                )
            }

            return applyFpsRange(targetFps, fpsRanges)
        } catch (e: Exception) {
            Log.e(TAG, "setHighFrameRate exception", e)
            return mapOf(
                "requestedFps" to 0.0,
                "error" to "Exception: ${e.message}"
            )
        }
    }

    /**
     * Request a specific frame rate. Falls back to the highest supported rate
     * ≤ requested if the exact rate is unavailable.
     */
    private fun setFrameRate(fps: Int): Map<String, Any?> {
        try {
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = findRearCameraId(cameraManager)
                ?: return mapOf(
                    "requestedFps" to 0.0,
                    "error" to "Could not find rear camera"
                )

            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val fpsRanges = characteristics.get(
                CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
            ) ?: return mapOf(
                "requestedFps" to 0.0,
                "error" to "No FPS ranges available"
            )

            Log.d(TAG, "setFrameRate($fps): available ranges=${fpsRanges.joinToString()}")
            return applyFpsRange(fps, fpsRanges)
        } catch (e: Exception) {
            Log.e(TAG, "setFrameRate exception", e)
            return mapOf(
                "requestedFps" to 0.0,
                "error" to "Exception: ${e.message}"
            )
        }
    }

    /**
     * Find the best FPS range for the target and report it back.
     * The actual FPS setting is negotiated by the camera package based on device capabilities.
     */
    private fun applyFpsRange(
        targetFps: Int,
        fpsRanges: Array<Range<Int>>
    ): Map<String, Any?> {
        // Find a range that contains our target (target within [lower, upper])
        var bestRange = fpsRanges.firstOrNull { it.lower <= targetFps && it.upper >= targetFps }

        // Fallback: find the range with highest upper bound ≤ target
        var actualFps = targetFps
        if (bestRange == null) {
            bestRange = fpsRanges
                .filter { it.upper <= targetFps }
                .maxByOrNull { it.upper }

            if (bestRange != null) {
                actualFps = bestRange.upper
            } else {
                // Last resort: use the range with the lowest upper bound
                bestRange = fpsRanges.minByOrNull { it.upper }
                if (bestRange != null) {
                    actualFps = bestRange.upper
                } else {
                    return mapOf(
                        "requestedFps" to 0.0,
                        "error" to "No suitable FPS range found for $targetFps fps"
                    )
                }
            }
        }

        Log.d(TAG, "FPS: device supports up to $actualFps fps (target was $targetFps)")

        return mapOf(
            "requestedFps" to actualFps.toDouble(),
            "error" to null
        )
    }

    /**
     * Find the camera ID for the rear-facing camera.
     */
    private fun findRearCameraId(cameraManager: CameraManager): String? {
        try {
            for (id in cameraManager.cameraIdList) {
                val characteristics = cameraManager.getCameraCharacteristics(id)
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                if (facing == CameraMetadata.LENS_FACING_BACK) {
                    return id
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error finding rear camera: ${e.message}")
        }
        return null
    }
}
