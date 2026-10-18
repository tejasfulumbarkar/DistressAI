import 'activity_prediction.dart';
import 'audio_prediction.dart';

enum RiskLevel { none, low, elevated, high }

String riskLevelLabel(RiskLevel level) {
  switch (level) {
    case RiskLevel.none:
      return 'Normal';
    case RiskLevel.low:
      return 'Low';
    case RiskLevel.elevated:
      return 'Elevated';
    case RiskLevel.high:
      return 'HIGH';
  }
}

/// All fusion thresholds live here so they can be tuned from Settings and
/// persisted locally. No threshold is hardcoded inside the fusion logic.
class RiskConfig {
  /// Motion confidence above which a fall is considered probable.
  final double fallTriggerThreshold;

  /// Motion confidence above which the microphone window is opened.
  final double audioWakeThreshold;

  /// Audio distress confidence considered meaningful.
  final double audioDistressThreshold;

  /// Fused score at or above this level triggers the emergency confirmation.
  final double highRiskThreshold;

  /// Fused score at or above this level is shown as "elevated" only.
  final double elevatedRiskThreshold;

  /// Weight of the motion signal in the fused score.
  final double motionWeight;

  /// Weight of the audio signal in the fused score.
  final double audioWeight;

  /// Seconds the "Are you safe?" countdown runs before escalating.
  final int countdownSeconds;

  const RiskConfig({
    this.fallTriggerThreshold = 0.70,
    this.audioWakeThreshold = 0.50,
    this.audioDistressThreshold = 0.60,
    this.highRiskThreshold = 0.70,
    this.elevatedRiskThreshold = 0.40,
    this.motionWeight = 0.65,
    this.audioWeight = 0.35,
    this.countdownSeconds = 15,
  });

  RiskConfig copyWith({
    double? fallTriggerThreshold,
    double? audioWakeThreshold,
    double? audioDistressThreshold,
    double? highRiskThreshold,
    double? elevatedRiskThreshold,
    double? motionWeight,
    double? audioWeight,
    int? countdownSeconds,
  }) {
    return RiskConfig(
      fallTriggerThreshold: fallTriggerThreshold ?? this.fallTriggerThreshold,
      audioWakeThreshold: audioWakeThreshold ?? this.audioWakeThreshold,
      audioDistressThreshold:
          audioDistressThreshold ?? this.audioDistressThreshold,
      highRiskThreshold: highRiskThreshold ?? this.highRiskThreshold,
      elevatedRiskThreshold:
          elevatedRiskThreshold ?? this.elevatedRiskThreshold,
      motionWeight: motionWeight ?? this.motionWeight,
      audioWeight: audioWeight ?? this.audioWeight,
      countdownSeconds: countdownSeconds ?? this.countdownSeconds,
    );
  }

  Map<String, dynamic> toMap() => {
        'fallTriggerThreshold': fallTriggerThreshold,
        'audioWakeThreshold': audioWakeThreshold,
        'audioDistressThreshold': audioDistressThreshold,
        'highRiskThreshold': highRiskThreshold,
        'elevatedRiskThreshold': elevatedRiskThreshold,
        'motionWeight': motionWeight,
        'audioWeight': audioWeight,
        'countdownSeconds': countdownSeconds,
      };

  static RiskConfig fromMap(Map<String, dynamic> map) {
    double d(String k, double fallback) {
      final v = map[k];
      return v is num ? v.toDouble() : fallback;
    }

    final defaults = const RiskConfig();
    return RiskConfig(
      fallTriggerThreshold:
          d('fallTriggerThreshold', defaults.fallTriggerThreshold),
      audioWakeThreshold: d('audioWakeThreshold', defaults.audioWakeThreshold),
      audioDistressThreshold:
          d('audioDistressThreshold', defaults.audioDistressThreshold),
      highRiskThreshold: d('highRiskThreshold', defaults.highRiskThreshold),
      elevatedRiskThreshold:
          d('elevatedRiskThreshold', defaults.elevatedRiskThreshold),
      motionWeight: d('motionWeight', defaults.motionWeight),
      audioWeight: d('audioWeight', defaults.audioWeight),
      countdownSeconds: (map['countdownSeconds'] is num)
          ? (map['countdownSeconds'] as num).toInt()
          : defaults.countdownSeconds,
    );
  }
}

class RiskAssessment {
  final double score;
  final RiskLevel level;
  final String reason;
  final ActivityPrediction? motion;
  final AudioPrediction? audio;
  final DateTime timestamp;

  const RiskAssessment({
    required this.score,
    required this.level,
    required this.reason,
    required this.timestamp,
    this.motion,
    this.audio,
  });

  bool get requiresConfirmation => level == RiskLevel.high;

  /// True only when every contributing signal came from a real .tflite model.
  bool get isFullyModelBacked {
    final m = motion;
    final a = audio;
    if (m != null && !m.isFromRealModel) return false;
    if (a != null && !a.isFromRealModel) return false;
    return m != null || a != null;
  }

  factory RiskAssessment.idle() => RiskAssessment(
        score: 0,
        level: RiskLevel.none,
        reason: 'No abnormal activity detected',
        timestamp: DateTime.now(),
      );
}
