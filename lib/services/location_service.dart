import 'package:geolocator/geolocator.dart';

class LocationFix {
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;

  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
  });

  String get shortText =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  String get accuracyText =>
      '±${accuracyMeters.toStringAsFixed(0)} m';

  String get mapsUrl =>
      'https://maps.google.com/?q=$latitude,$longitude';
}

enum LocationStatus {
  ready,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  failed,
}

class LocationService {
  Future<LocationStatus> checkPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      return LocationStatus.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      return LocationStatus.permissionDenied;
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationStatus.permissionDeniedForever;
    }

    return LocationStatus.ready;
  }

  Future<LocationFix?> getCurrentLocation() async {
    final status = await checkPermission();

    if (status != LocationStatus.ready) {
      return null;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
  desiredAccuracy: LocationAccuracy.high,
);

      return LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        timestamp: position.timestamp ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> openLocationSettings() async {
    return Geolocator.openLocationSettings();
  }

  Future<bool> openAppSettings() async {
    return Geolocator.openAppSettings();
  }
}