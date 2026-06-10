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
      duration: const Duration(milliseconds: 6000),
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

// Phase boundaries (fraction of 6s total)
const double _kPhase1End = 0.20; // Target pulses: 0–1.2s
const double _kPhase2End = 0.333; // Approach: 1.2–2.0s
const double _kPhase3End = 0.433; // Press: 2.0–2.6s
const double _kPhase4End = 0.85; // Measuring: 2.6–5.1s
// Lift: 5.1–6.0s (remainder to 1.0)

// Colors
const Color _kTeal = Color(0xFF06A3B7);
const Color _kSkinBase = Color(0xFFE0A583);
const Color _kSkinLight = Color(0xFFEFC4AA);
const Color _kNailColor = Color(0xFFF3D9CA);
const Color _kPhoneFill = Color(0xFFF0F0F0);
const Color _kPhoneBorder = Color(0xFFCCCCCC);
const Color _kLensDark = Color(0xFF2A2A2A);
const Color _kLensMid = Color(0xFF484848);
const Color _kFlashYellow = Color(0xFFFFE082);
const Color _kRedGlow = Color(0xFFE53935);

class _FingerGuidePainter extends CustomPainter {
  final double t; // 0..1 over 6s
  _FingerGuidePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Phone
    const pw = 110.0;
    const ph = 185.0;
    final pl = cx - pw / 2;
    final pt = cy - ph / 2;

    _drawPhone(canvas, pl, pt, pw, ph);

    // Camera + flash in top-left of phone back
    final camX = pl + 28.0;
    final camY = pt + 30.0;
    const camR = 8.0;
    final flashX = camX + 22.0;
    final flashY = camY;
    const flashR = 5.0;

    // Target centre (midpoint between camera and flash)
    final targetX = (camX + flashX) / 2;
    final targetY = camY;

    // --- Phase 1: pulsing teal target ring ---
    if (t < _kPhase2End) {
      double ringOpacity;
      if (t < _kPhase1End) {
        // Two pulses across 0.0–0.20
        final pt1 = t / _kPhase1End; // 0..1
        final pulse = math.sin(pt1 * math.pi * 2); // two full sine cycles
        ringOpacity = 0.25 + 0.35 * pulse.abs();
      } else {
        // Fade out during approach
        final ap = (t - _kPhase1End) / (_kPhase2End - _kPhase1End);
        ringOpacity = 0.25 * (1.0 - ap);
      }

      final ringPaint = Paint()
        ..color = _kTeal.withOpacity(ringOpacity.clamp(0.0, 1.0))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      final baseRadius = 22.0;
      double expand = 0.0;
      if (t < _kPhase1End) {
        final pt1 = t / _kPhase1End;
        expand = 3.0 * math.sin(pt1 * math.pi * 2).abs();
      }
      canvas.drawCircle(
          Offset(targetX, targetY), baseRadius + expand, ringPaint);
    }

