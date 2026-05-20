# HRV — Vagal HRV Camera Module

Camera-based Heart Rate Variability (HRV) measurement using fingertip photoplethysmography (PPG).

Place your finger over the phone's rear camera + flash → 60 seconds → get RMSSD, SDNN, heart rate.

## Status

**Layer 1** — Camera + signal processing + live waveform display.

## Building

This project builds on Codemagic (iOS) or locally with Flutter (Android).

- iOS: Push to `main` → Codemagic builds → TestFlight
- Android: `flutter run` with USB-connected device

## Architecture

```
lib/
├── main.dart
└── src/
    ├── models/
    ├── processing/        # Signal processing pipeline
    └── ui/                # Measurement screens
```

Signal processing core adapted from [flutter_ppg](https://pub.dev/packages/flutter_ppg) (MIT License, shigindo.com).

## Target App

Integration target: Vagally Better app (Vagal_Flutter repo).
