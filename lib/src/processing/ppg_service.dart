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
  final List<double> _fullRawIntensity = [];
  final List<bool> _fullFingerPresent = [];
  final List<int> _fullFrameMicros = [];
  static const PeakDetector _peakDetector = PeakDetector();
  final Stopwatch _frameStopwatch = Stopwatch();
  bool _buffersResized = false;
  int _lastReportedPeakCount = 0;
  ButterworthBandpassFilter? _butterworthFilter;

  // DEV TOOLING — last-frame data exposed for recording
  int _lastFrameMicros = 0;
  double _lastMeanR = 0, _lastMeanG = 0, _lastMeanB = 0;

  int get lastFrameMicros => _lastFrameMicros;
  int get sessionElapsedMicros => _nowMicros();
  double get lastMeanR => _lastMeanR;
  double get lastMeanG => _lastMeanG;
  double get lastMeanB => _lastMeanB;
  double get effectiveFPS => _effectiveFrameRate();
  int get fullFilteredSignalLength => _fullFilteredSignal.length;

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
    _fullRawIntensity.clear();
    _fullFingerPresent.clear();
    _fullFrameMicros.clear();
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
    _fullRawIntensity.clear();
    _fullFingerPresent.clear();
    _fullFrameMicros.clear();
    _frameRateDetector.reset();
    _frameStopwatch.stop();
    _buffersResized = false;
    _lastReportedPeakCount = 0;
    _butterworthFilter?.reset();
    _butterworthFilter = null;
  }

  /// DEV TOOLING — force the frame-rate detector to a known FPS and
  /// immediately initialise the Butterworth filter at that rate.
  /// Call before feeding any samples during replay so the filter,
  /// buffer sizing, and all FPS-dependent gates match the live session
  /// from frame 0 — no warmup phase, no detection ambiguity.
  void setDeterministicFPS(double fps) {
    _frameRateDetector.setDeterministicFPS(fps);
    _resizeBuffersIfNeeded(fps);
    _butterworthFilter ??= ButterworthBandpassFilter(sampleRate: fps);
  }

  /// Clear signal buffers and peak tracking state.
  /// Call when starting a new measurement phase to discard stale data.
  /// Preserves frame rate detection (which took time to stabilise).
  void clearSignalBuffers() {
    _rawBuffer.clear();
    _filteredBuffer.clear();
    _fullFilteredSignal.clear();
    _fullRawIntensity.clear();
    _fullFingerPresent.clear();
    _fullFrameMicros.clear();
    _lastReportedPeakCount = 0;
    _butterworthFilter?.reset();
  }

  /// Process a single camera frame synchronously and return the current signal state.
  PPGSignal processSingleFrame(CameraImage image) {
    // Record frame timing
    final micros = _nowMicros();
    _frameRateDetector.recordFrameMicros(micros);
    final fps = _effectiveFrameRate();
    _resizeBuffersIfNeeded(fps);

    // Extract RGB means (single pixel iteration)
    double meanR = 0, meanG = 0, meanB = 0;
    try {
      final rgb = _processor.extractRGBMeans(image);
      meanR = rgb.meanR;
      meanG = rgb.meanG;
      meanB = rgb.meanB;
    } catch (e) {
      return PPGSignal(
        rawIntensity: 0.0,
        filteredIntensity: 0.0,
        rrIntervals: [],
        quality: SignalQuality.poor,
        timestamp: DateTime.now(),
        frameRate: _frameRateDetector.fps,
        isFPSStable: _frameRateDetector.isStable,
        fingerDetected: false,
      );
    }

    // Store for recording
    _lastFrameMicros = micros;
    _lastMeanR = meanR;
    _lastMeanG = meanG;
    _lastMeanB = meanB;

    return _processExtractedData(meanR, meanG, meanB, fps);
  }

  /// DEV TOOLING — process a pre-extracted sample for replay.
  /// Follows the exact same pipeline as processSingleFrame.
  PPGSignal processReplaySample(
      int timestampMicros, double meanR, double meanG, double meanB) {
    _lastFrameMicros = timestampMicros;
    _frameRateDetector.recordFrameMicros(timestampMicros);
    final fps = _effectiveFrameRate();
    _resizeBuffersIfNeeded(fps);
    return _processExtractedData(meanR, meanG, meanB, fps);
  }

  /// Shared processing pipeline for both live frames and replay samples.
  PPGSignal _processExtractedData(
      double meanR, double meanG, double meanB, double effectiveFPS) {
    final now = DateTime.now();

    // HSV Value (brightness) as PPG signal — validated by HRV4Training
    final intensity = SignalProcessor.rgbToHsvValue(meanR, meanG, meanB);

    _rawBuffer.add(intensity);

    // Need minimum samples before we can do anything useful
    final minSamples = effectiveFPS.round();
    if (!_rawBuffer.isFull && _rawBuffer.length < minSamples) {
      final fingerDetected =
          _qualityAssessor.isFingerPresentByColor(meanR, meanG, meanB);
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
      _butterworthFilter =
          ButterworthBandpassFilter(sampleRate: _frameRateDetector.fps);
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
    _fullRawIntensity.add(intensity);
    _fullFingerPresent.add(fingerDetected);
    _fullFrameMicros.add(_lastFrameMicros);

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
  /// the final RR-interval series, selected window, filtered signal, and peaks.
  /// Call at end-of-measurement for the definitive HRV computation.
  ///
  /// Peak detection is run per contiguous finger-present segment so that no
  /// RR interval spans a finger-off gap. Runs shorter than ~1.5 beats
  /// (1.5 * fps samples) are skipped as too short for a reliable beat.
  ({
    List<double> rrIntervals,
    double selectedWindowSec,
    List<double> filteredSignal,
    List<int> peakIndices,
    List<double> interpolatedPeaks,
  }) computeFinalRRIntervals() {
    final fps = _effectiveFrameRate();
    if (_fullFilteredSignal.length < 3 || fps <= 0) {
      return (
        rrIntervals: <double>[],
        selectedWindowSec: 0.75,
        filteredSignal: <double>[],
        peakIndices: <int>[],
        interpolatedPeaks: <double>[],
      );
    }

    final runs = _findFingerPresentRuns(
        _fullFingerPresent, 0, _fullRawIntensity.length, fps);

    final allRR = <double>[];
    final allPeakIndices = <int>[];
    final allInterpolatedPeaks = <double>[];

    for (final (start, length) in runs) {
      final segment = _fullRawIntensity.sublist(start, start + length);
      final peaks =
          PeakDetector.findPeaksAMPD(segment, fps);

      // Offset peaks back to full-signal coordinates
      for (final p in peaks) {
        allPeakIndices.add(p + start);
        allInterpolatedPeaks.add((p + start).toDouble());
      }

      // RR intervals within this run only
      final segRR = _peakDetector.peaksToRRIntervals(peaks, fps);
      allRR.addAll(segRR);
    }

    return (
      rrIntervals: allRR,
      selectedWindowSec: 0.75,
      filteredSignal: List<double>.from(_fullFilteredSignal),
      peakIndices: allPeakIndices,
      interpolatedPeaks: allInterpolatedPeaks,
    );
  }

  /// Same as [computeFinalRRIntervals] but uses the diagnostics variant of
  /// the detector, capturing every intermediate stage. The algorithm is the
  /// same shared core — peaks and RR will be identical.
  ({
    List<double> rrIntervals,
    List<int> peakIndices,
    Map<String, dynamic> diagnostics,
  }) computeFinalRRIntervalsWithDiagnostics({
    required int clearBufferAtFrame,
  }) {
    final fps = _effectiveFrameRate();
    if (_fullFilteredSignal.length < 3 || fps <= 0) {
      return (
        rrIntervals: <double>[],
        peakIndices: <int>[],
        diagnostics: <String, dynamic>{},
      );
    }

    final runs = _findFingerPresentRuns(
        _fullFingerPresent, 0, _fullRawIntensity.length, fps);

    // Build segment info for ALL runs (including skipped ones)
    final allSegments = <Map<String, dynamic>>[];
    final minRunLen = (1.5 * fps).round();
    {
      // Walk the full mask to find all runs, including short ones
      int runStart = -1;
      for (int i = 0; i < _fullRawIntensity.length; i++) {
        final present = i < _fullFingerPresent.length ? _fullFingerPresent[i] : true;
        if (present) {
          if (runStart < 0) runStart = i;
        } else {
          if (runStart >= 0) {
            final len = i - runStart;
            allSegments.add({
              'start': runStart,
              'end': runStart + len,
              'usedForDetection': len >= minRunLen,
            });
            runStart = -1;
          }
        }
      }
      if (runStart >= 0) {
        final len = _fullRawIntensity.length - runStart;
        allSegments.add({
          'start': runStart,
          'end': runStart + len,
          'usedForDetection': len >= minRunLen,
        });
      }
    }

    final allRR = <double>[];
    final allPeakIndices = <int>[];
    final perSegment = <Map<String, dynamic>>[];

    for (final (start, length) in runs) {
      final segment = _fullRawIntensity.sublist(start, start + length);
      final diag = SegmentDiagnostics()
        ..start = start
        ..end = start + length;
      final peaks = PeakDetector.findPeaksAMPD(segment, fps);

      for (final p in peaks) {
        allPeakIndices.add(p + start);
      }

      final segRR = _peakDetector.peaksToRRIntervals(peaks, fps);
      allRR.addAll(segRR);
      perSegment.add(diag.toJson());
    }

    // cameraPeakSessionMicros — real per-frame timestamp at each peak index
    final cameraPeakSessionMicros = <int>[];
    for (final idx in allPeakIndices) {
      if (idx < _fullFrameMicros.length) {
        cameraPeakSessionMicros.add(_fullFrameMicros[idx]);
      }
    }

    final diagnostics = <String, dynamic>{
      'meta': {
        'fps': fps,
        'sampleCount': _fullRawIntensity.length,
        'clearBufferAtFrame': clearBufferAtFrame,
        'detectionLowHz': kDetectionLowHz,
        'detectionHighHz': kDetectionHighHz,
        'minRRIntervalMs': kMinRRIntervalMs,
        'amplitudeGatePercentile': 40,
        'amplitudeGateFraction': 0.5,
        'periodMinSpacingMs': 250,
        'periodUpperFraction': 0.7,
        'refractoryFraction': 0.55,
      },
      'fullRawIntensity': List<double>.from(_fullRawIntensity),
      'fullFingerPresent': List<bool>.from(_fullFingerPresent),
      'segments': allSegments,
      'perSegment': perSegment,
      'cameraPeakIndicesFull': allPeakIndices,
      'cameraPeakSessionMicros': cameraPeakSessionMicros,
      'detectedRRraw': allRR,
      // detectedRRfinal, artifactRejectedCount, resultsScreenRRfinal,
      // resultsScreenBeatCount, diagnosticsMatchResultsScreen — filled by caller
      // after running the artifact filter
    };

    return (
      rrIntervals: allRR,
      peakIndices: allPeakIndices,
      diagnostics: diagnostics,
    );
  }

  /// Run ROI detection on a trailing window of the filtered signal for
  /// live BPM computation. Returns RR intervals and peak indices mapped
  /// to full-signal coordinates (for waveform beat-marker display).
  /// Called at ~1 Hz from the UI; the window caps computation cost.
  ///
  /// Peak detection is segmented by finger presence — no RR spans a gap.
  ({
    List<double> rrIntervals,
    List<int> peakIndicesInFullSignal,
  }) computeRollingWindowDetection({int windowSeconds = 15}) {
    final fps = _effectiveFrameRate();
    final windowSamples = (windowSeconds * fps).round();
    final signalLen = _fullRawIntensity.length;

    if (signalLen < 3 || fps <= 0) {
      return (rrIntervals: <double>[], peakIndicesInFullSignal: <int>[]);
    }

    final startIdx =
        signalLen > windowSamples ? signalLen - windowSamples : 0;
    final windowLen = signalLen - startIdx;

    final runs = _findFingerPresentRuns(
        _fullFingerPresent, startIdx, windowLen, fps);

    final allRR = <double>[];
    final allPeaks = <int>[];

    for (final (runStart, runLen) in runs) {
      final segment =
          _fullRawIntensity.sublist(runStart, runStart + runLen);
      final peaks =
          PeakDetector.findPeaksAMPD(segment, fps);
      final segRR = _peakDetector.peaksToRRIntervals(peaks, fps);
      allRR.addAll(segRR);
      for (final p in peaks) {
        allPeaks.add(p + runStart);
      }
    }

    return (
      rrIntervals: allRR,
      peakIndicesInFullSignal: allPeaks,
    );
  }

  /// Find contiguous runs of finger-present (true) samples within a slice
  /// of [mask] starting at [sliceStart] for [sliceLen] samples. Runs shorter
  /// than 1.5 * fps are skipped (too short for a reliable beat).
  /// Returns a list of (startIndex, length) in full-signal coordinates.
  static List<(int, int)> _findFingerPresentRuns(
      List<bool> mask, int sliceStart, int sliceLen, double fps) {
    final minRunLen = (1.5 * fps).round();
    final runs = <(int, int)>[];
    final sliceEnd = sliceStart + sliceLen;

    // Guard: if mask is shorter than signal (e.g. early samples before
    // quality assessment), treat missing entries as finger-present to
    // preserve backward compatibility.
    int runStart = -1;
    for (int i = sliceStart; i < sliceEnd; i++) {
      final present = i < mask.length ? mask[i] : true;
      if (present) {
        if (runStart < 0) runStart = i;
      } else {
        if (runStart >= 0) {
          final len = i - runStart;
          if (len >= minRunLen) runs.add((runStart, len));
          runStart = -1;
        }
      }
    }
    // Close trailing run
    if (runStart >= 0) {
      final len = sliceEnd - runStart;
      if (len >= minRunLen) runs.add((runStart, len));
    }

    return runs;
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