    // Draw camera lens
    canvas.drawCircle(
        Offset(camX, camY), camR, Paint()..color = _kLensDark);
    canvas.drawCircle(
      Offset(camX, camY),
      5.0,
      Paint()
        ..color = _kLensMid
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Draw flash
    canvas.drawCircle(
        Offset(flashX, flashY), flashR, Paint()..color = _kFlashYellow);

    // --- Finger ---
    // Finger geometry: horizontal, long axis pointing left-right, tip pointing left
    const fingerLen = 80.0;
    const fingerWid = 36.0;
    const angle = -math.pi / 2; // horizontal: long axis left-right, tip left

    // Compute finger centre position based on phase
    final restX = targetX;
    final restY = targetY;
    final offX = size.width + 60.0;
    final offY = targetY; // approach horizontally, same Y

    double fingerX, fingerY, fingerOpacity = 1.0, fingerScale = 1.0;
    bool showGlow = false;
    double glowIntensity = 0.0;
    bool showHeart = false;
    double heartScale = 1.0;

    if (t < _kPhase1End) {
      // Phase 1: finger offscreen to the right
      fingerX = offX;
      fingerY = offY;
      fingerOpacity = 0.0;
    } else if (t < _kPhase2End) {
      // Phase 2: approach horizontally from the right
      final p = Curves.easeOut
          .transform((t - _kPhase1End) / (_kPhase2End - _kPhase1End));
      fingerX = offX + (restX - offX) * p;
      fingerY = restY;
      fingerOpacity = p.clamp(0.0, 1.0);
    } else if (t < _kPhase3End) {
      // Phase 3: press / squish
      final p = (t - _kPhase2End) / (_kPhase3End - _kPhase2End);
      fingerX = restX;
      fingerY = restY;
      // Squish: scale down to 95% at midpoint, back to 100%
      final squish = math.sin(p * math.pi);
      fingerScale = 1.0 - 0.05 * squish;
    } else if (t < _kPhase4End) {
      // Phase 4: measuring
      fingerX = restX;
      fingerY = restY;
      showGlow = true;

      // Heartbeat rhythm: ~70bpm = period 0.857s = 0.143 of 6s
      // In the measuring window we have (0.85-0.433)*6 = 2.5s, ~3 beats
      final measT = (t - _kPhase3End) / (_kPhase4End - _kPhase3End);
      final beatPeriod = 0.857 / 6.0; // one beat in normalised time
      final beatPhase = ((t - _kPhase3End) % beatPeriod) / beatPeriod;
      // Asymmetric pulse: quick rise (0–0.25), slower fall (0.25–1.0)
      if (beatPhase < 0.25) {
        glowIntensity = Curves.easeOut.transform(beatPhase / 0.25);
      } else {
        glowIntensity =
            1.0 - Curves.easeIn.transform((beatPhase - 0.25) / 0.75);
      }

      // Heart appears after first beat completes
      if (measT > 0.15) {
        showHeart = true;
        heartScale = 0.85 + 0.3 * glowIntensity;
      }
    } else {
      // Lift / fade out — retreat horizontally to the right
      final p =
          Curves.easeIn.transform((t - _kPhase4End) / (1.0 - _kPhase4End));
      fingerX = restX + (offX - restX) * p;
      fingerY = restY;
      fingerOpacity = (1.0 - p).clamp(0.0, 1.0);
    }

    if (fingerOpacity <= 0.001) return;

    // --- Draw red glow under finger ---
    if (showGlow) {
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            _kRedGlow.withOpacity(0.45 * glowIntensity),
            _kRedGlow.withOpacity(0.15 * glowIntensity),
            _kRedGlow.withOpacity(0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(
            center: Offset(fingerX, fingerY), radius: 28));
      canvas.drawCircle(Offset(fingerX, fingerY), 28, glowPaint);
    }

    // --- Draw finger shadow ---
    canvas.save();
    canvas.translate(fingerX + 2, fingerY + 3);
    canvas.rotate(angle);
    canvas.scale(fingerScale);
    final shadowRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset.zero, width: fingerWid, height: fingerLen),
      Radius.circular(fingerWid / 2),
    );
    canvas.drawRRect(
      shadowRRect,
      Paint()..color = Colors.black.withOpacity(0.12 * fingerOpacity),
    );
    canvas.restore();

    // --- Draw finger body ---
    canvas.save();
    canvas.translate(fingerX, fingerY);
    canvas.rotate(angle);
    canvas.scale(fingerScale);

    final bodyRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset.zero, width: fingerWid, height: fingerLen),
      Radius.circular(fingerWid / 2),
    );

    // Skin fill — warm red tint when glowing
    Color skinColor = _kSkinBase;
    if (showGlow) {
      skinColor =
          Color.lerp(_kSkinBase, const Color(0xFFD4806A), glowIntensity * 0.6)!;
    }
    canvas.drawRRect(
      bodyRRect,
      Paint()..color = skinColor.withOpacity(fingerOpacity),
    );

    // Subtle highlight along top edge (appears as upper side when horizontal)
    final highlightRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: const Offset(-6, 0), width: 10, height: fingerLen * 0.5),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      highlightRRect,
      Paint()..color = _kSkinLight.withOpacity(0.45 * fingerOpacity),
    );

    // Nail near the tip — visible rounded rectangle
    final nailRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -fingerLen / 2 + 14),
        width: fingerWid * 0.48,
        height: 16,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      nailRRect,
      Paint()..color = _kNailColor.withOpacity(0.75 * fingerOpacity),
    );
    // Nail border for definition
    canvas.drawRRect(
      nailRRect,
      Paint()
        ..color = const Color(0xFFD4B5A0).withOpacity(0.4 * fingerOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    canvas.restore();

    // --- Heart icon at bottom-centre of phone during measuring ---
    if (showHeart && fingerOpacity > 0.5) {
      final heartX = cx;
      final heartY = pt + ph - 25;
      _drawHeart(
        canvas,
        Offset(heartX, heartY),
        8.0 * heartScale,
        _kRedGlow.withOpacity(0.85 * fingerOpacity),
      );
    }
  }

  void _drawPhone(Canvas canvas, double l, double t, double w, double h) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(l, t, w, h),
      const Radius.circular(14),
    );
    canvas.drawRRect(rect, Paint()..color = _kPhoneFill);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = _kPhoneBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawHeart(Canvas canvas, Offset center, double size, Color color) {
    final path = Path();
    final x = center.dx;
    final y = center.dy;
    path.moveTo(x, y + size * 0.4);
    path.cubicTo(
        x - size, y - size * 0.2, x - size * 0.5, y - size, x, y - size * 0.4);
    path.cubicTo(
        x + size * 0.5, y - size, x + size, y - size * 0.2, x, y + size * 0.4);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _FingerGuidePainter old) =>
      old.t != t;
}
