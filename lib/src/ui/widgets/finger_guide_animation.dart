import 'dart:math' as math;
import 'package:flutter/material.dart';

class FingerGuideAnimation extends StatefulWidget {
  const FingerGuideAnimation({super.key});

  @override
  State<FingerGuideAnimation> createState() => _FingerGuideAnimationState();
}

class _FingerGuideAnimationState extends State<FingerGuideAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _FingerGuidePainter(_controller.value),
          size: const Size(double.infinity, 250),
        );
      },
    );
  }
}

class _FingerGuidePainter extends CustomPainter {
  final double animationValue;
  _FingerGuidePainter(this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // Phone dimensions
    const phoneWidth = 120.0;
    const phoneHeight = 200.0;
    final phoneLeft = centerX - phoneWidth / 2;
    final phoneTop = centerY - phoneHeight / 2;
    final phoneRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(phoneLeft, phoneTop, phoneWidth, phoneHeight),
      const Radius.circular(16),
    );

    // Draw phone fill
    final phoneFill = Paint()..color = const Color(0xFFF0F0F0);
    canvas.drawRRect(phoneRect, phoneFill);

    // Draw phone border
    final phoneBorder = Paint()
      ..color = const Color(0xFFCCCCCC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(phoneRect, phoneBorder);

    // Camera lens position (top-left area of phone)
    final cameraX = phoneLeft + 28;
    final cameraY = phoneTop + 30;
    const cameraRadius = 8.0;

    // Flash position (next to camera)
    final flashX = cameraX + 22;
    final flashY = cameraY;
    const flashRadius = 6.0;

    // Draw camera lens
    final cameraPaint = Paint()..color = const Color(0xFF333333);
    canvas.drawCircle(Offset(cameraX, cameraY), cameraRadius, cameraPaint);
    // Camera lens inner ring
    final cameraRing = Paint()
      ..color = const Color(0xFF555555)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(Offset(cameraX, cameraY), 5, cameraRing);

    // Phase 2 glow effects (flash + pulse)
    final isPhase2 = animationValue >= 0.3 && animationValue < 0.8;
    double glowOpacity = 0.0;
    if (isPhase2) {
      glowOpacity = 1.0;
    } else if (animationValue >= 0.8) {
      // Fade out
      glowOpacity = 1.0 - Curves.easeIn.transform((animationValue - 0.8) / 0.2);
    }

    // Draw flash (with glow during phase 2)
    if (glowOpacity > 0) {
      final flashGlow = Paint()
        ..color = const Color(0xFFFFEE58).withOpacity(0.3 * glowOpacity);
      canvas.drawCircle(Offset(flashX, flashY), 14, flashGlow);
    }
    final flashColor = isPhase2
        ? Color.lerp(const Color(0xFFFFE082), const Color(0xFFFFF9C4), 0.5)!
        : const Color(0xFFFFE082);
    final flashPaint = Paint()..color = flashColor;
    canvas.drawCircle(Offset(flashX, flashY), flashRadius, flashPaint);

    // Finger position calculation
    final fingerRestX = cameraX + 8; // Centered over camera+flash area
    final fingerRestY = cameraY;
    final offScreenX = size.width + 50;
    final fingerX = _fingerX(animationValue, fingerRestX, offScreenX);

    // Finger dimensions
    const fingerWidth = 90.0;
    const fingerHeight = 120.0;

    // Draw pulse glow under finger during phase 2
    if (glowOpacity > 0 && animationValue >= 0.3) {
      final pulsePhase = (animationValue - 0.3) / 0.5;
      final pulseScale = 0.8 + 0.4 * math.sin(pulsePhase * math.pi * 4);
      final pulseRadius = 35.0 * pulseScale;
      final pulseGlow = Paint()
        ..color = Color.fromRGBO(229, 57, 53, 0.25 * glowOpacity);
      canvas.drawCircle(
        Offset(fingerRestX, fingerRestY),
        pulseRadius,
        pulseGlow,
      );
    }

    // Draw finger
    final fingerRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(fingerX, fingerRestY),
        width: fingerWidth,
        height: fingerHeight,
      ),
      const Radius.circular(45),
    );

    // Finger shadow
    final fingerShadow = Paint()
      ..color = Colors.black.withOpacity(0.15);
    canvas.drawRRect(
      fingerRect.shift(const Offset(2, 3)),
      fingerShadow,
    );

    // Finger fill
    final fingerPaint = Paint()..color = const Color(0xFFE8B89D);
    canvas.drawRRect(fingerRect, fingerPaint);

    // Finger highlight (lighter stripe)
    final highlightRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(fingerX - 10, fingerRestY - 5),
        width: 20,
        height: fingerHeight * 0.6,
      ),
      const Radius.circular(10),
    );
    final highlightPaint = Paint()
      ..color = const Color(0xFFF5CDB8).withOpacity(0.6);
    canvas.drawRRect(highlightRect, highlightPaint);

    // Draw heart during phase 2
    if (glowOpacity > 0 && animationValue >= 0.3 && animationValue < 0.8) {
      final pulsePhase = (animationValue - 0.3) / 0.5;
      final heartScale = 0.9 + 0.2 * math.sin(pulsePhase * math.pi * 4);
      _drawHeart(canvas, Offset(centerX, phoneTop + phoneHeight - 30),
          12.0 * heartScale, Color.fromRGBO(229, 57, 53, 0.8 * glowOpacity));
    }
  }

  double _fingerX(double t, double restX, double offScreenX) {
    if (t < 0.3) {
      final progress = Curves.easeOut.transform(t / 0.3);
      return offScreenX + (restX - offScreenX) * progress;
    } else if (t < 0.8) {
      return restX;
    } else {
      final progress = Curves.easeIn.transform((t - 0.8) / 0.2);
      return restX + (offScreenX - restX) * progress;
    }
  }

  void _drawHeart(Canvas canvas, Offset center, double size, Color color) {
    final path = Path();
    final x = center.dx;
    final y = center.dy;

    path.moveTo(x, y + size * 0.4);
    path.cubicTo(
      x - size, y - size * 0.2,
      x - size * 0.5, y - size,
      x, y - size * 0.4,
    );
    path.cubicTo(
      x + size * 0.5, y - size,
      x + size, y - size * 0.2,
      x, y + size * 0.4,
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FingerGuidePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}
