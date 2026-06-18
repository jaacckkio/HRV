import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'butterworth_filter.dart' show kBandpassLowHz, kBandpassHighHz;

/// Candidate moving-average window sizes (seconds) for ROI auto-tuning.
const List<double> kMovingAvgWindowsSec = [0.75, 1.0, 1.5, 2.0, 2.5];

/// Fraction of the dominant beat period used as the refractory (minimum
/// inter-peak distance). At 0.70, a 1000 ms beat period yields a 700 ms
/// refractory — enough to suppress the dicrotic notch (~300 ms after the
/// systolic peak) while allowing normal beat-to-beat variability.
const double kRefractoryFraction = 0.70;

/// Minimum fraction of the global autocorrelation maximum that a local
/// maximum must reach to be accepted as the dominant beat period. Prevents
/// tiny noise ripples from being selected while still favouring the first
/// (fundamental) peak over the doubled-period harmonic. If no local max
/// clears this threshold, the global maximum is used as fallback.
const double kAutocorrPeakThreshold = 0.5;

/// Hard physiological floor for emitted RR intervals (ms). Any interval
/// at or below this is a detection artifact (two peaks on the same or
/// adjacent samples), not data, and is never emitted. 300 ms ≈ 200 bpm.
const double kMinRRIntervalMs = 300.0;

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
  /// Intervals at or below [kMinRRIntervalMs] are detection artifacts and
  /// are never emitted.
  List<double> peaksToRRIntervals(List<int> peakIndices, double frameRate) {
    if (peakIndices.length < 2) return [];

    final rrIntervals = <double>[];
    for (int i = 1; i < peakIndices.length; i++) {
      final diffFrames = peakIndices[i] - peakIndices[i - 1];
      final ms = (diffFrames / frameRate) * 1000.0;
      if (ms > kMinRRIntervalMs) rrIntervals.add(ms);
    }
    return rrIntervals;
  }

  /// Converts interpolated (fractional) peak indices to RR intervals in milliseconds.
  /// Intervals at or below [kMinRRIntervalMs] are detection artifacts and
  /// are never emitted.
  List<double> peaksToRRIntervalsInterpolated(
      List<double> interpolatedPeakIndices, double frameRate) {
    if (interpolatedPeakIndices.length < 2) return [];

    final rrIntervals = <double>[];
    for (int i = 1; i < interpolatedPeakIndices.length; i++) {
      final diffFrames =
          interpolatedPeakIndices[i] - interpolatedPeakIndices[i - 1];
      final ms = (diffFrames / frameRate) * 1000.0;
      if (ms > kMinRRIntervalMs) rrIntervals.add(ms);
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

  /// Estimate the dominant cardiac frequency via autocorrelation.
  ///
  /// Searches lags corresponding to the cardiac band
  /// [kBandpassLowHz]–[kBandpassHighHz]. To avoid half-rate locking (where
  /// the global autocorrelation max lands on the doubled period), selects
  /// the *first* local maximum (scanning from shortest lag upward) whose
  /// correlation reaches at least [kAutocorrPeakThreshold] of the global
  /// maximum. Falls back to the global max if no local peak clears the
  /// threshold. All values are derived from the input signal.
  static double _estimateDominantFrequency(
      List<double> signal, double frameRate) {
    final n = signal.length;
    if (n < 3) return (kBandpassLowHz + kBandpassHighHz) / 2;

    // Lag range from cardiac band boundaries (period = 1/freq)
    final minLag = math.max(1, (frameRate / kBandpassHighHz).floor());
    final maxLag = math.min(n ~/ 2, (frameRate / kBandpassLowHz).ceil());
    if (minLag >= maxLag) return (kBandpassLowHz + kBandpassHighHz) / 2;

    // Subtract mean for zero-centred autocorrelation
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += signal[i];
    }
    final mean = sum / n;

    // Compute autocorrelation for all in-band lags
    final corrValues = List<double>.filled(maxLag - minLag + 1, 0.0);
    double globalMaxCorr = double.negativeInfinity;
    int globalMaxLag = (minLag + maxLag) ~/ 2;

    for (int lag = minLag; lag <= maxLag; lag++) {
      double corr = 0;
      final limit = n - lag;
      for (int i = 0; i < limit; i++) {
        corr += (signal[i] - mean) * (signal[i + lag] - mean);
      }
      corr /= limit;
      corrValues[lag - minLag] = corr;

      if (corr > globalMaxCorr) {
        globalMaxCorr = corr;
        globalMaxLag = lag;
      }
    }

    // Find the first local maximum (scanning from shortest lag) that
    // exceeds kAutocorrPeakThreshold of the global max — this favours the
    // fundamental beat period over the doubled-period harmonic.
    final threshold = kAutocorrPeakThreshold * globalMaxCorr;
    final len = corrValues.length;

    for (int j = 1; j < len - 1; j++) {
      if (corrValues[j] > corrValues[j - 1] &&
          corrValues[j] > corrValues[j + 1] &&
          corrValues[j] >= threshold) {
        return frameRate / (minLag + j);
      }
    }

    // Fallback: no local max cleared the threshold — use global max
    return frameRate / globalMaxLag;
  }

  /// Detect peaks using the moving-average ROI method with SDSD-minimising
  /// window auto-tuning and a signal-derived refractory period.
  ///
  /// [signal] is the filtered PPG waveform. [frameRate] is the sampling rate
  /// in Hz. The method estimates the dominant cardiac frequency via
  /// autocorrelation, derives a refractory period ([kRefractoryFraction] of
  /// the beat period), then tries each candidate window with that refractory
  /// enforced. Picks the window producing the lowest non-zero SDSD within
  /// physiological BPM range and returns the peaks. Also returns the chosen
  /// window via [ROIDetectionResult].
  static ROIDetectionResult findPeaksROI(
      List<double> signal, double frameRate) {
    if (signal.length < 3) {
      return ROIDetectionResult(
          interpolatedPeaks: [], peakIndices: [], selectedWindowSec: kMovingAvgWindowsSec.last);
    }

    // Estimate dominant cardiac frequency and derive refractory period
    final dominantHz = _estimateDominantFrequency(signal, frameRate);
    final periodMs = 1000.0 / dominantHz;
    final refractoryMs = kRefractoryFraction * periodMs;
    final refractoryFrames = (refractoryMs / 1000.0 * frameRate).round();

    if (kDebugMode) {
      debugPrint(
        'PeakDetector: dominantHz=${dominantHz.toStringAsFixed(2)} '
        'periodMs=${periodMs.toStringAsFixed(0)} '
        'refractoryMs=${refractoryMs.toStringAsFixed(0)} '
        'refractoryFrames=$refractoryFrames',
      );
    }

    _ROICandidateResult? bestResult;
    double bestSdsd = double.infinity;

    for (final windowSec in kMovingAvgWindowsSec) {
      final candidate =
          _detectWithWindow(signal, frameRate, windowSec, refractoryFrames);
      if (candidate.rrIntervals.length < 2) continue;

      // Physiological gates: mean BPM 40–150, mean RR ≥ 400ms
      double rrSum = 0;
      for (final rr in candidate.rrIntervals) {
        rrSum += rr;
      }
      final meanRR = rrSum / candidate.rrIntervals.length;
      if (meanRR < 400) continue; // reject noise-flood over-detection
      final meanBPM = 60000.0 / meanRR;
      if (meanBPM < 40 || meanBPM > 150) continue;

      // Compute SDSD (standard deviation of successive differences)
      final sdsd = _computeSDSD(candidate.rrIntervals);
      if (sdsd <= 0) continue;

      if (sdsd < bestSdsd) {
        bestSdsd = sdsd;
        bestResult = candidate;
      }
    }

    // Fallback to longest window if all candidates were rejected —
    // over-detection (too-short window) is the failure we guard against
    bestResult ??=
        _detectWithWindow(signal, frameRate, kMovingAvgWindowsSec.last, refractoryFrames);

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
  ///
  /// [refractoryFrames] is the minimum distance (in frames) between any two
  /// accepted peaks, derived from the signal's dominant cardiac frequency.
  /// When two ROI maxima fall within the refractory window, only the taller
  /// one survives — this prevents the dicrotic bump from being accepted as
  /// a separate beat.
  static _ROICandidateResult _detectWithWindow(
      List<double> signal, double frameRate, double windowSec,
      int refractoryFrames) {
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
    final rawRoiMaxima = <int>[];
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
        rawRoiMaxima.add(roiMaxIdx);
        inROI = false;
      }
    }
    // If signal ends while in an ROI, close it
    if (inROI) {
      rawRoiMaxima.add(roiMaxIdx);
    }

    // Step 4b: Enforce refractory period — when two ROI maxima are closer
    // than refractoryFrames, keep the taller one and discard the other.
    final roiMaxima = <int>[];
    for (final idx in rawRoiMaxima) {
      if (roiMaxima.isNotEmpty && idx - roiMaxima.last < refractoryFrames) {
        // Within refractory of the previous accepted peak — keep the taller
        if (signal[idx] > signal[roiMaxima.last]) {
          roiMaxima.removeLast();
          roiMaxima.add(idx);
        }
        // else: previous peak is taller, discard this one
      } else {
        roiMaxima.add(idx);
      }
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
