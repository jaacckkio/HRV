import 'dart:math' as math;
import 'package:flutter/material.dart';

// --- Vagally Better palette ---
const Color _kTeal = Color(0xFF06A3B7);
const Color _kSkinBase = Color(0xFFD4A886);
const Color _kSkinHighlight = Color(0xFFE8C4A8);
const Color _kNailColor = Color(0xFFF0D6C4);
const Color _kPhoneFill = Color(0xFFF2F2F2);
const Color _kPhoneBorder = Color(0xFFD1D5DB);
const Color _kLensDark = Color(0xFF1A1A1A);
const Color _kLensRing = Color(0xFF3A3A3A);
const Color _kFlashOff = Color(0xFFD0D0D0);
const Color _kGlowWarm = Color(0xFFFFF8E1);
const Color _kHeartColor = Color(0xFFE57373);

class FingerGuideAnimation extends StatefulWidget {
  const FingerGuideAnimation({super.key});

  @override
  State<FingerGuideAnimation> createState() => _FingerGuideAnimationState();
}

class _FingerGuideAnimationState extends State<FingerGuideAnimation>
    with TickerProviderStateMixin {
  late AnimationController _glowController;
  late AnimationController _heartController;

  @override
  void initState() {
    super.initState();

    // Flash glow: blooms on once over ~700ms then holds at 1.0
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    // Heart: gentle continuous beat loop (~1s period)
    _heartController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    _heartController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_glowController, _heartController]),
      builder: (context, child) {
        // Glow: ease-out bloom from 0→1, then stays at 1
        final glowValue = Curves.easeOut.transform(_glowController.value);

        // Heart: gentle scale pulse — ease in-out sine wave, 5–10% scale
        final heartPhase = _heartController.value;
        final heartScale =
            1.0 + 0.08 * math.sin(heartPhase * math.pi * 2).abs();

        return CustomPaint(
          painter: _HelpIllustrationPainter(
            glowIntensity: glowValue,
            heartScale: heartScale,
          ),
          size: const Size(double.infinity, 250),
        );
      },
    );
  }
}

class _HelpIllustrationPainter extends CustomPainter {
  final double glowIntensity; // 0→1, stays at 1 after bloom
  final double heartScale; // ~1.0 ± 0.08

