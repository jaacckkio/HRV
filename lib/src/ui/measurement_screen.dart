import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../processing/ppg_service.dart';
import '../processing/hrv_calculator.dart';
import '../models/ppg_signal.dart';
import '../camera/camera_control.dart';
import '../recording/ppg_recording.dart';
import 'widgets/waveform_painter.dart';
import 'widgets/finger_guide_animation.dart';
import '../polar/polar_h10_service.dart';
import 'results_screen.dart';

/// Set to true to show developer scaffolding (FPS line, record/replay
/// toolbar, RR history card, debug panels). Set to false for production.
const bool kShowDevTools = true;

// TODO: Apply Mont font family when the host team adds it to the asset bundle.
// Using system default font for now.

// --- Vagally Better design system ---
const Color _navy = Color(0xFF02427A);
const Color _teal = Color(0xFF06A3B7);
// ignore: unused_element
const Color _lightBlue = Color(0xFF8ECAE9);
const Color _success = Color(0xFF7ACDA0);
const Color _error = Color(0xFFE57373);
const Color _surface = Color(0xFFF2F2F7);
const Color _border = Color(0xFFD1D5DB);
const Color _textPrimary = Color(0xFF02427A);
const Color _textSecondary = Color(0xFF64748B);

class MeasurementScreen extends StatefulWidget {
  const MeasurementScreen({super.key});

  @override
  State<MeasurementScreen> createState() => _MeasurementScreenState();
}

