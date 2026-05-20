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
}
