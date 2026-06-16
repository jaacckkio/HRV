/// Detects the actual frame rate from camera frame timestamps.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class FrameRateDetector {
  FrameRateDetector();

  static const int _warmupFrames = 30;
  static const double _defaultFPS = 120.0;
  static const double _minStableFPS = 20.0;
  static const int _lowFpsStreakToUnstable = 3;

  final List<double> _frameIntervalsMs = [];
  int? _lastFrameMicros;
  double _detectedFPS = _defaultFPS;
  bool _isStable = false;
  int _lowFpsStreak = 0;
  bool _deterministic = false;

  double get fps => _detectedFPS;
  bool get isStable => _isStable;

  void recordFrameMicros(int timestampMicros) {
    // In deterministic mode (replay), skip detection entirely —
    // FPS and isStable are already set and must not drift.
    if (_deterministic) return;

    if (_lastFrameMicros != null) {
      final intervalMs = (timestampMicros - _lastFrameMicros!) / 1000.0;

      if (intervalMs >= 5.0 && intervalMs <= 200.0) {
        _frameIntervalsMs.add(intervalMs);

        if (_frameIntervalsMs.length > _warmupFrames * 2) {
          _frameIntervalsMs.removeAt(0);
        }

        if (_frameIntervalsMs.length >= _warmupFrames) {
          _updateFPS();
        }
      }
    }

    _lastFrameMicros = timestampMicros;
  }

  void _updateFPS() {
    if (_frameIntervalsMs.isEmpty) return;

    final sorted = List<double>.from(_frameIntervalsMs)..sort();
    final medianInterval = sorted[sorted.length ~/ 2];

    final rawFPS = 1000.0 / medianInterval;
    _detectedFPS = _snapToCommonFPS(rawFPS);

    if (_detectedFPS < _minStableFPS) {
      _lowFpsStreak++;
    } else {
      _lowFpsStreak = 0;
    }

    _isStable = _frameIntervalsMs.length >= _warmupFrames &&
        _lowFpsStreak < _lowFpsStreakToUnstable;
  }

  double _snapToCommonFPS(double rawFPS) {
    const commonRates = [24.0, 25.0, 30.0, 60.0, 120.0];
    const tolerance = 2.0;

    for (final rate in commonRates) {
      if ((rawFPS - rate).abs() <= tolerance) return rate;
    }
    return rawFPS;
  }

  void reset() {
    _frameIntervalsMs.clear();
    _lastFrameMicros = null;
    _detectedFPS = _defaultFPS;
    _isStable = false;
    _lowFpsStreak = 0;
    _deterministic = false;
  }

  /// DEV TOOLING — force a known FPS and mark as immediately stable.
  /// Used during replay to guarantee bit-for-bit identical processing
  /// by bypassing the warmup/detection phase entirely.
  void setDeterministicFPS(double fps) {
    _detectedFPS = fps;
    _isStable = true;
    _lowFpsStreak = 0;
    _deterministic = true;
  }
}
