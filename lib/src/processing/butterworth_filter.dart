import 'dart:math' as math;

class _BiquadCoeffs {
  final double b0, b1, b2, a1, a2;
  const _BiquadCoeffs(this.b0, this.b1, this.b2, this.a1, this.a2);
}

class _BiquadState {
  double s1 = 0.0;
  double s2 = 0.0;

  void reset() {
    s1 = 0.0;
    s2 = 0.0;
  }
}

/// Butterworth bandpass filter (0.75–3.5 Hz) implemented as two cascaded
/// biquad sections: a 2nd-order high-pass followed by a 2nd-order low-pass.
/// Passes the cardiac frequency band (45–210 BPM).
class ButterworthBandpassFilter {
  late final _BiquadCoeffs _hpCoeffs;
  late final _BiquadCoeffs _lpCoeffs;
  final _BiquadState _hpState = _BiquadState();
  final _BiquadState _lpState = _BiquadState();

  ButterworthBandpassFilter({required double sampleRate}) {
    _hpCoeffs = _computeHighPass(sampleRate, 0.75);
    _lpCoeffs = _computeLowPass(sampleRate, 3.5);
  }

  static _BiquadCoeffs _computeHighPass(double sampleRate, double cutoff) {
    final omega = 2.0 * math.pi * cutoff / sampleRate;
    final sinOmega = math.sin(omega);
    final cosOmega = math.cos(omega);
    final alpha = sinOmega / (2.0 * 0.7071);
    final a0 = 1.0 + alpha;

    return _BiquadCoeffs(
      ((1.0 + cosOmega) / 2.0) / a0,
      (-(1.0 + cosOmega)) / a0,
      ((1.0 + cosOmega) / 2.0) / a0,
      (-2.0 * cosOmega) / a0,
      (1.0 - alpha) / a0,
    );
  }

  static _BiquadCoeffs _computeLowPass(double sampleRate, double cutoff) {
    final omega = 2.0 * math.pi * cutoff / sampleRate;
    final sinOmega = math.sin(omega);
    final cosOmega = math.cos(omega);
    final alpha = sinOmega / (2.0 * 0.7071);
    final a0 = 1.0 + alpha;

    return _BiquadCoeffs(
      ((1.0 - cosOmega) / 2.0) / a0,
      (1.0 - cosOmega) / a0,
      ((1.0 - cosOmega) / 2.0) / a0,
      (-2.0 * cosOmega) / a0,
      (1.0 - alpha) / a0,
    );
  }

  double _processBiquad(
      double x, _BiquadCoeffs c, _BiquadState s) {
    final y = c.b0 * x + s.s1;
    s.s1 = c.b1 * x - c.a1 * y + s.s2;
    s.s2 = c.b2 * x - c.a2 * y;
    return y;
  }

  /// Process one sample through the bandpass filter.
  double process(double sample) {
    final hp = _processBiquad(sample, _hpCoeffs, _hpState);
    return _processBiquad(hp, _lpCoeffs, _lpState);
  }

  /// Reset internal state for a new measurement.
  void reset() {
    _hpState.reset();
    _lpState.reset();
  }
}
