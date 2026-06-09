import 'dart:math' as math;
import 'package:camera/camera.dart';
import '../models/ppg_signal.dart';
import '../models/ppg_config.dart';
import '../models/filter_result.dart';
import 'signal_processor.dart';
import 'peak_detector.dart';
import 'quality_assessor.dart';
import 'outlier_filter.dart';
import 'frame_rate_detector.dart';
import 'rr_interval_analyzer.dart';
import 'ring_buffer.dart';

/// Main service for processing camera images into PPG signals and RR intervals.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class PPGService {
  final PPGConfig config;

  final SignalProcessor _processor;
  final SignalQualityAssessor _qualityAssessor;
  final OutlierFilter _outlierFilter;
  final FrameRateDetector _frameRateDetector;
  final RRIntervalAnalyzer _rrAnalyzer;

  late RingBuffer<double> _rawBuffer;
  late RingBuffer<double> _filteredBuffer;
  late PeakDetector _adaptivePeakDetector;
  int _adaptiveMinDistance = 0;
  double _adaptiveMinProminence = 0.5;
  final Stopwatch _frameStopwatch = Stopwatch();
  bool _buffersResized = false;
  int _lastReportedPeakCount = 0;
  final List<double> _recentRRsForAdaptive = [];
  final List<double> _recentValidRRs = [];

  PPGService({
    this.config = const PPGConfig(),
    SignalProcessor? processor,
    PeakDetector? peakDetector,
    SignalQualityAssessor? qualityAssessor,
    OutlierFilter? outlierFilter,
    FrameRateDetector? frameRateDetector,
    RRIntervalAnalyzer? rrIntervalAnalyzer,
  })  : _processor = processor ?? const SignalProcessor(),
        _qualityAssessor =
            qualityAssessor ?? SignalQualityAssessor.fromConfig(config),
        _outlierFilter = outlierFilter ?? OutlierFilter.fromConfig(config),
        _frameRateDetector = frameRateDetector ?? FrameRateDetector(),
        _rrAnalyzer =
            rrIntervalAnalyzer ?? RRIntervalAnalyzer.fromConfig(config) {
    int capacity = (config.samplingRate * config.windowSizeSeconds).round();
    _rawBuffer = RingBuffer<double>(capacity);
    _filteredBuffer = RingBuffer<double>(capacity);
    _adaptiveMinDistance =
        _minDistanceFromFps(config.samplingRate.toDouble());
    _adaptivePeakDetector = PeakDetector(
      minProminence: _adaptiveMinProminence,
      minDistance: _adaptiveMinDistance,
    );
  }

  void dispose() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _frameRateDetector.reset();
    _frameStopwatch.stop();
    _lastReportedPeakCount = 0;
    _recentRRsForAdaptive.clear();
    _recentValidRRs.clear();
  }

  /// Reset all state for a new measurement session.
  void reset() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _frameRateDetector.reset();
    _frameStopwatch.stop();
    _buffersResized = false;
    _lastReportedPeakCount = 0;
    _recentRRsForAdaptive.clear();
    _recentValidRRs.clear();
  }

  /// Clear signal buffers and peak tracking state.
  /// Call when starting a new measurement phase to discard stale data.
  /// Preserves frame rate detection (which took time to stabilise).
  void clearSignalBuffers() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _lastReportedPeakCount = 0;
    _recentRRsForAdaptive.clear();
    _recentValidRRs.clear();
  }

  /// Process a single camera frame synchronously and return the current signal state.
  PPGSignal processSingleFrame(CameraImage image) {
    final now = DateTime.now();

    // Record frame timing
    _frameRateDetector.recordFrameMicros(_nowMicros());
    final effectiveFPS = _effectiveFrameRate();
    _resizeBuffersIfNeeded(effectiveFPS);

    // Extract intensity from frame
    double intensity;
    try {
      intensity = _processor.extractRedChannel(image);
    } catch (e) {
      return PPGSignal(
        rawIntensity: 0.0,
        filteredIntensity: 0.0,
        rrIntervals: [],
        quality: SignalQuality.poor,
        timestamp: now,
        frameRate: _frameRateDetector.fps,
        isFPSStable: _frameRateDetector.isStable,
        fingerDetected: false,
      );
    }

    // Extract RGB channel means for colour-based finger detection
    double meanR = 0, meanG = 0, meanB = 0;
    try {
      final rgb = _processor.extractRGBMeans(image);
      meanR = rgb.meanR;
      meanG = rgb.meanG;
      meanB = rgb.meanB;
    } catch (_) {}

    _rawBuffer.add(intensity);

    // Need minimum samples before we can do anything useful
    final minSamples = effectiveFPS.round();
    if (!_rawBuffer.isFull && _rawBuffer.length < minSamples) {
      final fingerDetected = _qualityAssessor.isFingerPresentByColor(meanR, meanG, meanB);
      return PPGSignal(
        rawIntensity: intensity,
        filteredIntensity: 0.0,
        rrIntervals: [],
        quality: SignalQuality.poor,
        timestamp: now,
        frameRate: _frameRateDetector.fps,
        isFPSStable: _frameRateDetector.isStable,
        fingerDetected: fingerDetected,
      );
    }

    final rawWindow = _rawBuffer.toList;

    // Assess quality with colour-based finger detection
    final qualityResult = _qualityAssessor.assessQualityWithColorDetection(
        rawWindow, effectiveFPS, meanR, meanG, meanB);
    final quality = qualityResult.quality;
    final fingerDetected = qualityResult.fingerDetected;
    final driftRate =
        _qualityAssessor.calculateDriftRate(rawWindow, effectiveFPS);
    final snr = _qualityAssessor.calculateSNR(rawWindow);

    // Apply bandpass filter
    final filteredPoint =
        _processor.simpleBandpassFilter(rawWindow, 5);
    _filteredBuffer.add(filteredPoint);

    // If quality is poor or FPS not stable, return early
    if (quality == SignalQuality.poor || !_frameRateDetector.isStable) {
      return PPGSignal(
        rawIntensity: intensity,
        filteredIntensity: filteredPoint,
        rrIntervals: [],
        quality: quality,
        timestamp: now,
        snr: snr,
        frameRate: _frameRateDetector.fps,
        isFPSStable: _frameRateDetector.isStable,
        driftRate: driftRate,
        fingerDetected: fingerDetected,
      );
    }

    // Detect peaks
    final filteredWindow = _filteredBuffer.toList;
    final dynamicProminence = _dynamicMinProminence(filteredWindow);
    _updateAdaptivePeakDetector(effectiveFPS, dynamicProminence);
    // Find integer peaks, merge dicrotic notches, then interpolate
    final rawPeakIndices = _adaptivePeakDetector.findPeaks(filteredWindow);
    final mergeDistanceFrames = (0.6 * effectiveFPS).round();
    final peakIndices = PeakDetector.mergeDicroticNotches(
        rawPeakIndices, filteredWindow, mergeDistanceFrames);
    final interpolatedPeaks = PeakDetector.interpolateExistingPeaks(
        peakIndices, filteredWindow);

    // Extract and validate RR intervals — only return NEW ones
    List<double> rrIntervals = [];
    FilterResult filterResult = const FilterResult(
        intervals: [], totalInput: 0, rejectedCount: 0, rejectionRatio: 0.0);
    RRAnalysisResult rrAnalysis = _rrAnalyzer.analyze(const <double>[]);

    if (interpolatedPeaks.length >= 2) {
      final rawRRs = _adaptivePeakDetector.peaksToRRIntervalsInterpolated(
          interpolatedPeaks, effectiveFPS);

      // Only emit RR intervals corresponding to newly detected peaks.
      // If peaks fell off the window, adjust the count down without emitting.
      if (interpolatedPeaks.length > _lastReportedPeakCount) {
        final newIntervalCount =
            interpolatedPeaks.length - _lastReportedPeakCount;
        final newRRs = rawRRs.length >= newIntervalCount
            ? rawRRs.sublist(rawRRs.length - newIntervalCount)
            : rawRRs;
        filterResult = _outlierFilter.filterOutliersWithStats(newRRs);
        rrIntervals = filterResult.intervals;
        rrAnalysis = _rrAnalyzer.analyze(rrIntervals);

        // Collect valid RR intervals for adaptive min distance
        _recentRRsForAdaptive.addAll(rrIntervals);
        _updateAdaptiveMinDistance(effectiveFPS);
      }
      _lastReportedPeakCount = interpolatedPeaks.length;
    }

    // Track recent valid RR intervals for adaptive min distance (ratchet-up only)
    for (final rr in rrIntervals) {
      _recentValidRRs.add(rr);
      if (_recentValidRRs.length > 30) _recentValidRRs.removeAt(0);
    }

    if (_recentValidRRs.length >= 5) {
      final sorted = List<double>.from(_recentValidRRs)..sort();
      final medianRR = sorted[sorted.length ~/ 2];
      final adaptiveMinDistanceMs = medianRR * 0.7;
      final adaptiveMinDistanceFrames = (adaptiveMinDistanceMs / 1000.0 * effectiveFPS).round();
      if (adaptiveMinDistanceFrames > _adaptiveMinDistance) {
        _adaptiveMinDistance = adaptiveMinDistanceFrames;
        _adaptivePeakDetector = PeakDetector(
          minProminence: _adaptiveMinProminence,
          minDistance: _adaptiveMinDistance,
        );
      }
    }

    return PPGSignal(
      rawIntensity: intensity,
      filteredIntensity: filteredPoint,
      rrIntervals: rrIntervals,
      quality: quality,
      timestamp: now,
      peakIndices: peakIndices,
      snr: snr,
      frameRate: _frameRateDetector.fps,
      isFPSStable: _frameRateDetector.isStable,
      driftRate: driftRate,
      sdrr: rrAnalysis.sdrr,
      isSDRRAcceptable: rrAnalysis.isSDRRAcceptable,
      rejectionRatio: filterResult.rejectionRatio,
      rejectedIntervalCount: filterResult.rejectedCount,
      fingerDetected: fingerDetected,
    );
  }

  double _effectiveFrameRate() {
    final detected = _frameRateDetector.fps;
    if (detected <= 0) return config.samplingRate.toDouble();
    return detected;
  }

  void _resizeBuffersIfNeeded(double fps) {
    if (!_frameRateDetector.isStable) return;
    if (_buffersResized) return;

    final desiredCapacity = (fps * config.windowSizeSeconds).round();
    if (desiredCapacity <= 0) return;
    if (_rawBuffer.capacity == desiredCapacity) {
      _buffersResized = true;
      return;
    }

    final rawValues = _rawBuffer.toList;
    final filteredValues = _filteredBuffer.toList;

    final newRaw = RingBuffer<double>(desiredCapacity);
    final newFiltered = RingBuffer<double>(desiredCapacity);

    final rawStart = rawValues.length > desiredCapacity
        ? rawValues.length - desiredCapacity
        : 0;
    for (int i = rawStart; i < rawValues.length; i++) {
      newRaw.add(rawValues[i]);
    }

    final filteredStart = filteredValues.length > desiredCapacity
        ? filteredValues.length - desiredCapacity
        : 0;
    for (int i = filteredStart; i < filteredValues.length; i++) {
      newFiltered.add(filteredValues[i]);
    }

    _rawBuffer = newRaw;
    _filteredBuffer = newFiltered;
    _buffersResized = true;
  }

  void _updateAdaptivePeakDetector(double fps,
      [double? minProminenceOverride]) {
    // Only use the default min distance if no adaptive distance has been set yet
    final minDistanceFrames = _recentRRsForAdaptive.length >= 5
        ? _adaptiveMinDistance
        : _minDistanceFromFps(fps);
    final minProminence = minProminenceOverride ?? _adaptiveMinProminence;
    final prominenceChanged =
        (minProminence - _adaptiveMinProminence).abs() >= 0.05;
    if (minDistanceFrames == _adaptiveMinDistance && !prominenceChanged) return;

    _adaptivePeakDetector = PeakDetector(
      minProminence: minProminence,
      minDistance: minDistanceFrames,
    );
    _adaptiveMinDistance = minDistanceFrames;
    _adaptiveMinProminence = minProminence;
  }

  int _minDistanceFromFps(double fps) {
    // Use 500ms default (120 BPM ceiling) instead of config.minRRMs (300ms)
    // to reduce false peaks between real heartbeats
    const defaultMinRRMs = 500.0;
    int minDistanceFrames = (fps * (defaultMinRRMs / 1000.0)).round();
    if (minDistanceFrames < 1) minDistanceFrames = 1;
    return minDistanceFrames;
  }

  void _updateAdaptiveMinDistance(double fps) {
    if (_recentRRsForAdaptive.length < 5) return;

    // Compute median RR interval in ms
    final sorted = List<double>.from(_recentRRsForAdaptive)..sort();
    final medianRR = sorted[sorted.length ~/ 2];

    // Set min distance to 70% of median RR in frames
    final medianFrames = medianRR / 1000.0 * fps;
    int adaptiveDistance = (medianFrames * 0.7).round();
    if (adaptiveDistance < 1) adaptiveDistance = 1;

    if (adaptiveDistance != _adaptiveMinDistance) {
      _adaptivePeakDetector = PeakDetector(
        minProminence: _adaptiveMinProminence,
        minDistance: adaptiveDistance,
      );
      _adaptiveMinDistance = adaptiveDistance;
    }
  }

  int _nowMicros() {
    if (!_frameStopwatch.isRunning) _frameStopwatch.start();
    return _frameStopwatch.elapsedMicroseconds;
  }

  double _dynamicMinProminence(List<double> signal) {
    if (signal.length < 10) {
      return _adaptiveMinProminence > 0.0
          ? _adaptiveMinProminence
          : 0.5;
    }
    final start = signal.length > 60 ? signal.length - 60 : 0;
    final stdDev = _calculateStdDev(signal.sublist(start));
    final computed = stdDev * 1.0;
    return computed < 0.5 ? 0.5 : computed;
  }

  double _calculateStdDev(List<double> values) {
    if (values.isEmpty) return 0.0;
    double sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    final mean = sum / values.length;
    double varianceSum = 0.0;
    for (final v in values) {
      final diff = v - mean;
      varianceSum += diff * diff;
    }
    final variance = varianceSum / values.length;
    return variance <= 0.0 ? 0.0 : math.sqrt(variance);
  }
}
