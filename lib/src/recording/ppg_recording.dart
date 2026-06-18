import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// DEV TOOLING — record-and-replay for offline detector iteration.
/// Remove when no longer needed.

/// A single per-frame sample captured during recording.
/// These are the exact inputs the pipeline consumes: microsecond timestamp
/// + RGB channel means (from which intensity = max(R,G,B) is derived).
class PPGFrameSample {
  final int t; // microseconds since Stopwatch start
  final double r; // mean red channel (0–255)
  final double g; // mean green channel (0–255)
  final double b; // mean blue channel (0–255)

  const PPGFrameSample({
    required this.t,
    required this.r,
    required this.g,
    required this.b,
  });

  Map<String, dynamic> toJson() => {'t': t, 'r': r, 'g': g, 'b': b};

  factory PPGFrameSample.fromJson(Map<String, dynamic> json) => PPGFrameSample(
        t: (json['t'] as num).toInt(),
        r: (json['r'] as num).toDouble(),
        g: (json['g'] as num).toDouble(),
        b: (json['b'] as num).toDouble(),
      );
}

/// A detected beat with its wall-clock offset for Polar H10 alignment.
class RRBeat {
  final double beatOffsetMs; // ms from startWallClockUtc
  final double rrMs; // RR interval (ms) to previous beat

  const RRBeat({required this.beatOffsetMs, required this.rrMs});

  Map<String, dynamic> toJson() => {
        'beatOffsetMs': double.parse(beatOffsetMs.toStringAsFixed(1)),
        'rrMs': double.parse(rrMs.toStringAsFixed(1)),
      };

  factory RRBeat.fromJson(Map<String, dynamic> json) => RRBeat(
        beatOffsetMs: (json['beatOffsetMs'] as num).toDouble(),
        rrMs: (json['rrMs'] as num).toDouble(),
      );
}

const String _fileName = 'ppg_recording_latest.json';

/// Full recording: raw samples + metadata + final results.
class PPGRecording {
  final String startWallClockUtc;
  final double fps;
  final double requestedFps; // FPS set on the device via native plugin (0 = default)
  final int clearBufferAtFrame; // frame index where clearSignalBuffers was called
  final List<PPGFrameSample> samples;
  final List<RRBeat> finalRRIntervals;
  final bool polarConnected; // whether Polar was connected during session
  final List<Map<String, dynamic>>? polarPackets; // raw PolarRRPacket JSON

  const PPGRecording({
    required this.startWallClockUtc,
    required this.fps,
    this.requestedFps = 0,
    required this.clearBufferAtFrame,
    required this.samples,
    required this.finalRRIntervals,
    this.polarConnected = false,
    this.polarPackets,
  });

  Map<String, dynamic> toJson() => {
        'startWallClockUtc': startWallClockUtc,
        'fps': fps,
        'requestedFps': requestedFps,
        'clearBufferAtFrame': clearBufferAtFrame,
        'sampleCount': samples.length,
        'samples': samples.map((s) => s.toJson()).toList(),
        'finalRRIntervals': finalRRIntervals.map((b) => b.toJson()).toList(),
        'polarConnected': polarConnected,
        if (polarPackets != null) 'polarPackets': polarPackets,
      };

  factory PPGRecording.fromJson(Map<String, dynamic> json) => PPGRecording(
        startWallClockUtc: json['startWallClockUtc'] as String,
        fps: (json['fps'] as num).toDouble(),
        requestedFps: (json['requestedFps'] as num?)?.toDouble() ?? 0,
        clearBufferAtFrame: (json['clearBufferAtFrame'] as num?)?.toInt() ?? -1,
        samples: (json['samples'] as List)
            .map((e) => PPGFrameSample.fromJson(e as Map<String, dynamic>))
            .toList(),
        finalRRIntervals: (json['finalRRIntervals'] as List)
            .map((e) => RRBeat.fromJson(e as Map<String, dynamic>))
            .toList(),
        polarConnected: json['polarConnected'] as bool? ?? false,
        polarPackets: (json['polarPackets'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );

  /// Resolve the real iOS NSDocumentDirectory via path_provider.
  /// This is the directory UIFileSharingEnabled exposes in the Files app.
  static Future<String> _resolveFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_fileName';
  }

  /// Write recording to the app documents directory.
  /// Saves a timestamped file (never overwritten) AND updates the latest
  /// file so the existing Replay path keeps working.
  Future<void> save() async {
    final dir = await getApplicationDocumentsDirectory();
    final content = jsonEncode(toJson());

    // Timestamped file — never overwritten
    final epoch = DateTime.now().millisecondsSinceEpoch;
    final timestampedFile = File('${dir.path}/ppg_session_$epoch.json');
    await timestampedFile.writeAsString(content);

    // Latest file — for Replay compatibility
    final latestFile = File('${dir.path}/$_fileName');
    await latestFile.writeAsString(content);
  }

  /// Load recording from the app documents directory. Returns null if absent.
  static Future<PPGRecording?> load() async {
    final path = await _resolveFilePath();
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return PPGRecording.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Check if a recording file exists.
  static Future<bool> exists() async {
    final path = await _resolveFilePath();
    return File(path).exists();
  }
}
