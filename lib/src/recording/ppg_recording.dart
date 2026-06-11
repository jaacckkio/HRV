import 'dart:convert';
import 'dart:io';

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

/// Full recording: raw samples + metadata + final results.
class PPGRecording {
  final String startWallClockUtc;
  final double fps;
  final int clearBufferAtFrame; // frame index where clearSignalBuffers was called
  final List<PPGFrameSample> samples;
  final List<RRBeat> finalRRIntervals;

  const PPGRecording({
    required this.startWallClockUtc,
    required this.fps,
    required this.clearBufferAtFrame,
    required this.samples,
    required this.finalRRIntervals,
  });

  Map<String, dynamic> toJson() => {
        'startWallClockUtc': startWallClockUtc,
        'fps': fps,
        'clearBufferAtFrame': clearBufferAtFrame,
        'sampleCount': samples.length,
        'samples': samples.map((s) => s.toJson()).toList(),
        'finalRRIntervals': finalRRIntervals.map((b) => b.toJson()).toList(),
      };

  factory PPGRecording.fromJson(Map<String, dynamic> json) => PPGRecording(
        startWallClockUtc: json['startWallClockUtc'] as String,
        fps: (json['fps'] as num).toDouble(),
        clearBufferAtFrame: (json['clearBufferAtFrame'] as num?)?.toInt() ?? -1,
        samples: (json['samples'] as List)
            .map((e) => PPGFrameSample.fromJson(e as Map<String, dynamic>))
            .toList(),
        finalRRIntervals: (json['finalRRIntervals'] as List)
            .map((e) => RRBeat.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// App Documents directory — resolved from systemTemp to handle symlinks.
  static String get _documentsDir {
    final resolved = Directory.systemTemp.resolveSymbolicLinksSync();
    return '${Directory(resolved).parent.path}/Documents';
  }

  static String get filePath => '$_documentsDir/ppg_recording_latest.json';

  /// Write recording to the app documents directory.
  Future<void> save() async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(toJson()));
  }

  /// Load recording from the app documents directory. Returns null if absent.
  static Future<PPGRecording?> load() async {
    final file = File(filePath);
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
  static Future<bool> exists() => File(filePath).exists();
}
