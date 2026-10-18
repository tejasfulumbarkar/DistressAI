import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../models/sensor_sample.dart';

/// Reads the device's real accelerometer and gyroscope.
///
/// The two hardware streams fire independently, so the service keeps the most
/// recent gyroscope reading and pairs it with each incoming accelerometer
/// event. That gives one fused 6-axis sample per accelerometer tick.
///
/// There is no synthetic or random data anywhere in this class. If the hardware
/// is missing, the corresponding stream errors out and [availabilityMessage]
/// reports it.
class SensorService {
  /// Target sampling period. 20 ms => ~50 Hz, which is the usual rate for
  /// public human-activity-recognition datasets.
  static const Duration samplingPeriod = Duration(milliseconds: 20);
  static const int samplingRateHz = 50;

  final StreamController<SensorSample> _controller =
      StreamController<SensorSample>.broadcast();

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  GyroscopeEvent? _lastGyro;

  bool _accelerometerAvailable = false;
  bool _gyroscopeAvailable = false;
  bool _running = false;
  String? _lastError;

  Stream<SensorSample> get samples => _controller.stream;

  bool get isRunning => _running;
  bool get accelerometerAvailable => _accelerometerAvailable;
  bool get gyroscopeAvailable => _gyroscopeAvailable;

  /// Human-readable hardware status for the monitoring screen.
  String get availabilityMessage {
    if (!_running) return 'Sensors idle';
    if (_lastError != null) return 'Sensor error: $_lastError';
    if (_accelerometerAvailable && _gyroscopeAvailable) {
      return 'Accelerometer + gyroscope active (~$samplingRateHz Hz)';
    }
    if (_accelerometerAvailable) {
      return 'Accelerometer active, gyroscope unavailable';
    }
    if (_gyroscopeAvailable) {
      return 'Gyroscope active, accelerometer unavailable';
    }
    return 'Waiting for sensor data...';
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _lastError = null;

    _gyroSub = gyroscopeEventStream(samplingPeriod: samplingPeriod).listen(
      (event) {
        _gyroscopeAvailable = true;
        _lastGyro = event;
      },
      onError: (Object error) {
        _gyroscopeAvailable = false;
        _lastError = 'gyroscope unavailable';
      },
      cancelOnError: false,
    );

    _accelSub = accelerometerEventStream(samplingPeriod: samplingPeriod).listen(
      (event) {
        _accelerometerAvailable = true;
        final gyro = _lastGyro;
        _controller.add(
          SensorSample(
            timestamp: DateTime.now(),
            ax: event.x,
            ay: event.y,
            az: event.z,
            // If the device has no gyroscope we submit zeros rather than
            // fabricated values, and availabilityMessage says so.
            gx: gyro?.x ?? 0.0,
            gy: gyro?.y ?? 0.0,
            gz: gyro?.z ?? 0.0,
          ),
        );
      },
      onError: (Object error) {
        _accelerometerAvailable = false;
        _lastError = 'accelerometer unavailable';
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    _running = false;
    await _accelSub?.cancel();
    await _gyroSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _lastGyro = null;
    _accelerometerAvailable = false;
    _gyroscopeAvailable = false;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
