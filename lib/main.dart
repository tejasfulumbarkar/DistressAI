import 'dart:async';

import 'package:flutter/material.dart';

import 'models/activity_prediction.dart';
import 'models/risk_assessment.dart';
import 'models/sensor_sample.dart';

import 'services/emergency_alert_service.dart';
import 'services/location_service.dart';
import 'services/motion_inference_service.dart';
import 'services/risk_assessment_service.dart';
import 'services/sensor_service.dart';

void main() {
  runApp(const DistressAI());
}

class DistressAI extends StatelessWidget {
  const DistressAI({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Distress AI',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090B10),
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SensorService _sensorService = SensorService();

  final MotionInferenceService _motionService = MotionInferenceService();

  final RiskAssessmentService _riskService = RiskAssessmentService();

  final EmergencyAlertService _alertService = EmergencyAlertService();

  final LocationService _locationService = LocationService();

  StreamSubscription<SensorSample>? _sensorSubscription;

  // CHANGE THIS
  // Put the emergency contact's actual phone number here.
  final EmergencyContact _emergencyContact = const EmergencyContact(
    name: 'Emergency Contact',
    phone: '7219287449',
  );

  bool monitoring = true;
  bool modelReady = false;

  String activity = 'Model: loading...';
  double activityConfidence = 0.0;
  double risk = 0.08;

  SensorSample? latestSample;
  ActivityPrediction? latestPrediction;

  // Fall confirmation flow
  Timer? _confirmationTimer;
  bool _fallConfirmationShowing = false;
  int _confirmationSeconds = 15;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load the real TinyFall TFLite model.
    final loaded = await _motionService.initialize();

    if (!mounted) return;

    setState(() {
      modelReady = loaded;

      activity = loaded
          ? 'AI loaded • Input: ${_motionService.modelInputShape} • Output: ${_motionService.modelOutputShape}'
          : 'AI model failed: ${_motionService.modelLoadError ?? "Unknown error"}';
    });

    await _startSensors();
  }

  Future<void> _startSensors() async {
    await _sensorService.start();

    await _sensorSubscription?.cancel();

    _sensorSubscription = _sensorService.samples.listen(_handleSensorSample);

    if (!mounted) return;

    setState(() {
      monitoring = true;

      if (modelReady) {
        activity = 'Model loaded — collecting data...';
      } else {
        activity = 'Loading AI model...';
      }
    });
  }

  void _handleSensorSample(SensorSample sample) {
    if (!mounted) return;

    // Always show the real sensor values.
    setState(() {
      latestSample = sample;
    });

    if (!modelReady) {
      return;
    }

    // Feed every real sensor sample into the TinyFall window.
    final window = _motionService.addSample(sample);

    if (window == null) {
      return;
    }

    debugPrint('TINYFALL WINDOW READY: ${window.length} samples');

    final prediction = _motionService.classifyWindow(window);

    debugPrint('TINYFALL PREDICTION: $prediction');

    if (prediction == null) {
      return;
    }

    // Trigger the safety confirmation when TinyFall detects a fall.
    // 70% is the current fall-confidence threshold.
    if (prediction.isFall && prediction.confidence >= 0.70) {
      _triggerFallConfirmation(prediction);
    }

    final newRisk = _calculateMotionRisk(prediction);

    setState(() {
      latestPrediction = prediction;
      activity = _activityName(prediction.activity);
      activityConfidence = prediction.confidence;
      risk = newRisk;
    });
  }

  double _calculateMotionRisk(ActivityPrediction prediction) {
    switch (prediction.activity) {
      case ActivityClass.fall:
        return prediction.confidence;

      case ActivityClass.walking:
        return 0.05;

      case ActivityClass.sitting:
        return 0.02;

      case ActivityClass.standing:
        return 0.02;
    }
  }

  String _activityName(ActivityClass activity) {
    switch (activity) {
      case ActivityClass.sitting:
        return 'Sitting';

      case ActivityClass.standing:
        return 'Standing';

      case ActivityClass.walking:
        return 'Walking';

      case ActivityClass.fall:
        return 'Falling';
    }
  }

  // ============================================================
  // EMERGENCY FLOW
  // ============================================================

  Future<void> _triggerEmergencyAlert({
    required RiskAssessment assessment,
  }) async {
    if (!mounted) return;

    // Show that the emergency flow has started.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Getting your location...')),
          ],
        ),
      ),
    );

    LocationFix? location;

    try {
      location = await _locationService.getCurrentLocation();
    } catch (e) {
      debugPrint('LOCATION ERROR: $e');
    }

    if (!mounted) return;

    // Prepare the emergency alert using the existing service.
    final alert = _alertService.prepare(
      assessment: assessment,
      demoMode: false,
      location: location,
    );

    debugPrint('EMERGENCY ALERT PREPARED');

    debugPrint('Location: ${location?.shortText ?? "Unavailable"}');

    // Open SMS composer with the prepared message.
    final result = await _alertService.composeSms(alert, _emergencyContact);

    if (!mounted) return;

    if (result.state == AlertDeliveryState.handedToDialer) {
      _showSmsReadyMessage(location: location);
    } else {
      _showEmergencyError(result.stateDetail);
    }
  }

  void _showSmsReadyMessage({LocationFix? location}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF166534),
        content: Row(
          children: [
            const Icon(Icons.sms_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                location != null
                    ? 'Emergency SMS ready with your location. Tap SEND in the messaging app.'
                    : 'Emergency SMS ready. Location could not be obtained.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEmergencyError(String? detail) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFFB91C1C),
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Could not open emergency SMS${detail == null ? '' : ': $detail'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // FALL CONFIRMATION
  // ============================================================

  void _triggerFallConfirmation(ActivityPrediction prediction) {
    if (!mounted || _fallConfirmationShowing) {
      return;
    }

    _fallConfirmationShowing = true;
    _confirmationSeconds = 15;

    _confirmationTimer?.cancel();
    _confirmationTimer = null;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _confirmationTimer ??= Timer.periodic(const Duration(seconds: 1), (
              timer,
            ) {
              if (!mounted) {
                timer.cancel();
                _confirmationTimer = null;
                return;
              }

              if (_confirmationSeconds <= 1) {
                timer.cancel();
                _confirmationTimer = null;

                Navigator.of(dialogContext).pop();
                _fallConfirmationShowing = false;

                // No response = emergency.
                final assessment = _riskService.assess(motion: prediction);

                _triggerEmergencyAlert(assessment: assessment);

                return;
              }

              setDialogState(() {
                _confirmationSeconds--;
              });
            });

            return AlertDialog(
              backgroundColor: const Color(0xFF11151D),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 30,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Fall detected',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Are you safe?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'SOS will be triggered in $_confirmationSeconds seconds',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 22),

                  // I'M SAFE
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () {
                        _confirmationTimer?.cancel();
                        _confirmationTimer = null;

                        Navigator.of(dialogContext).pop();
                        _fallConfirmationShowing = false;
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        "I'M SAFE",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // I'M NOT SAFE
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton(
                      onPressed: () {
                        _confirmationTimer?.cancel();
                        _confirmationTimer = null;

                        Navigator.of(dialogContext).pop();
                        _fallConfirmationShowing = false;

                        final assessment = _riskService.assess(
                          motion: prediction,
                        );

                        _triggerEmergencyAlert(assessment: assessment);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        "I'M NOT SAFE",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ============================================================
  // MONITORING
  // ============================================================

  Future<void> _toggleMonitoring(bool value) async {
    if (value) {
      _motionService.reset();
      await _startSensors();
    } else {
      _confirmationTimer?.cancel();
      _confirmationTimer = null;

      if (_fallConfirmationShowing && mounted) {
        Navigator.of(context, rootNavigator: true).pop();

        _fallConfirmationShowing = false;
      }

      await _sensorSubscription?.cancel();
      _sensorSubscription = null;

      await _sensorService.stop();

      _motionService.reset();

      if (!mounted) return;

      setState(() {
        monitoring = false;
        activity = 'Monitoring paused';
        activityConfidence = 0.0;
        latestPrediction = null;
      });
    }
  }

  // ============================================================
  // MANUAL SOS
  // ============================================================

  void _showSOSConfirmation(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF11151D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 35),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 25),
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.amber,
                size: 48,
              ),
              const SizedBox(height: 14),
              const Text(
                'Send emergency alert?',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your emergency contact will receive a prepared SMS containing your current location.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, height: 1.4),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);

                    final assessment = _riskService.manualSos();

                    _triggerEmergencyAlert(assessment: assessment);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: const Text(
                    'SEND EMERGENCY ALERT',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _confirmationTimer?.cancel();
    _confirmationTimer = null;

    _sensorSubscription?.cancel();
    _sensorService.dispose();
    _motionService.dispose();

    super.dispose();
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final sample = latestSample;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // HEADER
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C63FF),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.shield_rounded, size: 27),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Distress AI',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Personal safety companion',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),

              const SizedBox(height: 28),

              // SYSTEM STATUS
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF11151D),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: monitoring
                            ? const Color(0xFF173B2B)
                            : const Color(0xFF332B18),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        monitoring ? Icons.check_rounded : Icons.pause_rounded,
                        color: monitoring
                            ? const Color(0xFF4ADE80)
                            : Colors.amber,
                        size: 27,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            monitoring
                                ? 'System is active'
                                : 'Monitoring paused',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            modelReady
                                ? 'Motion AI model loaded'
                                : 'Loading motion AI model...',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(value: monitoring, onChanged: _toggleMonitoring),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'LIVE MONITORING',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  color: Colors.white38,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 10),

              // MOTION + AUDIO
              Row(
                children: [
                  Expanded(
                    child: _StatusCard(
                      icon: Icons.directions_run_rounded,
                      title: 'Motion',
                      value: monitoring ? 'Active' : 'Paused',
                      subtitle: monitoring
                          ? 'Accelerometer + Gyroscope'
                          : 'Sensors stopped',
                      iconColor: const Color(0xFF6C63FF),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatusCard(
                      icon: Icons.mic_none_rounded,
                      title: 'Audio',
                      value: 'Standby',
                      subtitle: 'Triggered when needed',
                      iconColor: const Color(0xFF38BDF8),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // SENSOR DATA
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF11151D),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.sensors_rounded,
                          size: 20,
                          color: Colors.white70,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Live sensor data',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    _SensorRow(
                      label: 'Accelerometer',
                      value: sample == null
                          ? 'Waiting...'
                          : 'X ${sample.ax.toStringAsFixed(2)}  '
                                'Y ${sample.ay.toStringAsFixed(2)}  '
                                'Z ${sample.az.toStringAsFixed(2)}',
                    ),

                    const SizedBox(height: 10),

                    _SensorRow(
                      label: 'Gyroscope',
                      value: sample == null
                          ? 'Waiting...'
                          : 'X ${sample.gx.toStringAsFixed(2)}  '
                                'Y ${sample.gy.toStringAsFixed(2)}  '
                                'Z ${sample.gz.toStringAsFixed(2)}',
                    ),

                    const SizedBox(height: 10),

                    _SensorRow(
                      label: 'Acceleration',
                      value: sample == null
                          ? '--'
                          : '${sample.accelerationMagnitude.toStringAsFixed(2)} m/s²',
                    ),

                    const SizedBox(height: 10),

                    _SensorRow(
                      label: 'Rotation',
                      value: sample == null
                          ? '--'
                          : '${sample.rotationMagnitude.toStringAsFixed(2)} rad/s',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // RISK
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF11151D),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.radar_rounded,
                          size: 20,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Current risk',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${(risk * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: LinearProgressIndicator(
                        value: risk,
                        minHeight: 8,
                        backgroundColor: Colors.white10,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      latestPrediction == null
                          ? 'Waiting for AI prediction...'
                          : 'Motion AI • ${(activityConfidence * 100).toInt()}% confidence',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // LIVE STATUS
              const Text(
                'Live ...',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),

              const SizedBox(height: 28),

              // SOS
              SizedBox(
                width: double.infinity,
                height: 62,
                child: ElevatedButton(
                  onPressed: () {
                    _showSOSConfirmation(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.sos_rounded, size: 27),
                      SizedBox(width: 10),
                      Text(
                        'SEND SOS',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              Center(
                child: Text(
                  'Emergency contact will be notified',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// STATUS CARD
// ============================================================

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color iconColor;

  const _StatusCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF11151D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 21),
          ),
          const SizedBox(height: 15),
          Text(
            title,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SENSOR ROW
// ============================================================

class _SensorRow extends StatelessWidget {
  final String label;
  final String value;

  const _SensorRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 105,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}
