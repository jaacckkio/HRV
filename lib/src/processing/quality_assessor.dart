import 'dart:math' as math;
import '../models/ppg_signal.dart';
import '../models/ppg_config.dart';

/// Assesses the quality of the PPG signal.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class SignalQualityAssessor {
  final double fingerPresenceMin;
  final double fingerPresenceMax;
  final double minGoodSNR;
  final double minFairSNR;
  final double maxDriftRate;

  const SignalQualityAssessor({
    required this.fingerPresenceMin,
    required this.fingerPresenceMax,
    required this.minGoodSNR,
    required this.minFairSNR,
    required this.maxDriftRate,
  }) : assert(fingerPresenceMax > fingerPresenceMin),
       assert(minGoodSNR > minFairSNR),
       assert(maxDriftRate >= 0);

  factory SignalQualityAssessor.fromConfig(PPGConfig config) {
    return SignalQualityAssessor(
      fingerPresenceMin: config.fingerPresenceMin,
      fingerPresenceMax: config.fingerPresenceMax,
      minGoodSNR: config.minGoodSNR,
      minFairSNR: config.minFairSNR,
      maxDriftRate: config.maxDriftRate,
    );
  }

  bool isFingerPresent(double rawIntensity) {
    return rawIntensity > fingerPresenceMin &&
        rawIntensity < fingerPresenceMax;
  }

  double calculateSNR(List<double> signal) {
    if (signal.length < 2) return 0.0;

    final signalVariance = _calculateVariance(signal);
    if (signalVariance == 0) return 0.0;

    final diffs = <double>[];
    for (int i = 1; i < signal.length; i++) {
      diffs.add(signal[i] - signal[i - 1]);
    }
    final noiseVariance = _calculateVariance(diffs);

    if (noiseVariance == 0) return 100.0;

    return 10 * math.log(signalVariance / noiseVariance) / math.ln10;
  }

  SignalQuality assessQuality(List<double> recentSignals,
      {double? frameRate}) {
    if (recentSignals.isEmpty) return SignalQuality.poor;

    final last = recentSignals.last;
    if (!isFingerPresent(last)) return SignalQuality.poor;

    final minSamples = frameRate != null ? frameRate.round() : 30;
    if (recentSignals.length < minSamples) return SignalQuality.fair;

    final snr = calculateSNR(recentSignals);

    if (snr > minGoodSNR) return SignalQuality.good;
    if (snr > minFairSNR) return SignalQuality.fair;
    return SignalQuality.poor;
  }

  double calculateDriftRate(List<double> signal, double frameRate) {
    if (signal.length < 10) return 0.0;

    final n = signal.length;
    double sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;

    for (int i = 0; i < n; i++) {
      final x = i.toDouble();
      final y = signal[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }

    final denominator = (n * sumX2 - sumX * sumX);
    if (denominator == 0.0) return 0.0;

    final slope = (n * sumXY - sumX * sumY) / denominator;
    return slope * frameRate;
  }

  SignalQuality assessQualityWithDrift(
      List<double> recentSignals, double frameRate) {
    final basicQuality =
        assessQuality(recentSignals, frameRate: frameRate);
    if (basicQuality == SignalQuality.poor) return SignalQuality.poor;

    final driftRate = calculateDriftRate(recentSignals, frameRate).abs();
    if (driftRate > maxDriftRate) {
      return basicQuality == SignalQuality.good
          ? SignalQuality.fair
          : SignalQuality.poor;
    }

    return basicQuality;
  }

  double _calculateVariance(List<double> data) {
    if (data.isEmpty) return 0.0;
    final mean = data.reduce((a, b) => a + b) / data.length;
    double sumSquaredDiff = 0.0;
    for (final x in data) {
      final diff = x - mean;
      sumSquaredDiff += diff * diff;
    }
    return sumSquaredDiff / data.length;
  }
}
