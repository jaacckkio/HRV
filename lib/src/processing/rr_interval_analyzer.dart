import 'dart:math' as math;
import '../models/ppg_config.dart';

/// Analyzes RR interval quality and calculates heart rate statistics.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class RRIntervalAnalyzer {
  final double maxAcceptableSDRR;

  const RRIntervalAnalyzer({required this.maxAcceptableSDRR})
      : assert(maxAcceptableSDRR >= 0);

  factory RRIntervalAnalyzer.fromConfig(PPGConfig config) {
    return RRIntervalAnalyzer(maxAcceptableSDRR: config.maxAcceptableSDRRMs);
  }

  double calculateSDRR(List<double> rrIntervals) {
    if (rrIntervals.length < 2) return 0.0;

    final mean = rrIntervals.reduce((a, b) => a + b) / rrIntervals.length;
    double sumSquaredDiff = 0.0;
    for (final rr in rrIntervals) {
      final diff = rr - mean;
      sumSquaredDiff += diff * diff;
    }
    final variance = sumSquaredDiff / rrIntervals.length;
    return math.sqrt(variance);
  }

  double calculateMeanBPM(List<double> rrIntervals) {
    if (rrIntervals.isEmpty) return 0.0;
    final meanRR = rrIntervals.reduce((a, b) => a + b) / rrIntervals.length;
    return 60000.0 / meanRR;
  }

  RRAnalysisResult analyze(List<double> rrIntervals) {
    if (rrIntervals.isEmpty) {
      return const RRAnalysisResult(
          meanBPM: 0.0, sdrr: 0.0, isSDRRAcceptable: false, intervalCount: 0);
    }

    final sdrr = calculateSDRR(rrIntervals);
    return RRAnalysisResult(
      meanBPM: calculateMeanBPM(rrIntervals),
      sdrr: sdrr,
      isSDRRAcceptable: sdrr <= maxAcceptableSDRR,
      intervalCount: rrIntervals.length,
    );
  }
}

class RRAnalysisResult {
  final double meanBPM;
  final double sdrr;
  final bool isSDRRAcceptable;
  final int intervalCount;

  const RRAnalysisResult({
    required this.meanBPM,
    required this.sdrr,
    required this.isSDRRAcceptable,
    required this.intervalCount,
  });
}
