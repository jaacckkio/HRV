import 'dart:math' as math;

/// Bandpass lower cutoff (Hz). 0.7 Hz ≈ 42 bpm.
/// Removes DC drift and respiratory-frequency content below the cardiac band.
const double kBandpassLowHz = 0.7;

/// Bandpass upper cutoff (Hz). 4.0 Hz ≈ 240 bpm.
/// Widened from 2.5 Hz to preserve the systolic upstroke's higher-frequency
/// content and sharpen each peak for accurate beat-to-beat timing.  The
/// previous 2.5 Hz cutoff over-rounded the systolic peak into a broad plateau,
/// smearing genuine RR variability and biasing RMSSD low vs Polar H10.
const double kBandpassHighHz = 4.0;

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

/// Butterworth bandpass filter implemented as two cascaded biquad sections:
/// a 2nd-order high-pass at [kBandpassLowHz] followed by a 2nd-order low-pass
/// at [kBandpassHighHz]. The narrow passband collapses each cardiac cycle to
/// a single hump, suppressing the dicrotic notch that otherwise causes
/// double-detection.
class ButterworthBandpassFilter {
  late final _BiquadCoeffs _hpCoeffs;
  late final _BiquadCoeffs _lpCoeffs;
  final _BiquadState _hpState = _BiquadState();
  final _BiquadState _lpState = _BiquadState();

  ButterworthBandpassFilter({required double sampleRate}) {
    _hpCoeffs = _computeHighPass(sampleRate, kBandpassLowHz);
    _lpCoeffs = _computeLowPass(sampleRate, kBandpassHighHz);
  }

  ButterworthBandpassFilter.custom({
    required double sampleRate,
    required double lowHz,
    required double highHz,
  }) {
    _hpCoeffs = _computeHighPass(sampleRate, lowHz);
    _lpCoeffs = _computeLowPass(sampleRate, highHz);
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

  /// Zero-phase (forward-backward) bandpass filter over a complete signal.
  /// Creates a temporary filter with the given cutoffs, runs it forward,
  /// resets state, runs backward, and reverses the result. This eliminates
  /// phase distortion, giving symmetric peaks suitable for accurate timing.
  ///
  /// Uses odd (point) reflection padding at both ends (~1.5 s) so the filter
  /// state settles before it reaches the real data — eliminates the startup
  /// transient that otherwise corrupts the first beat and collapses short
  /// rolling windows. This matches scipy.signal.filtfilt's default behaviour.
  static List<double> filtfilt(
      List<double> signal, double sampleRate, double lowHz, double highHz) {
    if (signal.isEmpty) return [];
    final f = ButterworthBandpassFilter.custom(
        sampleRate: sampleRate, lowHz: lowHz, highHz: highHz);

    final n = signal.length;
    final padLen = n < 3 ? 0 : math.min((1.5 * sampleRate).round(), n - 1);

    if (padLen < 1) {
      // Too short to pad — fall back to unpadded forward/backward
      final forward = List<double>.filled(n, 0.0);
      for (int i = 0; i < n; i++) {
        forward[i] = f.process(signal[i]);
      }
      f.reset();
      final result = List<double>.filled(n, 0.0);
      for (int i = n - 1; i >= 0; i--) {
        result[i] = f.process(forward[i]);
      }
      return result;
    }

    // Build reflection-padded signal: [left pad | signal | right pad]
    final paddedLen = padLen + n + padLen;
    final padded = List<double>.filled(paddedLen, 0.0);
    final first = signal[0];
    final last = signal[n - 1];

    // Left pad: odd reflection about signal[0], k = padLen down to 1
    for (int k = padLen; k >= 1; k--) {
      padded[padLen - k] = 2 * first - signal[k];
    }
    // Centre: original signal
    for (int i = 0; i < n; i++) {
      padded[padLen + i] = signal[i];
    }
    // Right pad: odd reflection about signal[last], k = 2 to padLen+1
    for (int k = 2; k <= padLen + 1; k++) {
      padded[padLen + n + (k - 2)] = 2 * last - signal[n - k];
    }

    // Forward pass over padded signal
    final forward = List<double>.filled(paddedLen, 0.0);
    for (int i = 0; i < paddedLen; i++) {
      forward[i] = f.process(padded[i]);
    }

    // Reset state, backward pass
    f.reset();
    final paddedResult = List<double>.filled(paddedLen, 0.0);
    for (int i = paddedLen - 1; i >= 0; i--) {
      paddedResult[i] = f.process(forward[i]);
    }

    // Return central slice (drop padding)
    return paddedResult.sublist(padLen, padLen + n);
  }
}
