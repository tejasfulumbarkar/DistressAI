
enum ActivityClass {
  standing,
  sitting,
  walking,
  fall,
}

const List<ActivityClass> kActivityClassOrder = <ActivityClass>[
  ActivityClass.sitting,
  ActivityClass.standing,
  ActivityClass.walking,
  ActivityClass.fall,
];

String activityLabel(ActivityClass c) {
  switch (c) {
    case ActivityClass.standing:
      return 'Standing';
    case ActivityClass.sitting:
      return 'Sitting';
    case ActivityClass.walking:
      return 'Walking';
    case ActivityClass.fall:
      return 'Fall';
  }
}

enum PredictionSource {
  tfliteModel,
  demoMode,
}

class ActivityPrediction {
  final ActivityClass activity;
  final double confidence;
  final Map<ActivityClass, double> scores;
  final DateTime timestamp;
  final PredictionSource source;

  const ActivityPrediction({
    required this.activity,
    required this.confidence,
    required this.scores,
    required this.timestamp,
    required this.source,
  });

  bool get isFall => activity == ActivityClass.fall;

  double get fallConfidence =>
      scores[ActivityClass.fall] ?? 0.0;

  bool get isFromRealModel =>
      source == PredictionSource.tfliteModel;

  String get label => activityLabel(activity);

  @override
  String toString() =>
      'ActivityPrediction($label, '
      '${(confidence * 100).toStringAsFixed(1)}%, $source)';
}