/// Configuration for PPG processing and quality thresholds.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class PPGConfig {
  /// Fallback sampling rate in FPS (used before FPS stabilizes).
  final int samplingRate;

  /// Sliding window length in seconds.
  final int windowSizeSeconds;

  /// Minimum RR interval (ms). 300ms ≈ 200 BPM.
  final double minRRMs;

  /// Maximum RR interval (ms). 2000ms ≈ 30 BPM.
  final double maxRRMs;

  /// Max adjacent RR change ratio (0.30 = 30%).
  final double maxAdjacentRRChangeRatio;

  /// Maximum acceptable SDRR (ms).
  final double maxAcceptableSDRRMs;

  /// Maximum baseline drift rate (intensity units/sec).
  final double maxDriftRate;

  /// SNR threshold for "good" quality (dB).
  final double minGoodSNR;

  /// SNR threshold for "fair" quality (dB).
  final double minFairSNR;

  /// Minimum intensity for finger presence detection.
  final double fingerPresenceMin;

  /// Maximum intensity for finger presence detection.
  final double fingerPresenceMax;

  const PPGConfig({
    this.samplingRate = 30,
    this.windowSizeSeconds = 10,
    this.minRRMs = 300.0,
    this.maxRRMs = 2000.0,
    this.maxAdjacentRRChangeRatio = 0.30,
    this.maxAcceptableSDRRMs = 150.0,
    this.maxDriftRate = 50.0,
    this.minGoodSNR = 5.0,
    this.minFairSNR = 0.0,
    this.fingerPresenceMin = 30.0,
    this.fingerPresenceMax = 250.0,
  }) : assert(samplingRate > 0),
       assert(windowSizeSeconds > 0),
       assert(minRRMs > 0),
       assert(maxRRMs > minRRMs),
       assert(maxAdjacentRRChangeRatio >= 0),
       assert(maxAcceptableSDRRMs >= 0),
       assert(maxDriftRate >= 0),
       assert(fingerPresenceMax > fingerPresenceMin),
       assert(minGoodSNR > minFairSNR);
}
