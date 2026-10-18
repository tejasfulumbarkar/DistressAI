import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Thin wrapper around tflite_flutter.
///
/// Its only job is to load a .tflite file from assets/models/ if — and only if
/// — that file actually exists in the bundle, and to expose the interpreter's
/// real input/output shapes. Nothing here fabricates a model or a prediction.
class TFLiteService {
  final String assetPath;

  Interpreter? _interpreter;
  bool _attemptedLoad = false;
  String? _loadError;

  TFLiteService(this.assetPath);

  bool get isLoaded => _interpreter != null;
  String? get loadError => _loadError;
  bool get attemptedLoad => _attemptedLoad;
  Interpreter? get interpreter => _interpreter;

  /// Returns true if a model was successfully loaded.
  ///
  /// Returns false (and records [loadError]) when the asset is absent or is not
  /// a valid TFLite file. Callers must treat false as "no inference possible".
  Future<bool> load() async {
    if (_attemptedLoad) return isLoaded;
    _attemptedLoad = true;

    // rootBundle.load throws if the asset is not bundled, which is the honest
    // way to detect "no model has been added yet".
    try {
      await rootBundle.load(assetPath);
    } catch (_) {
      _loadError =
          'No model file at $assetPath. Add a .tflite model to assets/models/.';
      return false;
    }

    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(assetPath, options: options);
      _interpreter!.allocateTensors();
      return true;
    } catch (e) {
      _loadError = 'Failed to load $assetPath: $e';
      if (kDebugMode) {
        debugPrint(_loadError);
      }
      _interpreter = null;
      return false;
    }
  }

  /// Real input shape reported by the loaded model, or null when unloaded.
  List<int>? get inputShape {
    final i = _interpreter;
    if (i == null) return null;
    return i.getInputTensor(0).shape;
  }

  /// Real output shape reported by the loaded model, or null when unloaded.
  List<int>? get outputShape {
    final i = _interpreter;
    if (i == null) return null;
    return i.getOutputTensor(0).shape;
  }

  /// Number of classes the loaded model emits (last output dimension).
  int? get outputClassCount {
    final shape = outputShape;
    if (shape == null || shape.isEmpty) return null;
    return shape.last;
  }

  void run(Object input, Object output) {
    final i = _interpreter;
    if (i == null) {
      throw StateError('run() called before a model was loaded: $assetPath');
    }
    i.run(input, output);
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
    _attemptedLoad = false;
  }
}
