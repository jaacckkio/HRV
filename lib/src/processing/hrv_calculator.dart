import 'dart:math' as math;

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
  });
}

class HrvCalculator {
  const HrvCalculator._();

  static HrvResult compute(List<double> rrIntervals) {
    final n = rrIntervals.length;

    if (n < 2) {
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

    // Mean RR
    double sum = 0.0;
    for (final rr in rrIntervals) {
      sum += rr;
    }
    final meanRR = sum / n;
    final heartRate = 60000.0 / meanRR;

    // SDNN — population standard deviation
    double varianceSum = 0.0;
    for (final rr in rrIntervals) {
      final diff = rr - meanRR;
      varianceSum += diff * diff;
    }
    final sdnn = math.sqrt(varianceSum / n);

    // RMSSD and pNN50 — successive differences
    double sumSquaredDiffs = 0.0;
    int nn50Count = 0;
    for (int i = 1; i < n; i++) {
      final diff = rrIntervals[i] - rrIntervals[i - 1];
      sumSquaredDiffs += diff * diff;
      if (diff.abs() > 50.0) nn50Count++;
    }
    final rmssd = math.sqrt(sumSquaredDiffs / (n - 1));
    final pnn50 = (nn50Count / (n - 1)) * 100.0;

    // lnRMSSD
    final lnRmssd = rmssd > 0 ? math.log(rmssd) : 0.0;

    // Validity
    final bool isValid = n >= 10;
    final String qualityNote;
    if (n < 10) {
      qualityNote = 'Not enough heartbeats detected (need at least 10)';
    } else if (n <= 20) {
      qualityNote = 'Short measurement — results may be less reliable';
    } else {
      qualityNote = 'Good measurement';
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
    );
  }
}
