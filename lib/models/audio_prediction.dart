import 'activity_prediction.dart' show PredictionSource;
/// Audio event classes, in the order the audio .tflite model is expected to
/// emit them. 
enum AudioClass { help, scream, normalSpeech, backgroundNoise }

const List<AudioClass> kAudioClassOrder = <AudioClass>[
  AudioClass.help,
  AudioClass.scream,
  AudioClass.normalSpeech,
  AudioClass.backgroundNoise,
];

String audioLabel(AudioClass c) {
  switch (c) {
    case AudioClass.help:
      return 'Help';
    case AudioClass.scream:
      return 'Scream';
    case AudioClass.normalSpeech:
      return 'Normal speech';
    case AudioClass.backgroundNoise:
      return 'Background noise';
  }
}

class AudioPrediction {
  final AudioClass event;
  final double confidence;
  final Map<AudioClass, double> scores;
  final DateTime timestamp;
  final PredictionSource source;

  const AudioPrediction({
    required this.event,
    required this.confidence,
    required this.scores,
    required this.timestamp,
    required this.source,
  });

  double get screamConfidence => scores[AudioClass.scream] ?? 0.0;
  double get helpConfidence => scores[AudioClass.help] ?? 0.0;

  /// Highest confidence across the two distress classes.
  double get distressConfidence =>
      screamConfidence > helpConfidence ? screamConfidence : helpConfidence;

  bool get isFromRealModel => source == PredictionSource.tfliteModel;

  String get label => audioLabel(event);

  @override
  String toString() =>
      'AudioPrediction($label, ${(confidence * 100).toStringAsFixed(1)}%, $source)';
}
