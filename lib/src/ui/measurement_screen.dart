import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../processing/ppg_service.dart';
import '../models/ppg_signal.dart';
import 'widgets/waveform_painter.dart';

class MeasurementScreen extends StatefulWidget {
  const MeasurementScreen({super.key});

  @override
  State<MeasurementScreen> createState() => _MeasurementScreenState();
}

class _MeasurementScreenState extends State<MeasurementScreen> {
  CameraController? _controller;
  final _ppgService = PPGService();

  // State
  PPGSignal? _currentSignal;
  String _status = 'Initializing camera...';
  bool _isScanning = false;
  bool _isTransitioning = false;
  int _timeLeft = 60;
  Timer? _timer;
  Timer? _uiUpdateTimer;

  // Data buffers for visualization
  final List<double> _rawHistory = [];
  final List<double> _filteredHistory = [];
  final List<double> _rrHistory = [];
  final List<double> _sessionRRIntervals = []; // All RR intervals for the session
  List<int> _currentPeakIndices = [];
  static const int _historyLimit = 150;
  static const int _bpmWindowSize = 8;

  PPGSignal? _pendingSignal;
  StreamController<CameraImage>? _imageStreamController;
  StreamSubscription<PPGSignal>? _ppgSubscription;

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
      _controller = CameraController(
        camera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();
      if (mounted) setState(() => _status = 'Ready. Tap START to measure.');
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

    setState(() {
      _isScanning = true;
      _timeLeft = 60;
      _rawHistory.clear();
      _filteredHistory.clear();
      _rrHistory.clear();
      _sessionRRIntervals.clear();
      _currentPeakIndices = [];
      _currentSignal = null;
      _pendingSignal = null;
      _status = 'Starting...';
    });

    // Keep screen on
    WakelockPlus.enable();

    // Turn on flash
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

    // UI update throttle (10 Hz)
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _pendingSignal != null) _applyPendingSignal();
    });

    // Start camera stream
    _imageStreamController = StreamController<CameraImage>();
    try {
      await _controller!.startImageStream((image) {
        if (_imageStreamController != null &&
            !_imageStreamController!.isClosed) {
          _imageStreamController!.add(image);
        }
      });
    } catch (e) {
      debugPrint('Image stream error: $e');
      _isTransitioning = false;
      await _stopProcessing();
      return;
    }

    // Process PPG
    _ppgSubscription =
        _ppgService.processImageStream(_imageStreamController!.stream).listen(
      (signal) {
        _pendingSignal = signal;

        // Accumulate data
        _rawHistory.add(signal.rawIntensity);
        _filteredHistory.add(signal.filteredIntensity);
        if (_rawHistory.length > _historyLimit) _rawHistory.removeAt(0);
        if (_filteredHistory.length > _historyLimit) {
          _filteredHistory.removeAt(0);
        }
        _currentPeakIndices = signal.peakIndices;

        for (final rr in signal.rrIntervals) {
          _rrHistory.add(rr);
          _sessionRRIntervals.add(rr);
          if (_rrHistory.length > 20) _rrHistory.removeAt(0);
        }
      },
    );

    _isTransitioning = false;
  }

  void _applyPendingSignal() {
    if (_pendingSignal == null) return;
    final signal = _pendingSignal!;
    _pendingSignal = null;
    setState(() {
      _currentSignal = signal;
      _status = switch (signal.quality) {
        SignalQuality.good => 'Signal Good — Detecting heartbeats...',
        SignalQuality.fair => 'Signal Fair — Keep finger steady',
        SignalQuality.poor => 'Signal Poor — Cover camera + flash fully',
      };
    });
  }

  Future<void> _stopProcessing() async {
    if (_isTransitioning) return;
    _isTransitioning = true;

    _timer?.cancel();
    _uiUpdateTimer?.cancel();
    await _ppgSubscription?.cancel();
    await _imageStreamController?.close();
    _timer = null;
    _uiUpdateTimer = null;
    _ppgSubscription = null;
    _imageStreamController = null;

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

    WakelockPlus.disable();

    if (mounted) {
      setState(() {
        _isScanning = false;
        _status = _sessionRRIntervals.isEmpty
            ? 'No heartbeats detected. Try again.'
            : 'Done! Collected ${_sessionRRIntervals.length} RR intervals.';
      });
    }
    _isTransitioning = false;
  }

  double _meanRecentRR() {
    if (_rrHistory.isEmpty) return 0.0;
    final start =
        _rrHistory.length > _bpmWindowSize ? _rrHistory.length - _bpmWindowSize : 0;
    double sum = 0.0;
    int count = 0;
    for (int i = start; i < _rrHistory.length; i++) {
      sum += _rrHistory[i];
      count++;
    }
    return count == 0 ? 0.0 : sum / count;
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
    _ppgSubscription?.cancel();
    _imageStreamController?.close();
    _controller?.dispose();
    _ppgService.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String hrDisplay = '--';
    final meanRR = _meanRecentRR();
    if (meanRR > 0) hrDisplay = '${(60000 / meanRR).round()}';

    final snr = _currentSignal?.snr ?? 0.0;
    final quality = _currentSignal?.quality ?? SignalQuality.poor;
    final fps = _currentSignal?.frameRate ?? 0.0;
    final fpsStable = _currentSignal?.isFPSStable ?? false;
    final rejRatio = _currentSignal?.rejectionRatio ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('HRV Camera — Layer 1'),
        backgroundColor: const Color(0xFF02427A),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
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
                            '$hrDisplay BPM',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: _qualityColor(),
                            ),
                          ),
                          if (_isScanning)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _timeLeft <= 10
                                    ? Colors.red.withAlpha(40)
                                    : Colors.white10,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_timeLeft}s',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _timeLeft <= 10
                                      ? Colors.redAccent
                                      : Colors.white70,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _status,
                        style: TextStyle(color: _qualityColor(), fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Quality: ${quality.name.toUpperCase()} | '
                        'SNR: ${snr.toStringAsFixed(1)} dB',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      Text(
                        'FPS: ${fps.toStringAsFixed(0)} '
                        '${fpsStable ? "✓" : "⏳"} | '
                        'Rej: ${(rejRatio * 100).toStringAsFixed(0)}% | '
                        'RRs: ${_sessionRRIntervals.length}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Waveforms
            _buildWaveformCard(
                'Raw Signal (Red Channel)', _rawHistory, Colors.red.shade300, []),
            const SizedBox(height: 10),
            _buildWaveformCard('Filtered Signal (Bandpass)', _filteredHistory,
                Colors.greenAccent, _currentPeakIndices),
            const SizedBox(height: 10),

            // RR intervals
            _buildRRHistoryCard(),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isTransitioning ? null : _toggleScanning,
        backgroundColor: _isTransitioning
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
}
