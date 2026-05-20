import 'package:flutter/material.dart';

/// Lightweight waveform painter with optional peak markers.
class WaveformPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final List<int> peaks;

  WaveformPainter(this.data, this.color, [this.peaks = const []]);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final w = size.width, h = size.height, len = data.length;

    double minV = data.reduce((a, b) => a < b ? a : b);
    double maxV = data.reduce((a, b) => a > b ? a : b);
    final range = maxV - minV;
    final pad = range * 0.1;
    minV -= pad;
    maxV += pad;
    final scaleY = (maxV == minV) ? 1.0 : h / (maxV - minV);
    final stepX = len > 1 ? w / (len - 1) : w;

    for (int i = 0; i < len; i++) {
      final x = i * stepX;
      final y = h - ((data[i] - minV) * scaleY);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);

    if (peaks.isNotEmpty) {
      final peakPaint = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.fill;
      for (final idx in peaks) {
        if (idx >= 0 && idx < len) {
          canvas.drawCircle(
            Offset(idx * stepX, h - ((data[idx] - minV) * scaleY)),
            4,
            peakPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.data != data || old.peaks != peaks || old.color != color;
}
