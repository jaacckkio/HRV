import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Processes raw camera data to extract PPG signal.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class SignalProcessor {
  const SignalProcessor();

  /// Extracts the mean Green channel intensity from a CameraImage.
  /// Green has the strongest PPG signal for fingertip contact with flash.
  double extractChannel(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _extractLuminanceFromYUV420(image);
      case ImageFormatGroup.bgra8888:
        return _extractGreenFromBGRA8888(image);
      default:
        throw UnsupportedError(
            'Unsupported image format: ${image.format.group}');
    }
  }

  /// YUV420 has no direct green channel — use luminance (Y) as fallback.
  double _extractLuminanceFromYUV420(CameraImage image) {
    final yPlane = image.planes[0];
    return _calculateMean(yPlane.bytes);
  }

  double _extractGreenFromBGRA8888(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final int length = bytes.length;

    int sum = 0;
    int count = 0;

    // BGRA8888: B=0, G=1, R=2, A=3
    for (int i = 1; i < length; i += 4) {
      sum += bytes[i];
      count++;
    }

    return count == 0 ? 0.0 : sum / count;
  }

  double _calculateMean(Uint8List bytes) {
    if (bytes.isEmpty) return 0.0;

    int sum = 0;
    for (final byte in bytes) {
      sum += byte;
    }
    return sum / bytes.length;
  }

  double applyMovingAverage(List<double> buffer) {
    if (buffer.isEmpty) return 0.0;

    double sum = 0.0;
    for (final val in buffer) {
      sum += val;
    }
    return sum / buffer.length;
  }

  /// Bandpass-like filter: SMA(short) - SMA(long)
  double simpleBandpassFilter(
      List<double> rawSignalWindow, int smoothingWindow) {
    if (rawSignalWindow.length < smoothingWindow) return 0.0;

    final int n = rawSignalWindow.length;
    final shortStart = n - smoothingWindow;
    final shortWindow = rawSignalWindow.sublist(shortStart);
    final smoothed = applyMovingAverage(shortWindow);
    final trendVal = applyMovingAverage(rawSignalWindow);

    return smoothed - trendVal;
  }
}
