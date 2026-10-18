import 'dart:math' as math;
import 'dart:typed_data';

import '../models/activity_prediction.dart' show PredictionSource;
import '../models/audio_prediction.dart';
import 'audio_service.dart';
import 'tflite_service.dart';

/// Audio event pipeline: captured window -> resize to the model's input length
/// -> TFLite model -> event classification.
///
/// HONESTY NOTE: like the motion service, this class has no classifier of its
/// own. [classify] returns null when no real audio model has been placed in
/// assets/models/. It never guesses "Scream" from loudness and calls it AI.
class AudioInferenceService {
  static const String modelAsset = 'assets/models/audio_model.tflite';

  final TFLiteService _tflite = TFLiteService(modelAsset);

  bool get isModelLoaded => _tflite.isLoaded;
  String? get modelLoadError => _tflite.loadError;
  List<int>? get modelInputShape => _tflite.inputShape;
  List<int>? get modelOutputShape => _tflite.outputShape;

  Future<bool> initialize() => _tflite.load();

  AudioPrediction? classify(AudioWindow window) {
    if (!_tflite.isLoaded) return null;

    final inShape = _tflite.inputShape;
    final outShape = _tflite.outputShape;
    if (inShape == null || outShape == null) return null;

    final expected = inShape.fold<int>(1, (a, b) => a * b);
    final frame = _fitLength(window.samples, expected);

    final Object input = _shapeInput(frame, inShape);
    if (input == _unsupported) return null;

    final classCount = outShape.last;
    final output = List<List<double>>.generate(
      1,
      (_) => List<double>.filled(classCount, 0.0),
    );

    try {
      _tflite.run(input, output);
    } catch (_) {
      return null;
    }

    return _toPrediction(_normalize(output.first));
  }

  static const Object _unsupported = Object();

  /// Trims or zero-pads the captured audio to the model's expected sample count.
  List<double> _fitLength(Float32List samples, int target) {
    final out = List<double>.filled(target, 0.0);
    final n = samples.length < target ? samples.length : target;
    for (int i = 0; i < n; i++) {
      out[i] = samples[i];
    }
    return out;
  }

  Object _shapeInput(List<double> flat, List<int> shape) {
    switch (shape.length) {
      case 1:
        return flat;
      case 2:
        return [flat];
      case 3:
        final rows = shape[1];
        final cols = shape[2];
        if (rows * cols != flat.length) return _unsupported;
        return [
          List<List<double>>.generate(
            rows,
            (r) => flat.sublist(r * cols, (r + 1) * cols),
          )
        ];
      default:
        return _unsupported;
    }
  }

  List<double> _normalize(List<double> raw) {
    final sum = raw.fold<double>(0, (a, b) => a + b);
    final inRange = raw.every((v) => v >= 0 && v <= 1);
    if (inRange && (sum - 1.0).abs() < 0.05) return raw;

    final maxV = raw.reduce(math.max);
    final exps = raw.map((v) => math.exp(v - maxV)).toList();
    final expSum = exps.fold<double>(0, (a, b) => a + b);
    if (expSum == 0) return raw;
    return exps.map((v) => v / expSum).toList();
  }

  AudioPrediction _toPrediction(List<double> probabilities) {
    final scores = <AudioClass, double>{};
    for (int i = 0; i < kAudioClassOrder.length; i++) {
      scores[kAudioClassOrder[i]] =
          i < probabilities.length ? probabilities[i] : 0.0;
    }

    AudioClass best = kAudioClassOrder.first;
    double bestScore = -1;
    scores.forEach((k, v) {
      if (v > bestScore) {
        bestScore = v;
        best = k;
      }
    });

    return AudioPrediction(
      event: best,
      confidence: bestScore < 0 ? 0 : bestScore,
      scores: scores,
      timestamp: DateTime.now(),
      source: PredictionSource.tfliteModel,
    );
  }

  void dispose() => _tflite.close();
}
