import '../models/activity_prediction.dart';
import '../models/audio_prediction.dart';
import '../models/risk_assessment.dart';

/// Fuses the motion and audio signals into a single risk score.
///
/// The design goal from the brief: no single signal should be able to trigger an
/// emergency on its own.
///
///   fall 0.92 + scream 0.81 -> high risk
///   scream 0.85 + fall 0.10 -> NOT an emergency
///
/// This is achieved by gating on motion: the audio signal can only add weight
/// once the motion side has passed [RiskConfig.fallTriggerThreshold]. Audio
/// alone is capped below the high-risk threshold and surfaces as "elevated" so
/// the user still sees it in the UI.
class RiskAssessmentService {
  RiskConfig config;

  RiskAssessmentService({this.config = const RiskConfig()});

  RiskAssessment assess({
    ActivityPrediction? motion,
    AudioPrediction? audio,
  }) {
    final now = DateTime.now();

    if (motion == null && audio == null) {
      return RiskAssessment.idle();
    }

    final fall = motion?.fallConfidence ?? 0.0;
    final distress = audio?.distressConfidence ?? 0.0;

    final motionConfirmed = fall >= config.fallTriggerThreshold;
    final audioConfirmed = distress >= config.audioDistressThreshold;

    double score;
    String reason;

    if (motionConfirmed && audioConfirmed) {
      // Both signals agree — the strongest case.
      score = config.motionWeight * fall + config.audioWeight * distress;
      reason =
          'Fall detected (${_pct(fall)}) confirmed by audio ${audio!.label.toLowerCase()} (${_pct(distress)})';
    } else if (motionConfirmed) {
      // Motion alone can reach high risk, because a fall with no sound is a
      // realistic unconscious-victim case.
      score = config.motionWeight * fall;
      reason = audio == null
          ? 'Fall detected (${_pct(fall)}), no audio window classified'
          : 'Fall detected (${_pct(fall)}), audio did not confirm distress (${audio.label}, ${_pct(distress)})';
    } else if (audioConfirmed) {
      // Audio alone is intentionally capped just under the high threshold.
      final capped = config.highRiskThreshold - 0.01;
      score = config.audioWeight * distress;
      if (score > capped) score = capped;
      reason =
          'Audio distress (${audio!.label}, ${_pct(distress)}) without matching motion — monitoring, not escalating';
    } else {
      final motionPart = config.motionWeight * fall;
      final audioPart = config.audioWeight * distress;
      score = motionPart + audioPart;
      reason = motion != null
          ? 'Activity: ${motion.label} (${_pct(motion.confidence)})'
          : 'No abnormal motion detected';
    }

    if (score < 0) score = 0;
    if (score > 1) score = 1;

    return RiskAssessment(
      score: score,
      level: _levelFor(score),
      reason: reason,
      motion: motion,
      audio: audio,
      timestamp: now,
    );
  }

  /// Risk for a manual SOS press. Always maximal and clearly attributed.
  RiskAssessment manualSos() => RiskAssessment(
        score: 1.0,
        level: RiskLevel.high,
        reason: 'Manual SOS pressed by the user',
        timestamp: DateTime.now(),
      );

  /// True when the motion signal is strong enough to justify opening the mic.
  bool shouldWakeMicrophone(double fallConfidence) =>
      fallConfidence >= config.audioWakeThreshold;

  RiskLevel _levelFor(double score) {
    if (score >= config.highRiskThreshold) return RiskLevel.high;
    if (score >= config.elevatedRiskThreshold) return RiskLevel.elevated;
    if (score > 0.05) return RiskLevel.low;
    return RiskLevel.none;
  }

  static String _pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
}
