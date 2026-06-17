import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Connection state exposed to the UI.
enum PolarConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

/// A single RR packet from the Polar H10.
class PolarRRPacket {
  final int sessionMicros; // timestamp on the shared PPGService clock
  final int hr; // instantaneous HR from the strap
  final List<int> rrIntervalsMs; // 1/1024 s values converted to ms

  const PolarRRPacket({
    required this.sessionMicros,
    required this.hr,
    required this.rrIntervalsMs,
  });

  Map<String, dynamic> toJson() => {
        'sessionMicros': sessionMicros,
        'hr': hr,
        'rrIntervalsMs': rrIntervalsMs,
      };

  factory PolarRRPacket.fromJson(Map<String, dynamic> j) => PolarRRPacket(
        sessionMicros: j['sessionMicros'] as int,
        hr: j['hr'] as int,
        rrIntervalsMs: (j['rrIntervalsMs'] as List).cast<int>(),
      );
}

/// Manages BLE connection to a Polar H10 chest strap via the standard
/// Heart Rate Service (0x180D) / Heart Rate Measurement characteristic (0x2A37).
///
/// Accepts a `nowMicros` closure tied to PPGService._frameStopwatch so that
/// all timestamps share the same monotonic session clock.
class PolarH10Service {
  final int Function() nowMicros;

  PolarH10Service({required this.nowMicros});

  // BLE identifiers
  static final Guid _hrServiceUuid = Guid('180D');
  static final Guid _hrMeasurementUuid = Guid('2A37');

  // State
  PolarConnectionState _state = PolarConnectionState.disconnected;
  PolarConnectionState get state => _state;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  BluetoothDevice? _device;
  String? get deviceName => _device?.platformName;

  StreamSubscription? _scanSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _charSub;
  Timer? _scanTimer;

  // Latest data
  int _latestHR = 0;
  int get latestHR => _latestHR;
  final List<PolarRRPacket> _packets = [];
  List<PolarRRPacket> get packets => List.unmodifiable(_packets);

  // Callback for UI updates — throttled by the caller
  void Function(PolarConnectionState state)? onStateChanged;
  void Function(PolarRRPacket packet)? onRRPacket;

  // Reconnect tracking
  bool _hasReconnected = false;
  bool _intentionalDisconnect = false;

