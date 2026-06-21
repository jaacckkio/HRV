import 'package:flutter/material.dart';

/// Lightweight waveform painter with optional peak markers.
///
/// [skipLeading] omits the first N samples from both drawing and y-axis
/// scaling, which hides the Butterworth filter startup transient.
/// Robust y-bounds use 2nd/98th percentile so a single spike can't
/// dominate the scale.
class WaveformPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final List<int> peaks;
  final int skipLeading;

  WaveformPainter(this.data, this.color,
      [this.peaks = const [], this.skipLeading = 0]);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final start = skipLeading.clamp(0, data.length - 1);
    final visibleLen = data.length - start;
    if (visibleLen < 2) return;

    final w = size.width, h = size.height;

    // Robust y-bounds: 2nd / 98th percentile of visible window
    final sorted = <double>[];
    for (int i = start; i < data.length; i++) {
      sorted.add(data[i]);
    }
    sorted.sort();
    final p2 = sorted[(sorted.length * 0.02).floor()];
    final p98 = sorted[((sorted.length * 0.98).floor()).clamp(0, sorted.length - 1)];
    double minV = p2;
    double maxV = p98;
    if (maxV <= minV) {
      minV = sorted.first;
      maxV = sorted.last;
    }
    final range = maxV - minV;
    final pad = range * 0.1;
    minV -= pad;
    maxV += pad;
    final scaleY = (maxV == minV) ? 1.0 : h / (maxV - minV);
    final stepX = visibleLen > 1 ? w / (visibleLen - 1) : w;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();

    for (int i = 0; i < visibleLen; i++) {
      final x = i * stepX;
      final val = data[start + i].clamp(minV, maxV);
      final y = h - ((val - minV) * scaleY);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);

    if (peaks.isNotEmpty) {
      final peakPaint = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.fill;
      for (final idx in peaks) {
        final visIdx = idx - start;
        if (visIdx >= 0 && visIdx < visibleLen) {
          final val = data[idx].clamp(minV, maxV);
          canvas.drawCircle(
            Offset(visIdx * stepX, h - ((val - minV) * scaleY)),
            4,
            peakPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.data != data ||
      old.peaks != peaks ||
      old.color != color ||
      old.skipLeading != skipLeading;
}
