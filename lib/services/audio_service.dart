import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// A short captured audio window: 16 kHz mono PCM converted to floats in
/// [-1, 1], which is what audio classification models expect.
class AudioWindow {
  final Float32List samples;
  final int sampleRate;
  final DateTime capturedAt;

  const AudioWindow({
    required this.samples,
    required this.sampleRate,
    required this.capturedAt,
  });

  double get durationSeconds => samples.length / sampleRate;

  /// RMS level, useful for showing that real audio was captured.
  double get rms {
    if (samples.isEmpty) return 0;
    double sum = 0;
    for (final s in samples) {
      sum += s * s;
    }
    return (sum / samples.length);
  }
}

/// Microphone abstraction with an explicit no-always-on policy.
///
/// The microphone is OFF in the normal state. It is opened only by
/// [captureWindow], records for a bounded number of seconds, and is closed
/// again before the method returns — including on error. There is no code path
/// in this app that keeps the mic open continuously.
class AudioService {
  static const int sampleRate = 16000;
  static const Duration defaultWindow = Duration(seconds: 3);

  final AudioRecorder _recorder = AudioRecorder();

  bool _micActive = false;
  DateTime? _lastCaptureAt;
  String? _lastError;

  bool get isMicrophoneActive => _micActive;
  DateTime? get lastCaptureAt => _lastCaptureAt;
  String? get lastError => _lastError;

  Future<bool> hasPermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Opens the mic, records one bounded window, closes the mic, and returns the
  /// decoded PCM. Returns null if permission is missing or capture failed.
  Future<AudioWindow?> captureWindow({
    Duration duration = defaultWindow,
  }) async {
    _lastError = null;

    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) {
        _lastError = 'Microphone permission denied';
        return null;
      }
    }

    if (!await _recorder.hasPermission()) {
      _lastError = 'Recorder reported no microphone permission';
      return null;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/distress_window_${DateTime.now().millisecondsSinceEpoch}.wav';

    File? file;
    try {
      _micActive = true;
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: sampleRate,
          numChannels: 1,
        ),
        path: path,
      );

      await Future<void>.delayed(duration);
      await _recorder.stop();
      _micActive = false;
      _lastCaptureAt = DateTime.now();

      file = File(path);
      if (!await file.exists()) {
        _lastError = 'Recording file was not created';
        return null;
      }

      final bytes = await file.readAsBytes();
      final samples = _decodeWavToFloat(bytes);
      if (samples.isEmpty) {
        _lastError = 'Captured window contained no audio data';
        return null;
      }

      return AudioWindow(
        samples: samples,
        sampleRate: sampleRate,
        capturedAt: _lastCaptureAt!,
      );
    } catch (e) {
      _lastError = 'Audio capture failed: $e';
      return null;
    } finally {
      // The mic must never be left open.
      if (_micActive) {
        try {
          await _recorder.stop();
        } catch (_) {
          // Already stopped.
        }
        _micActive = false;
      }
      // Audio is not retained on disk after classification.
      try {
        if (file != null && await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Temp file cleanup is best-effort.
      }
    }
  }

  /// Minimal 16-bit PCM WAV decoder: finds the "data" chunk and scales the
  /// little-endian samples to [-1, 1].
  Float32List _decodeWavToFloat(Uint8List bytes) {
    if (bytes.length < 44) return Float32List(0);

    int dataOffset = -1;
    int dataLength = 0;

    // Walk the RIFF chunks instead of assuming a fixed 44-byte header.
    int offset = 12;
    final view = ByteData.sublistView(bytes);
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = view.getUint32(offset + 4, Endian.little);
      if (id == 'data') {
        dataOffset = offset + 8;
        dataLength = size;
        break;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }

    if (dataOffset < 0) return Float32List(0);
    if (dataOffset + dataLength > bytes.length) {
      dataLength = bytes.length - dataOffset;
    }

    final count = dataLength ~/ 2;
    final out = Float32List(count);
    for (int i = 0; i < count; i++) {
      final s = view.getInt16(dataOffset + i * 2, Endian.little);
      out[i] = s / 32768.0;
    }
    return out;
  }

  Future<void> dispose() async {
    try {
      if (_micActive) await _recorder.stop();
    } catch (_) {
      // Ignore.
    }
    _micActive = false;
    await _recorder.dispose();
  }
}
