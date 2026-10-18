import 'package:url_launcher/url_launcher.dart';

import '../models/risk_assessment.dart';
import 'location_service.dart';

/// What actually happened to an alert. There is no value here that means
/// "pretend it was sent".
enum AlertDeliveryState {
  /// Payload assembled and held on the device. Nothing has left the phone.
  preparedLocally,

  /// The dialer / SMS app was opened for the user to confirm and send.
  handedToDialer,

  /// A remote backend accepted the alert. Only reachable once a backend is
  /// wired into [sendToBackend].
  sentToBackend,

  /// A send was attempted and failed.
  failed,
}

class EmergencyContact {
  final String name;
  final String phone;

  const EmergencyContact({required this.name, required this.phone});

  Map<String, dynamic> toMap() => {'name': name, 'phone': phone};

  static EmergencyContact fromMap(Map<String, dynamic> map) => EmergencyContact(
        name: (map['name'] ?? '') as String,
        phone: (map['phone'] ?? '') as String,
      );
}

/// The alert payload, fully assembled offline.
class EmergencyAlert {
  final DateTime timestamp;
  final LocationFix? location;
  final String detectionReason;
  final double riskScore;
  final bool modelBacked;
  final bool demoMode;
  final AlertDeliveryState state;
  final String? stateDetail;

  const EmergencyAlert({
    required this.timestamp,
    required this.detectionReason,
    required this.riskScore,
    required this.modelBacked,
    required this.demoMode,
    required this.state,
    this.location,
    this.stateDetail,
  });

  EmergencyAlert copyWith({
    AlertDeliveryState? state,
    String? stateDetail,
    LocationFix? location,
  }) {
    return EmergencyAlert(
      timestamp: timestamp,
      detectionReason: detectionReason,
      riskScore: riskScore,
      modelBacked: modelBacked,
      demoMode: demoMode,
      state: state ?? this.state,
      stateDetail: stateDetail ?? this.stateDetail,
      location: location ?? this.location,
    );
  }

  /// The message body a backend or SMS gateway would send.
  String get messageBody {
    final loc = location;
    final buffer = StringBuffer()
      ..writeln(demoMode
          ? '[DEMO MODE — not a real emergency]'
          : 'EMERGENCY DETECTED')
      ..writeln('Time: ${timestamp.toLocal()}')
      ..writeln('Reason: $detectionReason')
      ..writeln('Risk score: ${(riskScore * 100).toStringAsFixed(0)}%');

    if (loc != null) {
      buffer
        ..writeln('Location: ${loc.shortText} (${loc.accuracyText})')
        ..writeln('Map: ${loc.mapsUrl}');
    } else {
      buffer.writeln('Location: unavailable');
    }

    buffer.writeln(modelBacked
        ? 'Source: on-device model inference'
        : 'Source: simulated (DEMO MODE) — no model inference');
    return buffer.toString();
  }

  String get stateLabel {
    switch (state) {
      case AlertDeliveryState.preparedLocally:
        return 'Prepared on device — NOT sent';
      case AlertDeliveryState.handedToDialer:
        return 'Handed to your phone app — you must confirm the send';
      case AlertDeliveryState.sentToBackend:
        return 'Delivered to backend';
      case AlertDeliveryState.failed:
        return 'Send failed';
    }
  }
}

/// Emergency dispatch abstraction.
///
/// [prepare] assembles the payload locally and marks it
/// [AlertDeliveryState.preparedLocally]. The UI shows exactly that state — it
/// never claims a message was delivered.
///
/// [sendToBackend] is the single seam for a future Firebase/REST backend. It
/// currently returns a failed state with an explanation instead of faking
/// success.
class EmergencyAlertService {
  EmergencyAlert? _lastAlert;

  EmergencyAlert? get lastAlert => _lastAlert;

  /// Whether a backend has been configured. Flip this by implementing
  /// [sendToBackend] and returning true from here.
  bool get isBackendConfigured => false;

  EmergencyAlert prepare({
    required RiskAssessment assessment,
    required bool demoMode,
    LocationFix? location,
  }) {
    final alert = EmergencyAlert(
      timestamp: DateTime.now(),
      detectionReason: assessment.reason,
      riskScore: assessment.score,
      modelBacked: assessment.isFullyModelBacked,
      demoMode: demoMode,
      location: location,
      state: AlertDeliveryState.preparedLocally,
      stateDetail:
          'Payload built offline. No SMS, push notification, or network request has been made.',
    );
    _lastAlert = alert;
    return alert;
  }

  /// Opens the dialer with the contact's number. The user still has to press
  /// call, so this reports [AlertDeliveryState.handedToDialer], not "sent".
  Future<EmergencyAlert> callContact(
    EmergencyAlert alert,
    EmergencyContact contact,
  ) async {
    final uri = Uri(scheme: 'tel', path: contact.phone);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      final updated = alert.copyWith(
        state: ok
            ? AlertDeliveryState.handedToDialer
            : AlertDeliveryState.failed,
        stateDetail: ok
            ? 'Dialer opened for ${contact.name} (${contact.phone}). Press call to actually place it.'
            : 'Could not open the dialer on this device.',
      );
      _lastAlert = updated;
      return updated;
    } catch (e) {
      final updated = alert.copyWith(
        state: AlertDeliveryState.failed,
        stateDetail: 'Could not open the dialer: $e',
      );
      _lastAlert = updated;
      return updated;
    }
  }

  /// Opens the SMS composer pre-filled with the alert body. Again: the user
  /// sends it, so the state is "handed to" the messaging app.
  Future<EmergencyAlert> composeSms(
    EmergencyAlert alert,
    EmergencyContact contact,
  ) async {
    final uri = Uri(
      scheme: 'sms',
      path: contact.phone,
      queryParameters: <String, String>{'body': alert.messageBody},
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      final updated = alert.copyWith(
        state: ok
            ? AlertDeliveryState.handedToDialer
            : AlertDeliveryState.failed,
        stateDetail: ok
            ? 'Messaging app opened with the alert text. Press send to actually deliver it.'
            : 'Could not open the messaging app on this device.',
      );
      _lastAlert = updated;
      return updated;
    } catch (e) {
      final updated = alert.copyWith(
        state: AlertDeliveryState.failed,
        stateDetail: 'Could not open the messaging app: $e',
      );
      _lastAlert = updated;
      return updated;
    }
  }

  /// Backend seam — intentionally unimplemented.
  ///
  /// To add Firebase Cloud Messaging or your own REST endpoint later, replace
  /// this body with the real call and return
  /// [AlertDeliveryState.sentToBackend] only after the server confirms.
  Future<EmergencyAlert> sendToBackend(EmergencyAlert alert) async {
    final updated = alert.copyWith(
      state: AlertDeliveryState.failed,
      stateDetail:
          'No backend configured. Implement EmergencyAlertService.sendToBackend() '
          'to post this payload to Firebase or your own server.',
    );
    _lastAlert = updated;
    return updated;
  }
}
