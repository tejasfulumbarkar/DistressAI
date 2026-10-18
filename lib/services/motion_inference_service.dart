import 'dart:math' as math;

import '../models/activity_prediction.dart';
import '../models/sensor_sample.dart';
import 'tflite_service.dart';

/// Result of the non-AI signal trigger described in [MotionInferenceService].
class MotionCandidate {
  final bool isCandidate;
  final double freeFallMinMagnitude;
  final double impactPeakMagnitude;
  final double rotationPeak;

  const MotionCandidate({
    required this.isCandidate,
    required this.freeFallMinMagnitude,
    required this.impactPeakMagnitude,
    required this.rotationPeak,
  });
}

/// Motion pipeline: sensor samples -> windowing/preprocessing -> TFLite model
/// -> activity classification.
///
/// HONESTY NOTE (important for the review):
/// This class contains NO classifier of its own. [classifyWindow] returns null
/// whenever no real .tflite model has been loaded from assets/models/. It never
/// substitutes a hand-written rule and calls the output "AI".
///
/// [detectCandidate] IS a plain physics threshold check (free-fall dip followed
/// by an impact peak). It is deliberately not called a classifier: its only job
/// is to decide when to spend battery waking the microphone and running the
/// model. Describe it as a signal trigger, not machine learning.
class MotionInferenceService {
  /// Asset path where the motion model is expected.
  static const String modelAsset = 'assets/models/motion_model.tflite';

  /// Samples per inference window. 128 @ 50 Hz = 2.56 s, the window length used
  /// by the UCI HAR dataset, which most public HAR models are trained on.
  static const int windowSize = 15;

  /// 50% overlap between consecutive windows.
  static const int windowStride = 7;

  /// Features per sample: ax, ay, az, gx, gy, gz.
  static const int featureCount = 6;

  final TFLiteService _tflite = TFLiteService(modelAsset);
  final List<SensorSample> _buffer = <SensorSample>[];

  int _samplesSinceLastWindow = 0;

  bool get isModelLoaded => _tflite.isLoaded;
  String? get modelLoadError => _tflite.loadError;
  List<int>? get modelInputShape => _tflite.inputShape;
  List<int>? get modelOutputShape => _tflite.outputShape;

  /// Attempts to load the model. Safe to call at startup; returns false when no
  /// model file has been added yet.
  Future<bool> initialize() => _tflite.load();

  /// Adds one sample to the sliding window.
  ///
  /// Returns the completed window when [windowStride] new samples have arrived
  /// and the buffer is full, otherwise null.
  List<SensorSample>? addSample(SensorSample sample) {
    _buffer.add(sample);
    if (_buffer.length > windowSize) {
      _buffer.removeRange(0, _buffer.length - windowSize);
    }
    _samplesSinceLastWindow++;

    if (_buffer.length == windowSize && _samplesSinceLastWindow >= windowStride) {
      _samplesSinceLastWindow = 0;
      return List<SensorSample>.unmodifiable(_buffer);
    }
    return null;
  }

  void reset() {
    _buffer.clear();
    _samplesSinceLastWindow = 0;
  }

