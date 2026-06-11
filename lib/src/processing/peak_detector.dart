import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Candidate moving-average window sizes (seconds) for ROI auto-tuning.
const List<double> kMovingAvgWindowsSec = [0.5, 0.65, 0.75, 1.0, 1.5];

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

  // ──────────────────────────────────────────────────────────────────
  // HeartPy-style moving-average ROI peak detection with auto-tuning
  // ──────────────────────────────────────────────────────────────────

  /// Detect peaks using the moving-average ROI method with SDSD-minimising
  /// window auto-tuning. Returns interpolated (fractional) peak indices.
  ///
  /// [signal] is the filtered PPG waveform. [frameRate] is the sampling rate
  /// in Hz. The method tries each candidate window, picks the one producing
  /// the lowest non-zero SDSD within physiological BPM range, and returns
  /// the peaks from that window. Also returns the chosen window via
  /// [ROIDetectionResult].
  static ROIDetectionResult findPeaksROI(
      List<double> signal, double frameRate) {
    if (signal.length < 3) {
      return ROIDetectionResult(
          interpolatedPeaks: [], peakIndices: [], selectedWindowSec: 0.75);
    }

    _ROICandidateResult? bestResult;
    double bestSdsd = double.infinity;

    for (final windowSec in kMovingAvgWindowsSec) {
      final candidate = _detectWithWindow(signal, frameRate, windowSec);
      if (candidate.rrIntervals.length < 2) continue;

      // BPM gate: mean BPM must be 40–180
      double rrSum = 0;
      for (final rr in candidate.rrIntervals) {
        rrSum += rr;
      }
      final meanRR = rrSum / candidate.rrIntervals.length;
      final meanBPM = 60000.0 / meanRR;
      if (meanBPM < 40 || meanBPM > 180) continue;

      // Compute SDSD (standard deviation of successive differences)
      final sdsd = _computeSDSD(candidate.rrIntervals);
      if (sdsd <= 0) continue;

      if (sdsd < bestSdsd) {
        bestSdsd = sdsd;
        bestResult = candidate;
      }
    }

    // Fallback to 0.75s window if all candidates were rejected
    bestResult ??= _detectWithWindow(signal, frameRate, 0.75);

    if (kDebugMode) {
      debugPrint(
        'PeakDetector ROI: window=${bestResult.windowSec}s '
        'peaks=${bestResult.interpolatedPeaks.length} '
        'RRs=${bestResult.rrIntervals.length} '
        'SDSD=${bestSdsd.isFinite ? bestSdsd.toStringAsFixed(1) : "N/A"}',
      );
    }

    return ROIDetectionResult(
      interpolatedPeaks: bestResult.interpolatedPeaks,
      peakIndices: bestResult.peakIndices,
      selectedWindowSec: bestResult.windowSec,
    );
  }

  /// Run the ROI detection pipeline for a single candidate window.
  static _ROICandidateResult _detectWithWindow(
      List<double> signal, double frameRate, double windowSec) {
    final n = signal.length;
    final windowSamples = (windowSec * frameRate).round();
    final halfWindow = windowSamples ~/ 2;

    // Compute signal mean for edge padding
    double signalSum = 0;
    for (int i = 0; i < n; i++) {
      signalSum += signal[i];
    }
    final signalMean = n > 0 ? signalSum / n : 0.0;

    // Step 2: Compute centred moving average
    final movingAvg = List<double>.filled(n, signalMean);
    for (int i = halfWindow; i < n - halfWindow; i++) {
      double wSum = 0;
      for (int j = i - halfWindow; j <= i + halfWindow; j++) {
        wSum += signal[j];
      }
      movingAvg[i] = wSum / (2 * halfWindow + 1);
    }

    // Step 3: Find ROIs — contiguous spans above the moving average
    // Step 4: Within each ROI, find the sample with max amplitude
    final roiMaxima = <int>[];
    bool inROI = false;
    int roiMaxIdx = 0;
    double roiMaxVal = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final aboveAvg = signal[i] > movingAvg[i];

      if (aboveAvg && !inROI) {
        // Crossing up — start new ROI
        inROI = true;
        roiMaxIdx = i;
        roiMaxVal = signal[i];
      } else if (aboveAvg && inROI) {
        // Inside ROI — track maximum
        if (signal[i] > roiMaxVal) {
          roiMaxVal = signal[i];
          roiMaxIdx = i;
        }
      } else if (!aboveAvg && inROI) {
        // Crossing down — end ROI, record the maximum
        roiMaxima.add(roiMaxIdx);
        inROI = false;
      }
    }
    // If signal ends while in an ROI, close it
    if (inROI) {
      roiMaxima.add(roiMaxIdx);
    }

    // Step 5: Apply parabolic interpolation to each ROI maximum
    final interpolatedPeaks = interpolateExistingPeaks(roiMaxima, signal);

    // Compute RR intervals for auto-tuning evaluation
    final rrIntervals = <double>[];
    for (int i = 1; i < interpolatedPeaks.length; i++) {
      final diffFrames = interpolatedPeaks[i] - interpolatedPeaks[i - 1];
      rrIntervals.add((diffFrames / frameRate) * 1000.0);
    }

    return _ROICandidateResult(
      peakIndices: roiMaxima,
      interpolatedPeaks: interpolatedPeaks,
      rrIntervals: rrIntervals,
      windowSec: windowSec,
    );
  }

  /// Compute the standard deviation of successive differences of RR intervals.
  static double _computeSDSD(List<double> rrIntervals) {
    if (rrIntervals.length < 2) return 0.0;

    final diffs = <double>[];
    for (int i = 1; i < rrIntervals.length; i++) {
      diffs.add(rrIntervals[i] - rrIntervals[i - 1]);
    }

    double sum = 0;
    for (final d in diffs) {
      sum += d;
    }
    final mean = sum / diffs.length;

    double varSum = 0;
    for (final d in diffs) {
      final dev = d - mean;
      varSum += dev * dev;
    }

    return math.sqrt(varSum / diffs.length);
  }
}

/// Internal result for a single candidate window evaluation.
class _ROICandidateResult {
  final List<int> peakIndices;
  final List<double> interpolatedPeaks;
  final List<double> rrIntervals;
  final double windowSec;

  const _ROICandidateResult({
    required this.peakIndices,
    required this.interpolatedPeaks,
    required this.rrIntervals,
    required this.windowSec,
  });
}

/// Public result of ROI peak detection, carrying the chosen window.
class ROIDetectionResult {
  final List<double> interpolatedPeaks;
  final List<int> peakIndices;
  final double selectedWindowSec;

  const ROIDetectionResult({
    required this.interpolatedPeaks,
    required this.peakIndices,
    required this.selectedWindowSec,
  });
}
