import 'dart:math' as math;

/// A single timestamped 6-axis inertial sample.
///
/// Values come straight from the device sensors:
///   ax, ay, az  -> accelerometer (m/s^2, includes gravity)
///   gx, gy, gz  -> gyroscope (rad/s)
class SensorSample {
  final DateTime timestamp;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  const SensorSample({
    required this.timestamp,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  /// Accelerometer magnitude in m/s^2. ~9.81 when the device is at rest.
  double get accelerationMagnitude => math.sqrt(ax * ax + ay * ay + az * az);

  /// Angular velocity magnitude in rad/s.
  double get rotationMagnitude => math.sqrt(gx * gx + gy * gy + gz * gz);

  /// Feature order handed to the model: [ax, ay, az, gx, gy, gz].
  List<double> toFeatureVector() => <double>[ax, ay, az, gx, gy, gz];

  @override
  String toString() =>
      'SensorSample(${timestamp.toIso8601String()}, a=[$ax,$ay,$az], g=[$gx,$gy,$gz])';
}
