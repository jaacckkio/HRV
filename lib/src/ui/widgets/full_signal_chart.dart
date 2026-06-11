import 'package:flutter/material.dart';

/// DEV TOOLING — scrollable full-signal chart with peak markers.
/// Renders the entire recording's filtered signal (not a rolling window)
/// so every detected peak can be visually inspected.
class FullSignalChart extends StatelessWidget {
  final List<double> signal;
  final List<int> peakIndices;
  final double fps;
  final double pixelsPerSecond;

  const FullSignalChart({
    super.key,
    required this.signal,
    required this.peakIndices,
    required this.fps,
    this.pixelsPerSecond = 100,
  });

  @override
  Widget build(BuildContext context) {
    if (signal.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('No signal data', style: TextStyle(color: Colors.grey))),
      );
    }

    final durationSec = signal.length / fps;
    final totalWidth = durationSec * pixelsPerSecond;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Full Signal — ${durationSec.toStringAsFixed(1)}s, '
          '${signal.length} samples, ${peakIndices.length} peaks',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 140,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth.clamp(300, double.infinity),
              height: 140,
              child: CustomPaint(
                painter: _FullSignalPainter(
                  signal: signal,
                  peakIndices: peakIndices,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FullSignalPainter extends CustomPainter {
  final List<double> signal;
  final List<int> peakIndices;

  _FullSignalPainter({required this.signal, required this.peakIndices});

  @override
  void paint(Canvas canvas, Size size) {
    if (signal.isEmpty) return;

    final w = size.width;
    final h = size.height;
    final len = signal.length;

    // Compute scale
    double minV = signal[0], maxV = signal[0];
    for (final v in signal) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final range = maxV - minV;
    final pad = range * 0.1;
    minV -= pad;
    maxV += pad;
    final scaleY = (maxV == minV) ? 1.0 : h / (maxV - minV);
    final stepX = len > 1 ? w / (len - 1) : w;

    // Draw waveform
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    for (int i = 0; i < len; i++) {
      final x = i * stepX;
      final y = h - ((signal[i] - minV) * scaleY);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);

    // Draw peak markers
    if (peakIndices.isNotEmpty) {
      final peakPaint = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.fill;

      for (final idx in peakIndices) {
        if (idx >= 0 && idx < len) {
          canvas.drawCircle(
            Offset(idx * stepX, h - ((signal[idx] - minV) * scaleY)),
            3,
            peakPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FullSignalPainter old) =>
      old.signal != signal || old.peakIndices != peakIndices;
}
