/// Signal quality assessment levels for PPG signals.
enum SignalQuality { poor, fair, good }

/// PPG signal data extracted from camera frames.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class PPGSignal {
  final double rawIntensity;
  final double filteredIntensity;
  final List<double> rrIntervals;
  final SignalQuality quality;
  final DateTime timestamp;
  final List<int> peakIndices;
  final double snr;
  final double frameRate;
  final bool isFPSStable;
  final double driftRate;
  final double sdrr;
  final bool isSDRRAcceptable;
  final double rejectionRatio;
  final int rejectedIntervalCount;
  final bool fingerDetected;

  PPGSignal({
    required this.rawIntensity,
    required this.filteredIntensity,
    required this.rrIntervals,
    required this.quality,
    required this.timestamp,
    this.peakIndices = const [],
    this.snr = 0.0,
    this.frameRate = 30.0,
    this.isFPSStable = false,
    this.driftRate = 0.0,
    this.sdrr = 0.0,
    this.isSDRRAcceptable = true,
    this.rejectionRatio = 0.0,
    this.rejectedIntervalCount = 0,
    this.fingerDetected = false,
  });
}
