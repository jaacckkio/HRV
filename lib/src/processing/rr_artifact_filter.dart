import 'package:flutter/foundation.dart';

/// Altini-style three-step artifact removal for RR-interval series.
///
/// Produces a cleaned list with gap markers so successive-difference
/// metrics (RMSSD, SDSD, pNN50) never bridge across a removed beat.
class RRArtifactFilter {
  const RRArtifactFilter._();

  /// Range filter bounds (ms). Instantaneous HR ~30–200 bpm.
  static const double kMinRR = 300.0;
  static const double kMaxRR = 2000.0;

  /// Beat-to-beat difference threshold (fraction of previous interval).
  /// TODO: make adaptive to the person's baseline HRV — a fixed 20% can
  /// overcorrect high-HRV individuals. Fine for resting tests now.
  static const double kBeatToBeatThreshold = 0.20;

  /// Percentile outlier margin (fraction of P25/P75).
  static const double kPercentileMargin = 0.25;

  /// Run all three artifact-removal steps and return the cleaned result.
  static ArtifactFilterResult filter(List<double> rawIntervals) {
    final int rawCount = rawIntervals.length;

    if (rawCount < 2) {
      return ArtifactFilterResult(
        intervals: List<double>.from(rawIntervals),
        isAdjacentClean: rawCount >= 1
            ? List<bool>.filled(rawCount, true)
            : <bool>[],
        removedStep1: 0,
        removedStep2: 0,
        removedStep3: 0,
        rawCount: rawCount,
      );
    }

    // Working lists: interval value + whether the preceding beat boundary
    // is intact (true) or was created by a removal (false).
    var values = List<double>.from(rawIntervals);
    // isAdjacentClean[i] == true means interval i is truly successive to
    // interval i-1 (no beat was removed between them). Index 0 is always true.
    var adjacent = List<bool>.filled(rawCount, true);

    // --- Step 1: Range filter (300–2000ms) ---
    int removedStep1 = 0;
    {
      final keptValues = <double>[];
      final keptAdjacent = <bool>[];
      bool prevRemoved = false;
      for (int i = 0; i < values.length; i++) {
        if (values[i] >= kMinRR && values[i] <= kMaxRR) {
          keptValues.add(values[i]);
          // If the previous interval was removed, this one is not cleanly
          // adjacent to whatever came before it in the kept list.
          keptAdjacent.add(prevRemoved ? false : adjacent[i]);
          prevRemoved = false;
        } else {
          removedStep1++;
          prevRemoved = true;
        }
      }
      values = keptValues;
      adjacent = keptAdjacent;
      if (adjacent.isNotEmpty) adjacent[0] = true;
    }

    // --- Step 2: Beat-to-beat difference filter ---
    int removedStep2 = 0;
    if (values.length >= 2) {
      final keptValues = <double>[values[0]];
      final keptAdjacent = <bool>[adjacent[0]];
      double prevKept = values[0];
      bool prevRemoved = false;
      for (int i = 1; i < values.length; i++) {
        final diff = (values[i] - prevKept).abs();
        if (diff <= kBeatToBeatThreshold * prevKept) {
          keptValues.add(values[i]);
          keptAdjacent.add(prevRemoved ? false : adjacent[i]);
          prevKept = values[i];
          prevRemoved = false;
        } else {
          removedStep2++;
          prevRemoved = true;
        }
      }
      values = keptValues;
      adjacent = keptAdjacent;
      if (adjacent.isNotEmpty) adjacent[0] = true;
    }

    // --- Step 3: Percentile outlier filter ---
    int removedStep3 = 0;
    if (values.length >= 4) {
      final sorted = List<double>.from(values)..sort();
      final p25 = _percentile(sorted, 25);
      final p75 = _percentile(sorted, 75);
      final lowerBound = p25 - kPercentileMargin * p25;
      final upperBound = p75 + kPercentileMargin * p75;

      final keptValues = <double>[];
      final keptAdjacent = <bool>[];
      bool prevRemoved = false;
      for (int i = 0; i < values.length; i++) {
        if (values[i] >= lowerBound && values[i] <= upperBound) {
          keptValues.add(values[i]);
          keptAdjacent.add(prevRemoved ? false : adjacent[i]);
          prevRemoved = false;
        } else {
          removedStep3++;
          prevRemoved = true;
        }
      }
      values = keptValues;
      adjacent = keptAdjacent;
      if (adjacent.isNotEmpty) adjacent[0] = true;
    }

    final result = ArtifactFilterResult(
      intervals: values,
      isAdjacentClean: adjacent,
      removedStep1: removedStep1,
      removedStep2: removedStep2,
      removedStep3: removedStep3,
      rawCount: rawCount,
    );

    if (kDebugMode) {
      final totalRemoved = removedStep1 + removedStep2 + removedStep3;
      debugPrint(
        'RRArtifactFilter: raw=$rawCount '
        'step1=-$removedStep1 step2=-$removedStep2 step3=-$removedStep3 '
        'clean=${values.length} '
        'artifactRatio=${result.artifactRatio.toStringAsFixed(2)}',
      );
    }

    return result;
  }

  static double _percentile(List<double> sortedData, int percentile) {
    final n = sortedData.length;
    if (n == 0) return 0.0;
    final index = (percentile / 100) * (n - 1);
    final lower = index.floor();
    final upper = index.ceil();
    if (lower == upper) return sortedData[lower];
    final weight = index - lower;
    return sortedData[lower] * (1 - weight) + sortedData[upper] * weight;
  }
}

/// Result of artifact filtering, carrying gap metadata for successive-diff
/// metrics.
class ArtifactFilterResult {
  /// Cleaned RR intervals (ms).
  final List<double> intervals;

  /// For each interval at index i, true if interval i-1 and i are truly
  /// adjacent beats with no removal between them. Index 0 is always true.
  /// Used by RMSSD/pNN50 to skip non-adjacent pairs.
  final List<bool> isAdjacentClean;

  /// Number of intervals removed at each step (for diagnostics).
  final int removedStep1;
  final int removedStep2;
  final int removedStep3;

  /// Number of raw intervals before filtering.
  final int rawCount;

  const ArtifactFilterResult({
    required this.intervals,
    required this.isAdjacentClean,
    required this.removedStep1,
    required this.removedStep2,
    required this.removedStep3,
    required this.rawCount,
  });

  int get totalRemoved => removedStep1 + removedStep2 + removedStep3;

  double get artifactRatio =>
      rawCount > 0 ? totalRemoved / rawCount : 0.0;
}
