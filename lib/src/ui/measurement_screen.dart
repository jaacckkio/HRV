import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../processing/ppg_service.dart';
import '../processing/hrv_calculator.dart';
import '../models/ppg_signal.dart';
import '../camera/camera_control.dart';
import '../recording/ppg_recording.dart';
import 'widgets/waveform_painter.dart';
import 'widgets/finger_guide_animation.dart';
import 'results_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
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
    });

    _countdownController?.dispose();
    _countdownController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _selectedDuration),
    );
    _countdownController!.forward();

    WakelockPlus.enable();

    // Request highest supported frame rate via native plugin (diagnostic).
    // Must be called after controller.initialize() sets up the AVCaptureSession
    // but before startImageStream so the format is active when frames arrive.
    _requestedFps = await CameraControl.setHighFrameRate();
    debugPrint('Requested FPS: $_requestedFps');

    try {
      await _controller!.setFlashMode(FlashMode.torch);
    } catch (e) {
      debugPrint('Flash error: $e');
    }

    // Countdown timer
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isScanning) {
        setState(() => _timeLeft--);
        if (_timeLeft <= 0) _stopProcessing();
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
          SignalQuality.good => 'Signal Good — Detecting heartbeats...',
          SignalQuality.fair => 'Signal Fair — Keep finger steady',
          SignalQuality.poor => 'Signal Poor — Keep finger steady',
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
        _status = 'No heartbeats detected. Tap START to retry.';
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

    final recording = PPGRecording(
      startWallClockUtc:
          _recordStartWallClock ?? DateTime.now().toUtc().toIso8601String(),
      fps: fps,
      requestedFps: _requestedFps,
      clearBufferAtFrame: _recordClearAtFrame,
      samples: List.from(_recordedSamples),
      finalRRIntervals: beats,
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

  /// Recompute live BPM, RMSSD, and waveform peak markers at ~1 Hz.
  /// Uses the same PeakDetector.findPeaksROI and HrvCalculator/artifact-filter
  /// pipeline as the final end-of-measurement result.
  void _updateLiveMetrics() {
    if (_ppgService == null || !_exposureLocked) return;

    final measElapsed = _measuringStartTime != null
        ? DateTime.now().difference(_measuringStartTime!).inSeconds
        : 0;

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
  }

  Color _qualityColor() {
    if (!_isScanning || _currentSignal == null) return Colors.grey;
    return switch (_currentSignal!.quality) {
      SignalQuality.good => Colors.greenAccent,
      SignalQuality.fair => Colors.orangeAccent,
      SignalQuality.poor => Colors.redAccent,
    };
  }

  @override
  void dispose() {
    _timer?.cancel();
    _uiUpdateTimer?.cancel();
    _liveMetricsTimer?.cancel();
    _countdownController?.dispose();
    _controller?.dispose();
    _ppgService?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String hrDisplay = '--';
    if (_isScanning && _exposureLocked && !_bpmSettled) {
      hrDisplay = 'Measuring\u2026';
    } else if (_bpmSettled && _liveBPM != null) {
      hrDisplay = '${_liveBPM!.round()}';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('HRV Camera — Layer 1'),
        backgroundColor: const Color(0xFF02427A),
        foregroundColor: Colors.white,
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
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top row: camera preview + stats
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCameraPreview(),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _bpmSettled ? '$hrDisplay BPM' : hrDisplay,
                                style: TextStyle(
                                  fontSize: _bpmSettled ? 32 : 20,
                                  fontWeight: FontWeight.bold,
                                  color: _qualityColor(),
                                ),
                              ),
                              if (_isScanning)
                                _buildCountdownRing()
                              else
                                _buildDurationButton(),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _rmssdSettled && _liveRMSSD != null
                                ? 'HRV (RMSSD): ${_liveRMSSD!.toStringAsFixed(1)} ms'
                                : (_isScanning && _exposureLocked
                                    ? 'HRV (RMSSD): Measuring\u2026'
                                    : 'HRV (RMSSD): \u2014'),
                            style: const TextStyle(
                                fontSize: 14, color: Colors.white70),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _status,
                            style: TextStyle(color: _qualityColor(), fontSize: 13),
                          ),
                          if (_isScanning) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Stream FPS: ${(_currentSignal?.frameRate ?? 0).toStringAsFixed(0)}'
                              ' (requested ${_requestedFps.toStringAsFixed(0)})',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.cyanAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // DEV TOOLING — Record / Replay / Share buttons
                _buildDevToolbar(),
                const SizedBox(height: 8),

                // Pulse waveform with beat markers
                _buildPulseWaveformCard(),
                const SizedBox(height: 10),

                // RR intervals
                _buildRRHistoryCard(),
                const SizedBox(height: 100),
              ],
            ),
          ),
          if (_showDurationPicker && !_isScanning) _buildDurationPicker(),
          if (_showingHelp) _buildHelpOverlay(context),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_isTransitioning || _isReplaying) ? null : _toggleScanning,
        backgroundColor: (_isTransitioning || _isReplaying)
            ? Colors.grey
            : (_isScanning ? Colors.red : const Color(0xFF06A3B7)),
        icon: Icon(_isScanning ? Icons.stop : Icons.play_arrow),
        label: Text(
          _isScanning ? 'STOP' : 'START',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

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
          _devButton('Replay', _isScanning || _isReplaying ? null : _replayRecording),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _isRecording ? 'Recording ON' : 'Files app: On My iPhone > Vagal HRV Camera',
              style: const TextStyle(fontSize: 9, color: Color(0xFF6D4C00)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
          color: onTap != null
              ? const Color(0xFF06A3B7)
              : Colors.grey.shade400,
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

  Widget _buildCountdownRing() {
    if (_countdownController == null || !_countdownController!.isAnimating) {
      return SizedBox(
        width: 48,
        height: 48,
        child: CustomPaint(
          painter: _CountdownPainter(
            progress: _selectedDuration > 0 ? _timeLeft / _selectedDuration : 0,
            timeText: _formatTimeLeft(),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _countdownController!,
      builder: (context, child) {
        return SizedBox(
          width: 48,
          height: 48,
          child: CustomPaint(
            painter: _CountdownPainter(
              progress: 1.0 - _countdownController!.value,
              timeText: _formatTimeLeft(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDurationButton() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _showDurationPicker = !_showDurationPicker;
        });
      },
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.1),
          border: Border.all(color: const Color(0xFF06A3B7), width: 1.5),
        ),
        child: Center(
          child: Text(
            _selectedDuration >= 60
                ? '${_selectedDuration ~/ 60}m'
                : '${_selectedDuration}s',
            style: const TextStyle(
              color: Color(0xFF06A3B7),
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDurationPicker() {
    const options = [
      (duration: 60, label: '60 seconds'),
      (duration: 120, label: '2 minutes'),
      (duration: 180, label: '3 minutes'),
    ];

    return Positioned(
      top: 140,
      right: 12,
      child: Container(
        constraints: const BoxConstraints(minWidth: 140),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1F2A),
          border: Border.all(color: const Color(0xFF2A2E3A)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < options.length; i++)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedDuration = options[i].duration;
                    _showDurationPicker = false;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _selectedDuration == options[i].duration
                        ? const Color(0xFF06A3B7).withOpacity(0.15)
                        : Colors.transparent,
                    border: i < options.length - 1
                        ? const Border(
                            bottom: BorderSide(color: Color(0xFF2A2E3A)))
                        : null,
                    borderRadius: i == 0
                        ? const BorderRadius.vertical(
                            top: Radius.circular(12))
                        : i == options.length - 1
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
                          color: _selectedDuration == options[i].duration
                              ? const Color(0xFF06A3B7)
                              : Colors.white70,
                          fontSize: 14,
                          fontWeight:
                              _selectedDuration == options[i].duration
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                        ),
                      ),
                      if (_selectedDuration == options[i].duration) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.check,
                            size: 16, color: Color(0xFF06A3B7)),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(
        height: 100,
        width: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.grey.shade800,
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return Container(
      height: 100,
      width: 100,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _qualityColor(), width: 3),
      ),
      clipBehavior: Clip.antiAlias,
      child: CameraPreview(_controller!),
    );
  }

  Widget _buildWaveformCard(
      String title, List<double> data, Color color, List<int> peaks) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: data.isEmpty
                  ? const Center(
                      child: Text('Waiting for data...',
                          style: TextStyle(color: Colors.white30)))
                  : CustomPaint(
                      painter: WaveformPainter(data, color, peaks),
                      child: Container(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPulseWaveformCard() {
    // Map peak indices from full-signal coordinates to the display buffer
    final fullLen = _ppgService?.fullFilteredSignalLength ?? 0;
    final histLen = _filteredHistory.length;
    final offset = fullLen - histLen;
    final displayPeaks = <int>[];
    for (final p in _livePeakIndicesInFull) {
      final idx = p - offset;
      if (idx >= 0 && idx < histLen) displayPeaks.add(idx);
    }
    return _buildWaveformCard(
        'Pulse', _filteredHistory, Colors.greenAccent, displayPeaks);
  }

  Widget _buildRRHistoryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'RR Intervals (ms) — ${_sessionRRIntervals.length} total',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            _rrHistory.isEmpty
                ? const Text('Waiting for heartbeats...',
                    style: TextStyle(color: Colors.white30))
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
                        labelStyle: const TextStyle(fontSize: 11),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      );
                    }).toList(),
                  ),
          ],
        ),
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
                              color: Color(0xFF02427A),
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
                              text: 'Place your phone on a flat surface'),
                          SizedBox(height: 12),
                          _InstructionStep(
                              number: '2',
                              text:
                                  'Cover the rear camera AND flash with your fingertip'),
                          SizedBox(height: 12),
                          _InstructionStep(
                              number: '3',
                              text: "Press gently — don't push hard"),
                          SizedBox(height: 12),
                          _InstructionStep(
                              number: '4',
                              text:
                                  'Stay completely still for 60 seconds'),
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
            color: Color(0xFF06A3B7),
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

class _CountdownPainter extends CustomPainter {
  final double progress; // 1.0 = full, 0.0 = empty
  final String timeText;

  _CountdownPainter({required this.progress, required this.timeText});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // Background circle
    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc
    final arcPaint = Paint()
      ..color = const Color(0xFF06A3B7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * pi * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2, // start at top
      sweepAngle, // sweep clockwise
      false,
      arcPaint,
    );

    // Time text
    final textPainter = TextPainter(
      text: TextSpan(
        text: timeText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _CountdownPainter old) {
    return old.progress != progress || old.timeText != timeText;
  }
}
