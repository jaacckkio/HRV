import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'rr_artifact_filter.dart';

class HrvResult {
  final double meanRR;
  final double heartRate;
  final double sdnn;
  final double rmssd;
  final double pnn50;
  final double lnRmssd;
  final int totalIntervals;
  final bool isValid;
  final String qualityNote;
  final double artifactRatio;
  final int rawIntervalCount;
  final int removedByRange;
  final int removedByBeatToBeat;
  final int removedByPercentile;
  final int cleanIntervalCount;
  final int validPairCount;

  const HrvResult({
    required this.meanRR,
    required this.heartRate,
    required this.sdnn,
    required this.rmssd,
    required this.pnn50,
    required this.lnRmssd,
    required this.totalIntervals,
    required this.isValid,
    required this.qualityNote,
    this.artifactRatio = 0.0,
    this.rawIntervalCount = 0,
    this.removedByRange = 0,
    this.removedByBeatToBeat = 0,
    this.removedByPercentile = 0,
    this.cleanIntervalCount = 0,
    this.validPairCount = 0,
  });
}

class HrvCalculator {
  const HrvCalculator._();

  static HrvResult compute(List<double> rrIntervals) {
    if (rrIntervals.length < 2) {
      final n = rrIntervals.length;
      return HrvResult(
        meanRR: n == 1 ? rrIntervals[0] : 0.0,
        heartRate: n == 1 ? 60000.0 / rrIntervals[0] : 0.0,
        sdnn: 0.0,
        rmssd: 0.0,
        pnn50: 0.0,
        lnRmssd: 0.0,
        totalIntervals: n,
        isValid: false,
        qualityNote: 'Not enough heartbeats detected (need at least 10)',
      );
    }

    // Artifact removal (Altini-style three-step filter)
    final filtered = RRArtifactFilter.filter(rrIntervals);
    final clean = filtered.intervals;
    final adjacentClean = filtered.isAdjacentClean;
    final artifactRatio = filtered.artifactRatio;
    final n = clean.length;

    if (n < 2) {
      return HrvResult(
        meanRR: n == 1 ? clean[0] : 0.0,
        heartRate: n == 1 ? 60000.0 / clean[0] : 0.0,
        sdnn: 0.0,
        rmssd: 0.0,
        pnn50: 0.0,
        lnRmssd: 0.0,
        totalIntervals: n,
        isValid: false,
        qualityNote: 'Too many artifacts — not enough clean beats',
        artifactRatio: artifactRatio,
      );
    }

    // Mean RR
    double sum = 0.0;
    for (final rr in clean) {
      sum += rr;
    }
    final meanRR = sum / n;
    final heartRate = 60000.0 / meanRR;

    // SDNN — population standard deviation (uses all surviving intervals)
    double varianceSum = 0.0;
    for (final rr in clean) {
      final diff = rr - meanRR;
      varianceSum += diff * diff;
    }
    final sdnn = math.sqrt(varianceSum / n);

    // RMSSD and pNN50 — gap-aware successive differences.
    // Only compute the difference between clean[i] and clean[i-1] when
    // adjacentClean[i] is true (no beat was removed between them).
    double sumSquaredDiffs = 0.0;
    int nn50Count = 0;
    int validPairCount = 0;
    for (int i = 1; i < n; i++) {
      if (!adjacentClean[i]) continue; // gap — skip this pair
      final diff = clean[i] - clean[i - 1];
      sumSquaredDiffs += diff * diff;
      if (diff.abs() > 50.0) nn50Count++;
      validPairCount++;
    }
    final rmssd =
        validPairCount > 0 ? math.sqrt(sumSquaredDiffs / validPairCount) : 0.0;
    final pnn50 =
        validPairCount > 0 ? (nn50Count / validPairCount) * 100.0 : 0.0;

    // lnRMSSD
    final lnRmssd = rmssd > 0 ? math.log(rmssd) : 0.0;

    // Validity
    final bool isValid = n >= 10 && artifactRatio <= 0.30;
    final String qualityNote;
    if (n < 10) {
      qualityNote = 'Not enough heartbeats detected (need at least 10)';
    } else if (artifactRatio > 0.30) {
      qualityNote =
          'High artifact ratio (${(artifactRatio * 100).round()}%) — results unreliable';
    } else if (n <= 20) {
      qualityNote = 'Short measurement — results may be less reliable';
    } else {
      qualityNote = 'Good measurement';
    }

    if (kDebugMode) {
      debugPrint(
        'HrvCalculator: clean=$n validPairs=$validPairCount '
        'artifactRatio=${artifactRatio.toStringAsFixed(2)} '
        'RMSSD=${rmssd.toStringAsFixed(1)}ms',
      );
    }

    return HrvResult(
      meanRR: meanRR,
      heartRate: heartRate,
      sdnn: sdnn,
      rmssd: rmssd,
      pnn50: pnn50,
      lnRmssd: lnRmssd,
      totalIntervals: n,
      isValid: isValid,
      qualityNote: qualityNote,
      artifactRatio: artifactRatio,
      rawIntervalCount: filtered.rawCount,
      removedByRange: filtered.removedStep1,
      removedByBeatToBeat: filtered.removedStep2,
      removedByPercentile: filtered.removedStep3,
      cleanIntervalCount: n,
      validPairCount: validPairCount,
    );
  }
}
