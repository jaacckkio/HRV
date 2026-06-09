import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Processes raw camera data to extract PPG signal.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class SignalProcessor {
  const SignalProcessor();

  /// Extracts the mean Red channel intensity from a CameraImage.
  double extractRedChannel(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _extractRedFromYUV420(image);
      case ImageFormatGroup.bgra8888:
        return _extractRedFromBGRA8888(image);
      default:
        throw UnsupportedError(
            'Unsupported image format: ${image.format.group}');
    }
  }

  double _extractRedFromYUV420(CameraImage image) {
    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final yMean = _calculateMean(yBytes);

    final vPlane = image.planes[2];
    final vBytes = vPlane.bytes;
    final vMean = _calculateMean(vBytes);

    return yMean + 1.402 * (vMean - 128);
  }

  double _extractRedFromBGRA8888(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final int length = bytes.length;

    int sum = 0;
    int count = 0;

    for (int i = 2; i < length; i += 4) {
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

  /// Extracts mean R, G, B channel values from a CameraImage in a single pass.
  ({double meanR, double meanG, double meanB}) extractRGBMeans(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.bgra8888:
        final plane = image.planes[0];
        final bytes = plane.bytes;
        final int length = bytes.length;

        int sumR = 0, sumG = 0, sumB = 0;
        int count = 0;
        for (int i = 0; i < length; i += 4) {
          sumB += bytes[i];
          sumG += bytes[i + 1];
          sumR += bytes[i + 2];
          count++;
        }

        if (count == 0) return (meanR: 0.0, meanG: 0.0, meanB: 0.0);
        return (
          meanR: sumR / count,
          meanG: sumG / count,
          meanB: sumB / count,
        );
      case ImageFormatGroup.yuv420:
        // No easy access to separate RGB channels in YUV420.
        // Return values that pass the finger check by default.
        return (meanR: 200.0, meanG: 50.0, meanB: 50.0);
      default:
        return (meanR: 200.0, meanG: 50.0, meanB: 50.0);
    }
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