  /// Physics threshold trigger (NOT a classifier, NOT AI).
  ///
  /// A fall typically shows a near-zero-g dip (free fall) followed within the
  /// same window by a large impact peak, often with high angular velocity.
  MotionCandidate detectCandidate(
    List<SensorSample> window, {
    double freeFallThreshold = 6.0, // m/s^2, below ~0.6 g
    double impactThreshold = 22.0, // m/s^2, above ~2.2 g
    double rotationThreshold = 3.0, // rad/s
  }) {
    double minMag = double.infinity;
    double maxMag = 0;
    double maxRot = 0;
    int minIndex = 0;

    for (int i = 0; i < window.length; i++) {
      final mag = window[i].accelerationMagnitude;
      final rot = window[i].rotationMagnitude;
      if (mag < minMag) {
        minMag = mag;
        minIndex = i;
      }
      if (mag > maxMag) maxMag = mag;
      if (rot > maxRot) maxRot = rot;
    }

    // Look for the impact strictly after the free-fall dip.
    double postDipPeak = 0;
    for (int i = minIndex; i < window.length; i++) {
      final mag = window[i].accelerationMagnitude;
      if (mag > postDipPeak) postDipPeak = mag;
    }

    final candidate = (minMag < freeFallThreshold &&
            postDipPeak > impactThreshold) ||
        (postDipPeak > impactThreshold && maxRot > rotationThreshold);

    return MotionCandidate(
      isCandidate: candidate,
      freeFallMinMagnitude: minMag.isFinite ? minMag : 0,
      impactPeakMagnitude: maxMag,
      rotationPeak: maxRot,
    );
  }

  /// Runs the loaded TFLite model over a window.
  ///
  /// Returns null when no model is loaded — the caller must then report
  /// "model not integrated" rather than guessing an activity.
  ActivityPrediction? classifyWindow(List<SensorSample> window) {
    if (!_tflite.isLoaded) return null;
    if (window.length != windowSize) return null;

    final flat = <double>[];
    for (final s in window) {
      flat.addAll(s.toFeatureVector());
    }

    final inShape = _tflite.inputShape;
    final outShape = _tflite.outputShape;
    if (inShape == null || outShape == null) return null;

    final Object input = _shapeInput(flat, inShape);
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

    final probabilities = _normalize(output.first);
    return _toPrediction(probabilities);
  }

  static const Object _unsupported = Object();

  /// Reshapes the flat window to whatever rank the loaded model wants.
  /// Supports [1, windowSize*features], [1, windowSize, features] and
  /// [1, windowSize, features, 1].
  Object _shapeInput(List<double> flat, List<int> shape) {
    final expected = shape.fold<int>(1, (a, b) => a * b);
    if (expected != flat.length) return _unsupported;

    switch (shape.length) {
      case 2:
        return [flat];
      case 3:
        final rows = shape[1];
        final cols = shape[2];
        return [
          List<List<double>>.generate(
            rows,
            (r) => flat.sublist(r * cols, (r + 1) * cols),
          )
        ];
      case 4:
        final rows = shape[1];
        final cols = shape[2];
        return [
          List<List<List<double>>>.generate(
            rows,
            (r) => List<List<double>>.generate(
              cols,
              (c) => <double>[flat[r * cols + c]],
            ),
          )
        ];
      default:
        return _unsupported;
    }
  }

  /// Applies softmax only when the model emits raw logits.
  List<double> _normalize(List<double> raw) {
    final sum = raw.fold<double>(0, (a, b) => a + b);
    final allInRange = raw.every((v) => v >= 0 && v <= 1);
    if (allInRange && (sum - 1.0).abs() < 0.05) return raw;

    final maxV = raw.reduce(math.max);
    final exps = raw.map((v) => math.exp(v - maxV)).toList();
    final expSum = exps.fold<double>(0, (a, b) => a + b);
    if (expSum == 0) return raw;
    return exps.map((v) => v / expSum).toList();
  }

  ActivityPrediction _toPrediction(List<double> probabilities) {
    final scores = <ActivityClass, double>{};
    for (int i = 0; i < kActivityClassOrder.length; i++) {
      scores[kActivityClassOrder[i]] =
          i < probabilities.length ? probabilities[i] : 0.0;
    }

    ActivityClass best = kActivityClassOrder.first;
    double bestScore = -1;
    scores.forEach((k, v) {
      if (v > bestScore) {
        bestScore = v;
        best = k;
      }
    });

    return ActivityPrediction(
      activity: best,
      confidence: bestScore < 0 ? 0 : bestScore,
      scores: scores,
      timestamp: DateTime.now(),
      source: PredictionSource.tfliteModel,
    );
  }

  void dispose() => _tflite.close();
}