  _HelpIllustrationPainter({
    required this.glowIntensity,
    required this.heartScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42; // phone centred a bit above middle

    // --- Phone body (rear view) ---
    const pw = 115.0;
    const ph = 190.0;
    final phoneRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: pw, height: ph),
      const Radius.circular(18),
    );
    // Subtle shadow
    canvas.drawRRect(
      phoneRect.shift(const Offset(0, 3)),
      Paint()..color = Colors.black.withOpacity(0.06),
    );
    canvas.drawRRect(phoneRect, Paint()..color = _kPhoneFill);
    canvas.drawRRect(
      phoneRect,
      Paint()
        ..color = _kPhoneBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // --- Camera module area (top-left of phone back) ---
    final camX = cx - pw / 2 + 32;
    final camY = cy - ph / 2 + 34;
    const camR = 9.0;
    final flashX = camX + 24.0;
    final flashY = camY - 1.0;
    const flashR = 5.5;

    // Target centre (between camera and flash — where finger rests)
    final targetX = (camX + flashX) / 2;
    final targetY = (camY + flashY) / 2;

    // --- Flash glow (blooms once and stays lit) ---
    if (glowIntensity > 0) {
      // Outer soft glow — larger, more diffuse
      for (int i = 3; i >= 0; i--) {
        final r = 18.0 + i * 10.0;
        final opacity = 0.08 * glowIntensity * (1.0 - i * 0.2);
        canvas.drawCircle(
          Offset(targetX, targetY),
          r,
          Paint()..color = _kGlowWarm.withOpacity(opacity.clamp(0.0, 1.0)),
        );
      }
      // Inner warm glow centred on flash
      canvas.drawCircle(
        Offset(flashX, flashY),
        12.0,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withOpacity(0.55 * glowIntensity),
              _kGlowWarm.withOpacity(0.3 * glowIntensity),
              _kGlowWarm.withOpacity(0.0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(
              Rect.fromCircle(center: Offset(flashX, flashY), radius: 12)),
      );
    }

    // --- Camera lens ---
    // Outer ring
    canvas.drawCircle(
      Offset(camX, camY),
      camR + 2,
      Paint()
        ..color = _kLensRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // Lens body
    canvas.drawCircle(
      Offset(camX, camY),
      camR,
      Paint()..color = _kLensDark,
    );
    // Lens reflection
    canvas.drawCircle(
      Offset(camX - 2.5, camY - 2.5),
      2.5,
      Paint()..color = Colors.white.withOpacity(0.18),
    );

    // --- Flash LED ---
    canvas.drawCircle(
      Offset(flashX, flashY),
      flashR,
      Paint()
        ..color = glowIntensity > 0
            ? Color.lerp(_kFlashOff, Colors.white, glowIntensity)!
            : _kFlashOff,
    );
    canvas.drawCircle(
      Offset(flashX, flashY),
      flashR,
      Paint()
        ..color = _kPhoneBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    // --- Fingertip (static, resting over lens/flash area) ---
    // Angled slightly for a natural finger-pressing-down look
    const fingerLen = 88.0;
    const fingerWid = 40.0;
    const fingerAngle = -math.pi / 2 + 0.15; // slight angle

    canvas.save();
    canvas.translate(targetX + 2, targetY - 1);
    canvas.rotate(fingerAngle);

    // Shadow
    final shadowRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: const Offset(2, 3), width: fingerWid, height: fingerLen),
      Radius.circular(fingerWid / 2),
    );
    canvas.drawRRect(
        shadowRRect, Paint()..color = Colors.black.withOpacity(0.10));

    // Finger body
    final bodyRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset.zero, width: fingerWid, height: fingerLen),
      Radius.circular(fingerWid / 2),
    );
    canvas.drawRRect(bodyRRect, Paint()..color = _kSkinBase);

    // Highlight along one side for 3D form
    final highlightRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: const Offset(-7, 0),
          width: 11,
          height: fingerLen * 0.55),
      const Radius.circular(5.5),
    );
    canvas.drawRRect(
        highlightRRect, Paint()..color = _kSkinHighlight.withOpacity(0.5));

    // Nail hint near the tip
    final nailRRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -fingerLen / 2 + 15),
        width: fingerWid * 0.46,
        height: 15,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(nailRRect, Paint()..color = _kNailColor.withOpacity(0.7));
    canvas.drawRRect(
      nailRRect,
      Paint()
        ..color = const Color(0xFFCCAA90).withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    canvas.restore();

    // --- Glow bleed around finger edges (when flash is on) ---
    if (glowIntensity > 0) {
      // Soft halo at the finger's perimeter where light leaks around it
      canvas.save();
      canvas.translate(targetX + 2, targetY - 1);
      canvas.rotate(fingerAngle);
      final edgeGlow = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset.zero,
            width: fingerWid + 8,
            height: fingerLen * 0.45),
        Radius.circular(fingerWid / 2 + 4),
      );
      canvas.drawRRect(
        edgeGlow,
        Paint()
          ..color = _kGlowWarm.withOpacity(0.12 * glowIntensity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.restore();
    }

    // --- Heart (below the phone, gently beating) ---
    final heartX = cx;
    final heartY = cy + ph / 2 + 28;
    _drawHeart(canvas, Offset(heartX, heartY), 11.0 * heartScale, _kHeartColor);
    // Small label beneath heart
    final tp = TextPainter(
      text: const TextSpan(
        text: 'detecting heartbeat',
        style: TextStyle(
          fontSize: 10,
          color: Color(0xFF9E9E9E),
          fontWeight: FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(heartX - tp.width / 2, heartY + 16));
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
  bool shouldRepaint(covariant _HelpIllustrationPainter old) =>
      old.glowIntensity != glowIntensity || old.heartScale != heartScale;
}
