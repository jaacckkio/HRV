import 'package:camera/camera.dart';
import '../models/ppg_signal.dart';
import '../models/ppg_config.dart';
import '../models/filter_result.dart';
import 'signal_processor.dart';
import 'butterworth_filter.dart';
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
  final List<double> _fullFilteredSignal = [];
  static const PeakDetector _peakDetector = PeakDetector();
  final Stopwatch _frameStopwatch = Stopwatch();
  bool _buffersResized = false;
  int _lastReportedPeakCount = 0;
  ButterworthBandpassFilter? _butterworthFilter;

  PPGService({
    this.config = const PPGConfig(),
    SignalProcessor? processor,
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
  }

  void dispose() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _fullFilteredSignal.clear();
    _frameRateDetector.reset();
    _frameStopwatch.stop();
    _lastReportedPeakCount = 0;
    _butterworthFilter?.reset();
    _butterworthFilter = null;
  }

  /// Reset all state for a new measurement session.
  void reset() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _fullFilteredSignal.clear();
    _frameRateDetector.reset();
    _frameStopwatch.stop();
    _buffersResized = false;
    _lastReportedPeakCount = 0;
    _butterworthFilter?.reset();
    _butterworthFilter = null;
  }

  /// Clear signal buffers and peak tracking state.
  /// Call when starting a new measurement phase to discard stale data.
  /// Preserves frame rate detection (which took time to stabilise).
  void clearSignalBuffers() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _fullFilteredSignal.clear();
    _lastReportedPeakCount = 0;
    _butterworthFilter?.reset();
  }

  /// Process a single camera frame synchronously and return the current signal state.
  PPGSignal processSingleFrame(CameraImage image) {
    final now = DateTime.now();

    // Record frame timing
    _frameRateDetector.recordFrameMicros(_nowMicros());
    final effectiveFPS = _effectiveFrameRate();
    _resizeBuffersIfNeeded(effectiveFPS);

    // Extract RGB means (single pixel iteration) and derive HSV Value as PPG signal
    double intensity;
    double meanR = 0, meanG = 0, meanB = 0;
    try {
      final rgb = _processor.extractRGBMeans(image);
      meanR = rgb.meanR;
      meanG = rgb.meanG;
      meanB = rgb.meanB;
      // HSV Value (brightness) as PPG signal — validated by HRV4Training
      intensity = SignalProcessor.rgbToHsvValue(meanR, meanG, meanB);
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

    // Apply Butterworth bandpass filter (0.5–8 Hz)
    if (_butterworthFilter == null && _frameRateDetector.isStable) {
      _butterworthFilter = ButterworthBandpassFilter(sampleRate: _frameRateDetector.fps);
    }

    double filteredPoint;
    if (_butterworthFilter != null) {
      filteredPoint = _butterworthFilter!.process(intensity);
    } else {
      // Before FPS stabilises, use raw intensity minus running mean as crude filter
      if (rawWindow.isNotEmpty) {
        final mean = rawWindow.reduce((a, b) => a + b) / rawWindow.length;
        filteredPoint = intensity - mean;
      } else {
        filteredPoint = 0.0;
      }
    }
    _filteredBuffer.add(filteredPoint);
    _fullFilteredSignal.add(filteredPoint);

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

    // Detect peaks using HeartPy-style moving-average ROI method
    final filteredWindow = _filteredBuffer.toList;
    final roiResult = PeakDetector.findPeaksROI(filteredWindow, effectiveFPS);
    final peakIndices = roiResult.peakIndices;
    final interpolatedPeaks = roiResult.interpolatedPeaks;

    // Extract and validate RR intervals — only return NEW ones
    List<double> rrIntervals = [];
    FilterResult filterResult = const FilterResult(
        intervals: [], totalInput: 0, rejectedCount: 0, rejectionRatio: 0.0);
    RRAnalysisResult rrAnalysis = _rrAnalyzer.analyze(const <double>[]);

    if (interpolatedPeaks.length >= 2) {
      final rawRRs = _peakDetector.peaksToRRIntervalsInterpolated(
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
      }
      _lastReportedPeakCount = interpolatedPeaks.length;
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

  /// Run ROI peak detection ONCE on the full filtered signal and return
  /// the final RR-interval series plus the selected window size.
  /// Call at end-of-measurement for the definitive HRV computation.
  ({List<double> rrIntervals, double selectedWindowSec}) computeFinalRRIntervals() {
    final fps = _effectiveFrameRate();
    if (_fullFilteredSignal.length < 3 || fps <= 0) {
      return (rrIntervals: <double>[], selectedWindowSec: 0.75);
    }

    final roiResult = PeakDetector.findPeaksROI(_fullFilteredSignal, fps);
    final rrIntervals = _peakDetector.peaksToRRIntervalsInterpolated(
        roiResult.interpolatedPeaks, fps);

    return (
      rrIntervals: rrIntervals,
      selectedWindowSec: roiResult.selectedWindowSec,
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

  int _nowMicros() {
    if (!_frameStopwatch.isRunning) _frameStopwatch.start();
    return _frameStopwatch.elapsedMicroseconds;
  }

}