class _MeasurementScreenState extends State<MeasurementScreen>
    with TickerProviderStateMixin {
  CameraController? _controller;
  PPGService? _ppgService;

  // State
  PPGSignal? _currentSignal;
  String _status = 'Initializing camera...';
  bool _isScanning = false;
  bool _isTransitioning = false;
  int _timeLeft = 60;
  Timer? _timer;
  Timer? _uiUpdateTimer;
  bool _fingerFirstDetected = false;
  DateTime? _fingerDetectedTime;
  bool _exposureLocked = false;
  CameraLockResult? _nativeLockResult;
  DateTime? _measuringStartTime;
  bool _showingHelp = false;
  int _selectedDuration = 60; // seconds
  bool _showDurationPicker = false;
  AnimationController? _countdownController;

  // Data buffers for visualization
  final List<double> _filteredHistory = [];
  final List<double> _rrHistory = [];
  final List<double> _sessionRRIntervals = [];
  static const int _historyLimit = 750;

  // Live metrics — updated at 1 Hz via rolling ROI detection
  static const int _rollingWindowSeconds = 15;
  static const int _rmssdMinBeats = 20;
  double? _liveBPM;
  double? _liveRMSSD;
  List<int> _livePeakIndicesInFull = [];
  Timer? _liveMetricsTimer;

  // Stability-based reveal gating — metrics show "Measuring…" until settled
  static const int _bpmMinSeconds = 10;
  static const int _rmssdMinSeconds = 25;
  static const double _bpmSettleTolerance = 3.0; // ±3 bpm
  static const double _rmssdSettleTolerance = 10.0; // ±10 ms
  static const int _settleHistoryLen = 4; // last N 1 Hz readings
  bool _bpmSettled = false;
  bool _rmssdSettled = false;
  final List<double> _bpmHistory = [];
  final List<double> _rmssdHistory = [];

  // FPS diagnostic — requested vs delivered
  double _requestedFps = 0;

  // DEV TOOLING — recording state
  bool _isRecording = false;
  bool _isReplaying = false;
  final List<PPGFrameSample> _recordedSamples = [];
  int _recordClearAtFrame = -1;
  String? _recordStartWallClock;

  // DEV TOOLING — Polar H10 BLE
  PolarH10Service? _polarService;
  PolarConnectionState _polarState = PolarConnectionState.disconnected;
  String? _polarError;
  int _polarLatestHR = 0;
  int _polarRRCount = 0;
  DateTime _lastPolarUiTick = DateTime(0);
  bool _polarWasConnected = false; // true if Polar connected at any point this session

  // DEV TOOLING — live comparison metrics (computed at 1 Hz in _updateLiveMetrics)
  double? _polarBPM;
  HrvResult? _polarMetrics;
  HrvResult? _cameraMetrics; // full-session HRV for comparison panel

  // DEV TOOLING — Live (continuous) mode
  bool _continuousMode = false;
  int _elapsedSeconds = 0;

  // DEV TOOLING — switchable camera FPS (chosen while idle, applied at Start)
  int _selectedFps = 120;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      // Android requires a runtime CAMERA permission request before
      // CameraController.initialize() — iOS handles it via Info.plist.
      if (Platform.isAndroid) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          if (mounted) {
            setState(() => _status = 'Camera permission denied');
          }
          return;
        }
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _status = 'No cameras found.');
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // iOS works better with bgra8888, Android with yuv420
      final imageFormat = Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420;

      _controller = CameraController(
        camera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: imageFormat,
      );
      await _controller!.initialize();
      if (mounted) {
        setState(() => _status = 'Ready. Tap START to measure.');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera error: $e');
    }
  }

  void _toggleScanning() {
    if (_isTransitioning) return;
    _isScanning ? _stopProcessing() : _startProcessing();
  }

  Future<void> _startProcessing() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isTransitioning) return;
    _isTransitioning = true;

    // Create fresh PPG service each session
    _ppgService?.dispose();
    _ppgService = PPGService();

    setState(() {
      _isScanning = true;
      _timeLeft = _selectedDuration;
      _showDurationPicker = false;
      _filteredHistory.clear();
      _rrHistory.clear();
      _sessionRRIntervals.clear();
      _liveBPM = null;
      _liveRMSSD = null;
      _livePeakIndicesInFull = [];
      _bpmSettled = false;
      _rmssdSettled = false;
      _bpmHistory.clear();
      _rmssdHistory.clear();
      _requestedFps = 0;
      _currentSignal = null;
      _status = 'Starting...';
      _fingerFirstDetected = false;
      _fingerDetectedTime = null;
      _exposureLocked = false;
      _nativeLockResult = null;
      _measuringStartTime = null;
      // Recording
      _recordedSamples.clear();
      _recordClearAtFrame = -1;
      _recordStartWallClock = null;
      // Polar
      _polarRRCount = 0;
      _polarWasConnected = _polarState == PolarConnectionState.connected;
      _polarBPM = null;
      _polarMetrics = null;
      _cameraMetrics = null;
      // Live mode
      _elapsedSeconds = 0;
    });

    // Clear Polar packets for fresh session
    _polarService?.clearPackets();

    _countdownController?.dispose();
    if (!_continuousMode) {
      _countdownController = AnimationController(
        vsync: this,
        duration: Duration(seconds: _selectedDuration),
      );
      _countdownController!.forward();
    } else {
      _countdownController = null;
    }

    WakelockPlus.enable();

    // Request frame rate via native plugin.
    // Must be called after controller.initialize() sets up the AVCaptureSession
    // but before startImageStream so the format is active when frames arrive.
    if (kShowDevTools) {
      _requestedFps = await CameraControl.setFrameRate(_selectedFps);
    } else {
      _requestedFps = await CameraControl.setHighFrameRate();
    }
    debugPrint('Requested FPS: $_requestedFps');

    try {
      await _controller!.setFlashMode(FlashMode.torch);
    } catch (e) {
      debugPrint('Flash error: $e');
    }

    // Countdown timer (or count-up in continuous mode)
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isScanning) {
        if (_continuousMode) {
          setState(() => _elapsedSeconds++);
        } else {
          setState(() => _timeLeft--);
          if (_timeLeft <= 0) _stopProcessing();
        }
      }
    });

    // UI update at 10 Hz
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _isScanning) {
        setState(() {});
      }
    });

    // Live metrics at 1 Hz (rolling ROI detection for BPM + RMSSD)
    _liveMetricsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isScanning) _updateLiveMetrics();
    });

    // Start camera stream — process frames directly in callback
    try {
      await _controller!.startImageStream((CameraImage image) {
        _processFrame(image);
      });
    } catch (e) {
      debugPrint('Image stream error: $e');
      _isTransitioning = false;
      await _stopProcessing();
      return;
    }

    _isTransitioning = false;
  }

  Future<void> _processFrame(CameraImage image) async {
    if (!_isScanning || _ppgService == null) return;

    try {
      final signal = _ppgService!.processSingleFrame(image);
      _currentSignal = signal;

      // DEV TOOLING — capture per-frame data for recording
      if (_isRecording) {
        _recordedSamples.add(PPGFrameSample(
          t: _ppgService!.lastFrameMicros,
          r: _ppgService!.lastMeanR,
          g: _ppgService!.lastMeanG,
          b: _ppgService!.lastMeanB,
        ));
      }

      // Accumulate visualization data
      _filteredHistory.add(signal.filteredIntensity);
      if (_filteredHistory.length > _historyLimit) _filteredHistory.removeAt(0);

      // === Phase 1: Waiting for finger ===
      if (!_fingerFirstDetected) {
        if (signal.fingerDetected) {
          _fingerFirstDetected = true;
          _fingerDetectedTime = DateTime.now();
          _status = 'Finger detected — calibrating...';
        } else {
          _status = 'Place finger over camera and flash';
        }
        return;
      }

      // === Phase 2: Calibrating (2 seconds after finger first detected) ===
      if (!_exposureLocked) {
        final elapsed = DateTime.now().difference(_fingerDetectedTime!);
        if (elapsed.inMilliseconds < 2000) {
          _status = 'Calibrating...';
          return;
        }

        // 2 seconds have passed — lock exposure, focus, and white balance
        // via native AVFoundation for reliable hardware-level lock
        _exposureLocked = true;
        _nativeLockResult = await CameraControl.lockCameraSettings();
        debugPrint('Native camera lock: '
            'exp=${_nativeLockResult!.exposureLocked} '
            'focus=${_nativeLockResult!.focusLocked} '
            'wb=${_nativeLockResult!.whiteBalanceLocked} '
            'err=${_nativeLockResult!.error}');
        _ppgService?.clearSignalBuffers();
        _filteredHistory.clear();
        // DEV TOOLING — mark clear point
        if (_isRecording) {
          _recordClearAtFrame = _recordedSamples.length;
        }
        _status = 'Measuring...';
      }

      // === Phase 3: Measuring (exposure locked, collecting data) ===
      _measuringStartTime ??= DateTime.now();

      // DEV TOOLING — capture wall-clock start for Polar alignment
      if (_isRecording) {
        _recordStartWallClock ??=
            DateTime.now().toUtc().toIso8601String();
      }

      final measuringElapsed = DateTime.now().difference(_measuringStartTime!);
      if (measuringElapsed.inMilliseconds <= 5000) {
        _status = 'Stabilising signal...';
      } else if (!signal.fingerDetected) {
        _status = 'No finger detected — place finger over camera and flash';
      } else {
        _status = switch (signal.quality) {
          SignalQuality.good => 'Good signal \u00b7 keep still',
          SignalQuality.fair => 'Fair signal \u00b7 keep finger steady',
          SignalQuality.poor => 'Adjusting \u00b7 keep finger steady',
        };
      }

      if (measuringElapsed.inMilliseconds > 5000) {
        for (final rr in signal.rrIntervals) {
          _rrHistory.add(rr);
          _sessionRRIntervals.add(rr);
          if (_rrHistory.length > 20) _rrHistory.removeAt(0);
        }
      }
    } catch (_) {}
  }

  Future<void> _stopProcessing() async {
    if (_isTransitioning) return;
    _isTransitioning = true;

    _timer?.cancel();
    _uiUpdateTimer?.cancel();
    _liveMetricsTimer?.cancel();
    _timer = null;
    _uiUpdateTimer = null;
    _liveMetricsTimer = null;
    _countdownController?.stop();

    _isScanning = false;

    if (_controller != null && _controller!.value.isInitialized) {
      try {
        if (_controller!.value.isStreamingImages) {
          await _controller!.stopImageStream();
        }
        await _controller!.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint('Stop camera error: $e');
      }
    }

    if (_exposureLocked) {
      await CameraControl.unlockCameraSettings();
      debugPrint('Native camera unlock called');
      _exposureLocked = false;
    }

    WakelockPlus.disable();

    if (mounted && _ppgService != null) {
      final finalResult = _ppgService!.computeFinalRRIntervals();
      final rrIntervals = finalResult.rrIntervals;

      if (rrIntervals.isNotEmpty) {
        final hrvResult = HrvCalculator.compute(
          rrIntervals,
          selectedMovingAvgWindow: finalResult.selectedWindowSec,
        );

        // DEV TOOLING — save recording if enabled
        if (_isRecording && _recordedSamples.isNotEmpty) {
          _saveRecording(finalResult);
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ResultsScreen(
              hrvResult: hrvResult,
              rrIntervals: List<double>.from(rrIntervals),
              fullFilteredSignal: finalResult.filteredSignal,
              fullPeakIndices: finalResult.peakIndices,
              signalFps: _ppgService!.effectiveFPS,
            ),
          ),
        );
        return;
      }
    }

    if (mounted) {
      setState(() {
        _status = 'No heartbeats detected. Tap Start to retry.';
      });
    }
    _isTransitioning = false;
  }

  /// DEV TOOLING — save the recording to JSON.
  void _saveRecording(
    // The final result from computeFinalRRIntervals
    ({
      List<double> rrIntervals,
      double selectedWindowSec,
      List<double> filteredSignal,
      List<int> peakIndices,
      List<double> interpolatedPeaks,
    }) finalResult,
  ) {
    final fps = _ppgService?.effectiveFPS ?? 24.0;

    // Build RR beats with wall-clock offsets for Polar alignment
    final beats = <RRBeat>[];
    final peaks = finalResult.interpolatedPeaks;
    final rrList = finalResult.rrIntervals;
    for (int i = 0; i < peaks.length; i++) {
      final offsetMs = (peaks[i] / fps) * 1000.0;
      final rrMs = i > 0 && i - 1 < rrList.length ? rrList[i - 1] : 0.0;
      beats.add(RRBeat(beatOffsetMs: offsetMs, rrMs: rrMs));
    }

    // Polar packets — save raw data if any exist, regardless of current state
    final polarPkts = _polarService != null && _polarService!.packets.isNotEmpty
        ? _polarService!.packets.map((p) => p.toJson()).toList()
        : null;

    final recording = PPGRecording(
      startWallClockUtc:
          _recordStartWallClock ?? DateTime.now().toUtc().toIso8601String(),
      fps: fps,
      requestedFps: _requestedFps,
      clearBufferAtFrame: _recordClearAtFrame,
      samples: List.from(_recordedSamples),
      finalRRIntervals: beats,
      polarConnected: _polarWasConnected,
      polarPackets: polarPkts,
    );

    recording.save().then((_) {
      debugPrint(
          'Recording saved: ${_recordedSamples.length} frames, '
          '${beats.length} beats');
    }).catchError((e) {
      debugPrint('Failed to save recording: $e');
    });
  }

  /// DEV TOOLING — replay the last recording through the same pipeline.
  Future<void> _replayRecording() async {
    if (_isReplaying || _isScanning) return;
    setState(() {
      _isReplaying = true;
      _status = 'Loading recording...';
    });

    final recording = await PPGRecording.load();
    if (recording == null) {
      if (mounted) {
        setState(() {
          _isReplaying = false;
          _status = 'No recording found.';
        });
      }
      return;
    }

    setState(() => _status = 'Replaying ${recording.samples.length} frames...');

    // Run replay in a microtask to avoid blocking the UI thread entirely
    await Future.delayed(const Duration(milliseconds: 50));

    final replayService = PPGService();
    // Force the stored FPS so the Butterworth filter, buffer sizing, and
    // all FPS-dependent gates match the live session from frame 0.
    replayService.setDeterministicFPS(recording.fps);

    try {
      for (int i = 0; i < recording.samples.length; i++) {
        final s = recording.samples[i];
        replayService.processReplaySample(s.t, s.r, s.g, s.b);

        // Clear at the same point as the live measurement
        if (recording.clearBufferAtFrame > 0 &&
            i == recording.clearBufferAtFrame - 1) {
          replayService.clearSignalBuffers();
        }
      }

      final finalResult = replayService.computeFinalRRIntervals();
      final rrIntervals = finalResult.rrIntervals;

      if (rrIntervals.isEmpty) {
        if (mounted) {
          setState(() {
            _isReplaying = false;
            _status = 'Replay produced no heartbeats.';
          });
        }
        replayService.dispose();
        return;
      }

      final hrvResult = HrvCalculator.compute(
        rrIntervals,
        selectedMovingAvgWindow: finalResult.selectedWindowSec,
      );

      replayService.dispose();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ResultsScreen(
              hrvResult: hrvResult,
              rrIntervals: List<double>.from(rrIntervals),
              fullFilteredSignal: finalResult.filteredSignal,
              fullPeakIndices: finalResult.peakIndices,
              signalFps: recording.fps,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Replay error: $e');
      replayService.dispose();
      if (mounted) {
        setState(() {
          _isReplaying = false;
          _status = 'Replay failed: $e';
        });
      }
    }
  }

  void _showHelpOverlay() {
    setState(() => _showingHelp = true);
  }

  void _hideHelpOverlay() {
    setState(() => _showingHelp = false);
  }

  // DEV TOOLING — Polar H10 BLE
  void _polarConnect() {
    if (_polarService != null) return;
    _polarService = PolarH10Service(
      nowMicros: () => _ppgService?.sessionElapsedMicros ?? 0,
    );
    _polarService!.onStateChanged = (s) {
      if (!mounted) return;
      if (s == PolarConnectionState.connected) _polarWasConnected = true;
      setState(() {
        _polarState = s;
        _polarError = _polarService?.errorMessage;
      });
    };
    _polarService!.onRRPacket = (packet) {
      if (!mounted) return;
      _polarLatestHR = packet.hr;
      _polarRRCount += packet.rrIntervalsMs.length;
      final now = DateTime.now();
      if (now.difference(_lastPolarUiTick).inMilliseconds >= 300) {
        _lastPolarUiTick = now;
        setState(() {});
      }
    };
    _polarService!.startScan();
  }

  Future<void> _polarDisconnect() async {
    await _polarService?.dispose();
    _polarService = null;
    if (mounted) {
      setState(() {
        _polarState = PolarConnectionState.disconnected;
        _polarError = null;
        _polarLatestHR = 0;
        _polarRRCount = 0;
      });
    }
  }

  /// Recompute live BPM, RMSSD, and waveform peak markers at ~1 Hz.
  /// Uses the same PeakDetector.findPeaksROI and HrvCalculator/artifact-filter
  /// pipeline as the final end-of-measurement result.
  void _updateLiveMetrics() {
    if (_ppgService == null || !_exposureLocked) return;

    final fingerNow = _currentSignal?.fingerDetected ?? false;

    // Suspend all camera metrics while finger is absent — avoids showing
    // stale or noise-derived values. When the finger returns, settle checks
    // will re-gate display. Polar side is independent and keeps streaming.
    if (!fingerNow) {
      _liveBPM = null;
      _liveRMSSD = null;
      _cameraMetrics = null;
      _bpmSettled = false;
      _rmssdSettled = false;
      _bpmHistory.clear();
      _rmssdHistory.clear();
      // Skip camera computation but still compute Polar below
    }

    final measElapsed = _measuringStartTime != null
        ? DateTime.now().difference(_measuringStartTime!).inSeconds
        : 0;

    if (fingerNow) {
      // BPM — from trailing-window ROI detection (15 s window)
      final windowResult = _ppgService!.computeRollingWindowDetection(
          windowSeconds: _rollingWindowSeconds);
      _livePeakIndicesInFull = windowResult.peakIndicesInFullSignal;

      if (windowResult.rrIntervals.isNotEmpty) {
        double sum = 0;
        for (final rr in windowResult.rrIntervals) {
          sum += rr;
        }
        _liveBPM = 60000.0 / (sum / windowResult.rrIntervals.length);

        // BPM settle check
        if (!_bpmSettled && _liveBPM != null) {
          _bpmHistory.add(_liveBPM!);
          if (_bpmHistory.length > _settleHistoryLen) {
            _bpmHistory.removeAt(0);
          }
          if (measElapsed >= _bpmMinSeconds &&
              _bpmHistory.length >= _settleHistoryLen) {
            final spread = _bpmHistory.reduce(max) - _bpmHistory.reduce(min);
            if (spread <= _bpmSettleTolerance * 2) {
              _bpmSettled = true;
            }
          }
        }
      }

      // RMSSD — from full accumulated signal, through the same artifact filter
      // and gap-aware RMSSD that HrvCalculator uses for the final result.
      final fullResult = _ppgService!.computeFinalRRIntervals();
      final allRR = fullResult.rrIntervals;

      if (allRR.length >= _rmssdMinBeats) {
        final hrvResult = HrvCalculator.compute(allRR);
        _cameraMetrics = hrvResult;
        if (hrvResult.rmssd > 0) {
          _liveRMSSD = hrvResult.rmssd;

          // RMSSD settle check
          if (!_rmssdSettled) {
            _rmssdHistory.add(_liveRMSSD!);
            if (_rmssdHistory.length > _settleHistoryLen) {
              _rmssdHistory.removeAt(0);
            }
            if (measElapsed >= _rmssdMinSeconds &&
                _rmssdHistory.length >= _settleHistoryLen) {
              final spread =
                  _rmssdHistory.reduce(max) - _rmssdHistory.reduce(min);
              if (spread <= _rmssdSettleTolerance * 2) {
                _rmssdSettled = true;
              }
            }
          }
        }
      }
    } // end fingerNow

    // DEV TOOLING — Polar metrics (same artifact-filter + HrvCalculator path)
    if (kShowDevTools &&
        _polarService != null &&
        _polarState == PolarConnectionState.connected) {
      final polarRR = _polarService!.allRRIntervalsMs;

      // BPM — trailing ~15 s window (same semantics as camera's rolling window)
      if (polarRR.isNotEmpty) {
        double windowSum = 0;
        int windowCount = 0;
        for (int i = polarRR.length - 1; i >= 0; i--) {
          windowSum += polarRR[i];
          windowCount++;
          if (windowSum >= _rollingWindowSeconds * 1000) break;
        }
        if (windowCount > 0) {
          _polarBPM = 60000.0 / (windowSum / windowCount);
        }
      }

      // RMSSD / SDNN / meanRR / beats — full session through HrvCalculator
      if (polarRR.length >= _rmssdMinBeats) {
        _polarMetrics = HrvCalculator.compute(polarRR);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _uiUpdateTimer?.cancel();
    _liveMetricsTimer?.cancel();
    _countdownController?.dispose();
    _controller?.dispose();
    _ppgService?.dispose();
    _polarService?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // BPM display string (settle-gated — logic unchanged)
    String hrDisplay = '--';
    if (_isScanning && _exposureLocked && !_bpmSettled) {
      hrDisplay = 'Measuring\u2026';
    } else if (_bpmSettled && _liveBPM != null) {
      hrDisplay = '${_liveBPM!.round()}';
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('HRV Tracking'),
        centerTitle: true,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: _showHelpOverlay,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.2),
                ),
                child: const Center(
                  child: Text(
                    '?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _buildDurationSelector(),
                  const SizedBox(height: 24),
                  _buildHeroCircle(hrDisplay),
                  const SizedBox(height: 16),
                  _buildStatusLine(),
                  if (kShowDevTools && _isScanning) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Stream FPS: ${(_currentSignal?.frameRate ?? 0).toStringAsFixed(0)}'
                      ' (requested ${_requestedFps.toStringAsFixed(0)})',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _teal),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (kShowDevTools) ...[
                    const SizedBox(height: 8),
                    _buildDevToolbar(),
                    const SizedBox(height: 6),
                    _buildPolarStrip(),
                    const SizedBox(height: 6),
                    _buildFpsPicker(),
                  ],
                  const SizedBox(height: 20),
                  _buildPulseWaveformCard(),
                  const SizedBox(height: 12),
                  if (kShowDevTools &&
                      _isScanning &&
                      _polarState == PolarConnectionState.connected)
                    _buildComparisonPanel()
                  else
                    _buildRmssdStrip(),
                  if (kShowDevTools) ...[
                    const SizedBox(height: 12),
                    _buildRRHistoryCard(),
                  ],
                  const SizedBox(height: 100), // room for start button
                ],
              ),
            ),
            // Start button — State A only (or Stop in continuous mode)
            if (!_isScanning) _buildStartButton(),
            if (_isScanning && _continuousMode) _buildStopButton(),
            // Duration picker overlay
            if (_showDurationPicker && !_isScanning) _buildDurationPicker(),
            // Help overlay
            if (_showingHelp) _buildHelpOverlay(context),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // WIDGET BUILDERS — New / Restyled
  // ---------------------------------------------------------------------------

  Widget _buildDurationSelector() {
    final label = _continuousMode
        ? 'Live'
        : _selectedDuration >= 60
            ? '${_selectedDuration ~/ 60}m'
            : '${_selectedDuration}s';
    final active = !_isScanning;
    final color = active ? _teal : _textSecondary.withOpacity(0.4);

    return GestureDetector(
      onTap: active
          ? () => setState(() => _showDurationPicker = !_showDurationPicker)
          : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 18, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: color)),
          if (active) ...[
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, size: 18, color: color),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroCircle(String hrDisplay) {
    const heroSize = 220.0;
    const ringWidth = 6.0;
    const innerSize = heroSize - ringWidth * 2 - 8;

    Widget buildCircle(double progress) {
      final cameraReady =
          _controller != null && _controller!.value.isInitialized;

      return Center(
        child: GestureDetector(
          onTap: _isScanning ? _stopProcessing : null,
          child: SizedBox(
            width: heroSize,
            height: heroSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Ring
                CustomPaint(
                  size: const Size(heroSize, heroSize),
                  painter: _HeroRingPainter(
                    progress: progress,
                    isActive: _isScanning,
                    ringWidth: ringWidth,
                  ),
                ),
                // Camera preview (circular clip)
                ClipOval(
                  child: Container(
                    width: innerSize,
                    height: innerSize,
                    color: _surface,
                    child: cameraReady
                        ? CameraPreview(_controller!)
                        : const Center(
                            child: CircularProgressIndicator(
                                color: _teal, strokeWidth: 2)),
                  ),
                ),
                // Dark overlay for text readability during measurement
                if (_isScanning)
                  ClipOval(
                    child: Container(
                      width: innerSize,
                      height: innerSize,
                      color: Colors.black.withOpacity(0.35),
                    ),
                  ),
                // State A: hint text
                if (!_isScanning && cameraReady)
                  Text(
                    'Place finger\non camera',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.white.withOpacity(0.9),
                      fontWeight: FontWeight.w500,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 6)
                      ],
                    ),
                  ),
                // State B: BPM + countdown
                if (_isScanning)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontSize: _bpmSettled ? 44 : 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        child: Text(
                            _bpmSettled ? hrDisplay : 'Measuring\u2026'),
                      ),
                      if (_bpmSettled)
                        const Text('BPM',
                            style: TextStyle(
                                fontSize: 14,
                                color: Colors.white70,
                                fontWeight: FontWeight.w500)),
                      const SizedBox(height: 10),
                      Text(
                        _continuousMode
                            ? _formatElapsed()
                            : _formatTimeLeft(),
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withOpacity(0.55)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isScanning && !_continuousMode && _countdownController != null) {
      return AnimatedBuilder(
        animation: _countdownController!,
        builder: (context, child) {
          return buildCircle(1.0 - _countdownController!.value);
        },
      );
    }
    return buildCircle(0.0);
  }

  Widget _buildStatusLine() {
    if (!_isScanning) {
      // State A — subtle ready / error message
      String display = _status;
      if (_status == 'Ready. Tap START to measure.') {
        display = 'Ready to measure';
      }
      return Text(display,
          style: const TextStyle(fontSize: 13, color: _textSecondary),
          textAlign: TextAlign.center);
    }

    // State B — coloured dot + status
    Color dotColor;
    if (_currentSignal == null || !_fingerFirstDetected) {
      dotColor = _textSecondary;
    } else if (!_currentSignal!.fingerDetected) {
      dotColor = _error;
    } else {
      dotColor = switch (_currentSignal!.quality) {
        SignalQuality.good => _success,
        SignalQuality.fair => const Color(0xFFFFA726),
        SignalQuality.poor => _error,
      };
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(_status,
              style: const TextStyle(fontSize: 13, color: _textSecondary),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _buildPulseWaveformCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Pulse',
              style: TextStyle(
                  fontSize: 12,
                  color: _textSecondary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          SizedBox(
            height: 100,
            child: _filteredHistory.isEmpty
                ? Center(child: Container(height: 1, color: _border))
                : CustomPaint(
                    painter:
                        WaveformPainter(_filteredHistory, _teal, const []),
                    child: Container(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRmssdStrip() {
    final display = _rmssdSettled && _liveRMSSD != null
        ? '${_liveRMSSD!.toStringAsFixed(1)} ms'
        : (_isScanning && _exposureLocked ? 'Measuring\u2026' : '\u2014');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: _cardDecoration(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Vagal Tone (HRV)',
              style: TextStyle(
                  fontSize: 14,
                  color: _textSecondary,
                  fontWeight: FontWeight.w500)),
          Text(display,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _textPrimary)),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return Positioned(
      left: 20,
      right: 20,
      bottom: 24,
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed:
              (_isTransitioning || _isReplaying) ? null : _startProcessing,
          style: ElevatedButton.styleFrom(
            backgroundColor: _teal,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade300,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          child: const Text('Start',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildStopButton() {
    return Positioned(
      left: 20,
      right: 20,
      bottom: 24,
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: _isTransitioning ? null : _stopProcessing,
          style: ElevatedButton.styleFrom(
            backgroundColor: _error,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade300,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          child: const Text('Stop',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  // DEV TOOLING — Camera vs Polar comparison panel
  Widget _buildComparisonPanel() {
    // Camera values — BPM reads from _liveBPM (same as hero circle)
    final camBPM =
        _bpmSettled && _liveBPM != null ? '${_liveBPM!.round()}' : '\u2014';
    final camRMSSD = _rmssdSettled && _liveRMSSD != null
        ? _liveRMSSD!.toStringAsFixed(1)
        : '\u2014';

    // Camera full-session HRV for SDNN / meanRR / beats (from 1 Hz update)
    final camSDNN = _cameraMetrics != null
        ? _cameraMetrics!.sdnn.toStringAsFixed(1)
        : '\u2014';
    final camMeanRR = _cameraMetrics != null
        ? _cameraMetrics!.meanRR.round().toString()
        : '\u2014';
    final camBeats = _cameraMetrics != null
        ? '${_cameraMetrics!.totalIntervals}'
        : '\u2014';

    // Polar values
    final polBPM =
        _polarBPM != null ? '${_polarBPM!.round()}' : '\u2014';
    final polRMSSD = _polarMetrics != null && _polarMetrics!.rmssd > 0
        ? _polarMetrics!.rmssd.toStringAsFixed(1)
        : '\u2014';
    final polSDNN = _polarMetrics != null && _polarMetrics!.sdnn > 0
        ? _polarMetrics!.sdnn.toStringAsFixed(1)
        : '\u2014';
    final polMeanRR = _polarMetrics != null && _polarMetrics!.meanRR > 0
        ? _polarMetrics!.meanRR.round().toString()
        : '\u2014';
    final polBeats = _polarMetrics != null
        ? '${_polarMetrics!.totalIntervals}'
        : '\u2014';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Camera vs Polar',
              style: TextStyle(
                  fontSize: 11,
                  color: _textSecondary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _comparisonRow(
            label: 'Camera',
            labelColor: _teal,
            bpm: camBPM,
            rmssd: camRMSSD,
            sdnn: camSDNN,
            meanRR: camMeanRR,
            beats: camBeats,
          ),
          const Divider(height: 12, thickness: 0.5, color: _border),
          _comparisonRow(
            label: 'Polar',
            labelColor: const Color(0xFF2E7D32),
            bpm: polBPM,
            rmssd: polRMSSD,
            sdnn: polSDNN,
            meanRR: polMeanRR,
            beats: polBeats,
          ),
        ],
      ),
    );
  }

  Widget _comparisonRow({
    required String label,
    required Color labelColor,
    required String bpm,
    required String rmssd,
    required String sdnn,
    required String meanRR,
    required String beats,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.bold, color: labelColor)),
        const SizedBox(height: 4),
        Row(
          children: [
            _metricCell('BPM', bpm),
            _metricCell('RMSSD', rmssd),
            _metricCell('SDNN', sdnn),
            _metricCell('RR', meanRR),
            _metricCell('Beats', beats),
          ],
        ),
      ],
    );
  }

  Widget _metricCell(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 9,
                  color: _textSecondary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: _textPrimary)),
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _border),
      boxShadow: [
        BoxShadow(
          color: _navy.withOpacity(0.06),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // WIDGET BUILDERS — Kept (dev-gated or shared)
  // ---------------------------------------------------------------------------

  // DEV TOOLING — toolbar with Record toggle, Replay, and file-access hint
  Widget _buildDevToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCC02)),
      ),
      child: Row(
        children: [
          const Text('REC',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF6D4C00))),
          const SizedBox(width: 4),
          SizedBox(
            height: 24,
            child: Switch(
              value: _isRecording,
              onChanged: _isScanning
                  ? null
                  : (v) => setState(() => _isRecording = v),
              activeColor: Colors.red,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 8),
          _devButton(
              'Replay',
              _isScanning || _isReplaying ? null : _replayRecording),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _isRecording
                  ? 'Recording ON'
                  : 'Files app: On My iPhone > Vagal HRV Camera',
              style:
                  const TextStyle(fontSize: 9, color: Color(0xFF6D4C00)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // DEV TOOLING — Polar H10 connection strip
  Widget _buildPolarStrip() {
    final stateLabel = switch (_polarState) {
      PolarConnectionState.disconnected => 'Not connected',
      PolarConnectionState.scanning => 'Scanning\u2026',
      PolarConnectionState.connecting =>
        'Connecting to ${_polarService?.deviceName ?? "Polar"}\u2026',
      PolarConnectionState.connected =>
        '${_polarService?.deviceName ?? "Polar"} \u2014 HR: $_polarLatestHR  RR: $_polarRRCount',
      PolarConnectionState.error => _polarError ?? 'Error',
    };

    final isError = _polarState == PolarConnectionState.error;
    final isConnected = _polarState == PolarConnectionState.connected;
    final isBusy = _polarState == PolarConnectionState.scanning ||
        _polarState == PolarConnectionState.connecting;

    final bgColor = isError
        ? const Color(0xFFFFEBEE)
        : isConnected
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFF3E5F5);
    final borderColor = isError
        ? const Color(0xFFE57373)
        : isConnected
            ? const Color(0xFF81C784)
            : const Color(0xFFCE93D8);
    final textColor = isError
        ? const Color(0xFFC62828)
        : isConnected
            ? const Color(0xFF2E7D32)
            : const Color(0xFF6A1B9A);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.bluetooth,
              size: 14,
              color: isConnected ? const Color(0xFF2E7D32) : textColor),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              stateLabel,
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: textColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          if (!isConnected && !isBusy)
            _devButton('Connect', _polarConnect),
          if (isConnected)
            _devButton('Disconnect', _polarDisconnect),
          if (isBusy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: textColor,
              ),
            ),
        ],
      ),
    );
  }

  // DEV TOOLING — camera FPS picker (30 / 60 / 120)
  Widget _buildFpsPicker() {
    const fpsOptions = [30, 60, 120];
    final enabled = !_isScanning;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCC02)),
      ),
      child: Row(
        children: [
          const Text('FPS',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF6D4C00))),
          const SizedBox(width: 8),
          for (final fps in fpsOptions) ...[
            GestureDetector(
              onTap: enabled
                  ? () => setState(() => _selectedFps = fps)
                  : null,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _selectedFps == fps
                      ? (enabled ? _teal : Colors.grey.shade400)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: _selectedFps == fps
                      ? null
                      : Border.all(
                          color: enabled
                              ? const Color(0xFF6D4C00).withOpacity(0.3)
                              : Colors.grey.shade300,
                        ),
                ),
                child: Text(
                  '$fps',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _selectedFps == fps
                        ? Colors.white
                        : (enabled
                            ? const Color(0xFF6D4C00)
                            : Colors.grey.shade400),
                  ),
                ),
              ),
            ),
            if (fps != fpsOptions.last) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _devButton(String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: onTap != null ? _teal : Colors.grey.shade400,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
      ),
    );
  }

  String _formatTimeLeft() {
    if (_timeLeft >= 60) {
      final mins = _timeLeft ~/ 60;
      final secs = _timeLeft % 60;
      return '$mins:${secs.toString().padLeft(2, '0')}';
    }
    return '${_timeLeft}s';
  }

  String _formatElapsed() {
    final mins = _elapsedSeconds ~/ 60;
    final secs = _elapsedSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  Widget _buildDurationPicker() {
    final options = [
      (duration: 60, label: '60 seconds', isLive: false),
      (duration: 120, label: '2 minutes', isLive: false),
      (duration: 180, label: '3 minutes', isLive: false),
      if (kShowDevTools)
        (duration: 0, label: 'Live (continuous)', isLive: true),
    ];
    final totalOptions = options.length;

    return Positioned(
      top: 40,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(minWidth: 160),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: _navy.withOpacity(0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < totalOptions; i++)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      if (options[i].isLive) {
                        _continuousMode = true;
                      } else {
                        _continuousMode = false;
                        _selectedDuration = options[i].duration;
                      }
                      _showDurationPicker = false;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: options[i].isLive
                          ? (_continuousMode
                              ? _teal.withOpacity(0.08)
                              : Colors.transparent)
                          : (!_continuousMode &&
                                  _selectedDuration == options[i].duration
                              ? _teal.withOpacity(0.08)
                              : Colors.transparent),
                      border: i < totalOptions - 1
                          ? const Border(
                              bottom: BorderSide(color: _border, width: 0.5))
                          : null,
                      borderRadius: i == 0
                          ? const BorderRadius.vertical(
                              top: Radius.circular(12))
                          : i == totalOptions - 1
                              ? const BorderRadius.vertical(
                                  bottom: Radius.circular(12))
                              : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          options[i].label,
                          style: TextStyle(
                            color: (options[i].isLive
                                    ? _continuousMode
                                    : (!_continuousMode &&
                                        _selectedDuration ==
                                            options[i].duration))
                                ? _teal
                                : _textPrimary,
                            fontSize: 14,
                            fontWeight: (options[i].isLive
                                    ? _continuousMode
                                    : (!_continuousMode &&
                                        _selectedDuration ==
                                            options[i].duration))
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        if (options[i].isLive
                            ? _continuousMode
                            : (!_continuousMode &&
                                _selectedDuration ==
                                    options[i].duration)) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.check, size: 16, color: _teal),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRRHistoryCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFCC02)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RR Intervals (ms) \u2014 ${_sessionRRIntervals.length} total',
            style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6D4C00),
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _rrHistory.isEmpty
              ? const Text('Waiting for heartbeats...',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6D4C00)))
              : Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _rrHistory.map((rr) {
                    final isOutlier = rr < 400 || rr > 1500;
                    return Chip(
                      label: Text('${rr.round()}'),
                      backgroundColor: isOutlier
                          ? Colors.orange.shade800
                          : Colors.green.shade800,
                      labelStyle:
                          const TextStyle(fontSize: 11, color: Colors.white),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    );
                  }).toList(),
                ),
        ],
      ),
    );
  }

  Widget _buildHelpOverlay(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Positioned.fill(
      child: GestureDetector(
        onTap: _hideHelpOverlay,
        child: Container(
          color: Colors.black.withOpacity(0.5),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // Prevent tap-through to background
              child: Container(
                width: screenSize.width * 0.9,
                constraints: BoxConstraints(
                    maxHeight: screenSize.height * 0.75),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'How to Measure',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: _navy,
                            ),
                          ),
                          GestureDetector(
                            onTap: _hideHelpOverlay,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.grey.shade200,
                              ),
                              child: const Icon(Icons.close,
                                  size: 18, color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const SizedBox(
                        height: 250,
                        child: FingerGuideAnimation(),
                      ),
                      const SizedBox(height: 20),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _InstructionStep(
                              number: '1',
                              text:
                                  'Cover the camera and flash with your fingertip'),
                          SizedBox(height: 12),
                          _InstructionStep(
                              number: '2',
                              text: 'Hold as still as you can'),
                          SizedBox(height: 12),
                          _InstructionStep(
                              number: '3',
                              text:
                                  "Keep gentle, steady contact \u2014 don't press hard"),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HELPER WIDGETS
// ---------------------------------------------------------------------------

class _InstructionStep extends StatelessWidget {
  final String number;
  final String text;
  const _InstructionStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: _teal,
          ),
          child: Center(
            child: Text(number,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 15, color: Color(0xFF4B5563), height: 1.4)),
        ),
      ],
    );
  }
}

/// Paints the hero ring around the camera preview circle.
/// In inactive state: light grey track. In active state: grey track with
/// a teal progress arc sweeping clockwise from the top.
class _HeroRingPainter extends CustomPainter {
  final double progress; // 0.0 = empty, 1.0 = full
  final bool isActive;
  final double ringWidth;

  _HeroRingPainter({
    required this.progress,
    required this.isActive,
    required this.ringWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - ringWidth / 2;

    // Track
    final trackPaint = Paint()
      ..color = isActive ? const Color(0xFFE0E0E0) : const Color(0xFFE8E8E8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth;
    canvas.drawCircle(center, radius, trackPaint);

    // Progress arc (only when active)
    if (isActive && progress > 0) {
      final arcPaint = Paint()
        ..color = _teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..strokeCap = StrokeCap.round;

      final sweepAngle = 2 * pi * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2, // start at top
        sweepAngle,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HeroRingPainter old) {
    return old.progress != progress || old.isActive != isActive;
  }
}
