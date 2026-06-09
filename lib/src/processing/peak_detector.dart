import 'dart:math' as math;

/// Detects peaks in a PPG signal for RR interval calculation.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class PeakDetector {
  final double minProminence;
  final int minDistance;

  const PeakDetector({this.minProminence = 0.5, this.minDistance = 10});

  List<int> findPeaks(List<double> signal) {
    if (signal.length < 3) return [];

    final peaks = <int>[];

    for (int i = 1; i < signal.length - 1; i++) {
      if (signal[i] > signal[i - 1] && signal[i] > signal[i + 1]) {
        if (peaks.isNotEmpty) {
          if (i - peaks.last < minDistance) {
            if (signal[i] > signal[peaks.last]) {
              peaks.removeLast();
              peaks.add(i);
            }
            continue;
          }
        }

        final startSearch = math.max(0, i - minDistance);
        final endSearch = math.min(signal.length, i + minDistance);

        double localMin = double.maxFinite;
        for (int j = startSearch; j < endSearch; j++) {
          if (signal[j] < localMin) localMin = signal[j];
        }

        if (signal[i] - localMin >= minProminence) {
          peaks.add(i);
        }
      }
    }

    return peaks;
  }

  /// Finds peaks with parabolic interpolation for sub-frame accuracy.
  /// Returns fractional indices instead of integer indices.
  List<double> findPeaksInterpolated(List<double> signal) {
    final intPeaks = findPeaks(signal);
    final interpolated = <double>[];

    for (final i in intPeaks) {
      if (i >= 1 && i < signal.length - 1) {
        final alpha = signal[i - 1];
        final beta = signal[i];
        final gamma = signal[i + 1];
        final denominator = alpha - 2 * beta + gamma;
        if (denominator.abs() > 1e-10) {
          final p = 0.5 * (alpha - gamma) / denominator;
          interpolated.add(i + p);
        } else {
          interpolated.add(i.toDouble());
        }
      } else {
        interpolated.add(i.toDouble());
      }
    }

    return interpolated;
  }

  /// Converts peak indices to RR intervals in milliseconds.
  List<double> peaksToRRIntervals(List<int> peakIndices, double frameRate) {
    if (peakIndices.length < 2) return [];

    final rrIntervals = <double>[];
    for (int i = 1; i < peakIndices.length; i++) {
      final diffFrames = peakIndices[i] - peakIndices[i - 1];
      final seconds = diffFrames / frameRate;
      rrIntervals.add(seconds * 1000.0);
    }
    return rrIntervals;
  }

  /// Converts interpolated (fractional) peak indices to RR intervals in milliseconds.
  List<double> peaksToRRIntervalsInterpolated(
      List<double> interpolatedPeakIndices, double frameRate) {
    if (interpolatedPeakIndices.length < 2) return [];

    final rrIntervals = <double>[];
    for (int i = 1; i < interpolatedPeakIndices.length; i++) {
      final diffFrames =
          interpolatedPeakIndices[i] - interpolatedPeakIndices[i - 1];
      final seconds = diffFrames / frameRate;
      rrIntervals.add(seconds * 1000.0);
    }
    return rrIntervals;
  }

  /// Merge dicrotic notch peaks: when two peaks are closer than
  /// [minDistanceFrames], keep the taller one and discard the shorter.
  static List<int> mergeDicroticNotches(
      List<int> peaks, List<double> signal, int minDistanceFrames) {
    if (peaks.length < 2) return List<int>.from(peaks);

    final merged = <int>[peaks[0]];

    for (int i = 1; i < peaks.length; i++) {
      final prev = merged.last;
      final curr = peaks[i];

      if (curr - prev < minDistanceFrames) {
        // Two peaks too close together — one is a dicrotic notch.
        // Keep whichever has the higher amplitude.
        if (signal[curr] > signal[prev]) {
          merged.removeLast();
          merged.add(curr);
        }
        // else: prev is taller, keep it, discard curr
      } else {
        merged.add(curr);
      }
    }

    return merged;
  }

  /// Parabolic interpolation on pre-determined integer peak indices.
  static List<double> interpolateExistingPeaks(
      List<int> peakIndices, List<double> signal) {
    final interpolated = <double>[];

    for (final i in peakIndices) {
      if (i <= 0 || i >= signal.length - 1) {
        interpolated.add(i.toDouble());
        continue;
      }

      final alpha = signal[i - 1];
      final beta = signal[i];
      final gamma = signal[i + 1];

      final denominator = alpha - 2 * beta + gamma;
      if (denominator.abs() > 1e-10) {
        final p = 0.5 * (alpha - gamma) / denominator;
        interpolated.add(i + p);
      } else {
        interpolated.add(i.toDouble());
      }
    }

    return interpolated;
  }
}