  /// Start scanning for Polar devices. Auto-connects to the strongest one
  /// after collecting candidates for up to 5 s, or 15 s total timeout.
  Future<void> startScan() async {
    if (_state == PolarConnectionState.scanning ||
        _state == PolarConnectionState.connecting ||
        _state == PolarConnectionState.connected) return;

    _errorMessage = null;
    _setState(PolarConnectionState.scanning);

    // Check adapter state
    final adapterState = FlutterBluePlus.adapterStateNow;
    if (adapterState != BluetoothAdapterState.on) {
      _setError('Bluetooth is off — turn it on in Settings');
      return;
    }

    final Map<DeviceIdentifier, (BluetoothDevice, int)> candidates = {};

    try {
      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          if (name.toLowerCase().contains('polar')) {
            final existing = candidates[r.device.remoteId];
            if (existing == null || r.rssi > existing.$2) {
              candidates[r.device.remoteId] = (r.device, r.rssi);
            }
          }
        }
      });

      // Start scan — returns a Future that completes when scan ends
      // ignore: unawaited_futures
      FlutterBluePlus.startScan(
        withServices: [_hrServiceUuid],
        timeout: const Duration(seconds: 15),
      );

      // Collect candidates for 5 s, then stop and pick strongest
      _scanTimer = Timer(const Duration(seconds: 5), () async {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
        _scanSub?.cancel();
        _scanSub = null;

        if (_state != PolarConnectionState.scanning) return;

        if (candidates.isEmpty) {
          _setError('No Polar device found — is it worn and in range?');
          return;
        }

        final best = candidates.values.reduce(
          (a, b) => a.$2 > b.$2 ? a : b,
        );
        await _connectToDevice(best.$1);
      });
    } catch (e) {
      _setError('Scan failed: $e');
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _device = device;
    _setState(PolarConnectionState.connecting);

    try {
      _intentionalDisconnect = false;

      // Listen for disconnects
      _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            !_intentionalDisconnect) {
          _handleUnexpectedDisconnect();
        }
      });

      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
      );

      // Discover services
      final services = await device.discoverServices();
      BluetoothService? hrService;
      for (final s in services) {
        if (s.serviceUuid == _hrServiceUuid) {
          hrService = s;
          break;
        }
      }

      if (hrService == null) {
        _setError('Heart Rate service not found on ${device.platformName}');
        await device.disconnect();
        return;
      }

      BluetoothCharacteristic? hrChar;
      for (final c in hrService.characteristics) {
        if (c.characteristicUuid == _hrMeasurementUuid) {
          hrChar = c;
          break;
        }
      }

      if (hrChar == null) {
        _setError('HR Measurement characteristic not found');
        await device.disconnect();
        return;
      }

      // Subscribe to notifications
      await hrChar.setNotifyValue(true);
      _charSub = hrChar.onValueReceived.listen(_onHRData);

      _setState(PolarConnectionState.connected);
    } catch (e) {
      _setError('Connection failed: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  void _handleUnexpectedDisconnect() {
    if (_intentionalDisconnect) return;

    if (!_hasReconnected && _device != null) {
      // One auto-reconnect attempt
      _hasReconnected = true;
      _setState(PolarConnectionState.connecting);
      _connectToDevice(_device!);
    } else {
      _setError('Polar disconnected');
    }
  }

  /// Parse Heart Rate Measurement per Bluetooth SIG spec.
  /// Flags byte: bit 0 = HR format (0=uint8, 1=uint16),
  ///             bit 4 = RR-interval present.
  void _onHRData(List<int> value) {
    if (value.isEmpty) return;

    final data = Uint8List.fromList(value);
    final flags = data[0];
    final hrIs16Bit = (flags & 0x01) != 0;
    final rrPresent = (flags & 0x10) != 0;

    int offset = 1;

    // Heart rate
    int hr;
    if (hrIs16Bit) {
      if (data.length < 3) return;
      hr = data[1] | (data[2] << 8);
      offset = 3;
    } else {
      if (data.length < 2) return;
      hr = data[1];
      offset = 2;
    }
    _latestHR = hr;

    // Energy expended (skip if present)
    if ((flags & 0x08) != 0) {
      offset += 2;
    }

    // RR intervals (1/1024 second units)
    final rrMs = <int>[];
    if (rrPresent) {
      while (offset + 1 < data.length) {
        final raw = data[offset] | (data[offset + 1] << 8);
        // Convert from 1/1024 s to milliseconds
        final ms = (raw * 1000.0 / 1024.0).round();
        rrMs.add(ms);
        offset += 2;
      }
    }

    final packet = PolarRRPacket(
      sessionMicros: nowMicros(),
      hr: hr,
      rrIntervalsMs: rrMs,
    );
    _packets.add(packet);
    onRRPacket?.call(packet);
  }

  /// Disconnect and clean up.
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _scanTimer?.cancel();
    _scanSub?.cancel();
    _charSub?.cancel();
    _connectionSub?.cancel();
    _scanSub = null;
    _charSub = null;
    _connectionSub = null;
    _scanTimer = null;

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }

    _device = null;
    _setState(PolarConnectionState.disconnected);
  }

  /// Clear accumulated packets (call at start of new measurement).
  void clearPackets() {
    _packets.clear();
    _latestHR = 0;
    _hasReconnected = false;
  }

  /// Full cleanup.
  Future<void> dispose() async {
    await disconnect();
    _packets.clear();
    onStateChanged = null;
    onRRPacket = null;
  }

  void _setState(PolarConnectionState s) {
    _state = s;
    if (s != PolarConnectionState.error) _errorMessage = null;
    onStateChanged?.call(s);
  }

  void _setError(String msg) {
    _errorMessage = msg;
    _setState(PolarConnectionState.error);
  }
}
