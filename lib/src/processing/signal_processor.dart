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
        return _extractRGBMeansFromYUV420(image);
      default:
        return (meanR: 200.0, meanG: 50.0, meanB: 50.0);
    }
  }

  /// Extract mean R, G, B from a YUV420 CameraImage using plane means and
  /// BT.601 conversion. Works for both planar (I420) and semi-planar
  /// (NV12/NV21) layouts by respecting each plane's pixelStride and rowStride.
  static ({double meanR, double meanG, double meanB}) _extractRGBMeansFromYUV420(
      CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    // Y plane — full resolution, one byte per pixel
    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final int yRowStride = yPlane.bytesPerRow;
    int ySum = 0;
    for (int row = 0; row < height; row++) {
      final int rowOffset = row * yRowStride;
      for (int col = 0; col < width; col++) {
        ySum += yBytes[rowOffset + col];
      }
    }
    final double meanY = ySum / (width * height);

    // U plane (Cb) — half resolution
    final uPlane = image.planes[1];
    final uBytes = uPlane.bytes;
    final int uPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uRowStride = uPlane.bytesPerRow;
    final int uvWidth = width ~/ 2;
    final int uvHeight = height ~/ 2;
    int uSum = 0;
    int uCount = 0;
    for (int row = 0; row < uvHeight; row++) {
      final int rowOffset = row * uRowStride;
      for (int col = 0; col < uvWidth; col++) {
        uSum += uBytes[rowOffset + col * uPixelStride];
        uCount++;
      }
    }
    final double meanU = uCount > 0 ? uSum / uCount : 128.0;

    // V plane (Cr) — half resolution
    final vPlane = image.planes[2];
    final vBytes = vPlane.bytes;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;
    final int vRowStride = vPlane.bytesPerRow;
    int vSum = 0;
    int vCount = 0;
    for (int row = 0; row < uvHeight; row++) {
      final int rowOffset = row * vRowStride;
      for (int col = 0; col < uvWidth; col++) {
        vSum += vBytes[rowOffset + col * vPixelStride];
        vCount++;
      }
    }
    final double meanV = vCount > 0 ? vSum / vCount : 128.0;

    // BT.601 YUV→RGB on the channel means
    final double r = (meanY + 1.402 * (meanV - 128)).clamp(0, 255).toDouble();
    final double g =
        (meanY - 0.344 * (meanU - 128) - 0.714 * (meanV - 128)).clamp(0, 255).toDouble();
    final double b = (meanY + 1.772 * (meanU - 128)).clamp(0, 255).toDouble();

    return (meanR: r, meanG: g, meanB: b);
  }

  /// Compute HSV Value (brightness) from RGB channel means.
  /// HSV Value = max(R, G, B). This is what HRV4Training uses
  /// as the PPG signal input (Altini and Amft, 2016).
  static double rgbToHsvValue(double meanR, double meanG, double meanB) {
    double v = meanR;
    if (meanG > v) v = meanG;
    if (meanB > v) v = meanB;
    return v;
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
