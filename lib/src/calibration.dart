import 'dart:math' as math;

import 'config.dart';

/// Exception thrown when a benchmark operation violates operational timing
/// bounds.
final class CalibrationException implements Exception {
  final String message;
  final double perOpDurationMicroseconds;

  CalibrationException(this.message, this.perOpDurationMicroseconds);

  @override
  String toString() =>
      'CalibrationException: $message (Measured: '
      '${perOpDurationMicroseconds.toStringAsFixed(3)} µs/op)';
}

/// Represents the calibrated batch parameters for an inner measurement loop.
final class CalibratedBatch {
  final int iterations;
  final double estimatedOpDurationMicroseconds;

  const CalibratedBatch({
    required this.iterations,
    required this.estimatedOpDurationMicroseconds,
  });
}

/// Utility for calibrating inner loop iteration counts.
abstract final class BenchmarkCalibrator {
  /// Calibrates batch size for synchronous action to reach target duration.
  static CalibratedBatch calibrateSync(
    void Function() action,
    BenchmarkConfig config,
  ) {
    var iterations = 1;
    final stopwatch = Stopwatch();

    // Exponential probing loop to find measurable duration
    while (true) {
      stopwatch.reset();
      stopwatch.start();
      for (var i = 0; i < iterations; i++) {
        action();
      }
      stopwatch.stop();

      final elapsedUs = stopwatch.elapsedMicroseconds;
      if (elapsedUs >= 5000 || iterations >= 1000000) {
        final perOpUs = elapsedUs / iterations;
        _validateOperationalBounds(perOpUs, config);

        final targetUs = config.targetBatchDuration.inMicroseconds;
        final targetIters = math.max(1, (targetUs / perOpUs).round());
        return CalibratedBatch(
          iterations: targetIters,
          estimatedOpDurationMicroseconds: perOpUs,
        );
      }

      final scaleFactor = 5000 / math.max(1, elapsedUs);
      iterations = math.max(iterations * 2, (iterations * scaleFactor).round());
    }
  }

  /// Calibrates batch size for asynchronous action to reach target duration.
  static Future<CalibratedBatch> calibrateAsync(
    Future<void> Function() action,
    BenchmarkConfig config,
  ) async {
    var iterations = 1;
    final stopwatch = Stopwatch();

    while (true) {
      stopwatch.reset();
      stopwatch.start();
      for (var i = 0; i < iterations; i++) {
        await action();
      }
      stopwatch.stop();

      final elapsedUs = stopwatch.elapsedMicroseconds;
      if (elapsedUs >= 5000 || iterations >= 10000) {
        final perOpUs = elapsedUs / iterations;
        _validateOperationalBounds(perOpUs, config);

        final targetUs = config.targetBatchDuration.inMicroseconds;
        final targetIters = math.max(1, (targetUs / perOpUs).round());
        return CalibratedBatch(
          iterations: targetIters,
          estimatedOpDurationMicroseconds: perOpUs,
        );
      }

      final scaleFactor = 5000 / math.max(1, elapsedUs);
      iterations = math.max(iterations * 2, (iterations * scaleFactor).round());
    }
  }

  static void _validateOperationalBounds(
    double perOpUs,
    BenchmarkConfig config,
  ) {
    if (perOpUs < 10.0 && !config.forceRun) {
      // Check for web timer virtualization (if elapsed reports ~0 on JS/Wasm)
      if (perOpUs <= 0.0) {
        config.logger?.call(
          'Warning: Measured 0 µs per operation. Likely browser timer '
          'quantization. Calibrating with higher iteration volume.',
        );
        return;
      }
      throw CalibrationException(
        'Operation latency is below the 10 µs lower-bound threshold. '
        'Microbenchmarks below 10 µs must be batched or run with forceRun: '
        'true.',
        perOpUs,
      );
    }

    if (perOpUs > 200000.0) {
      throw CalibrationException(
        'Operation latency exceeds the 200 ms upper-bound threshold. '
        'Individual iterations > 200 ms should use macro-benchmarking with '
        'fewer trials.',
        perOpUs,
      );
    }

    if (perOpUs < 1000.0) {
      config.logger?.call(
        'Notice: Operation latency (${perOpUs.toStringAsFixed(1)} µs) is < 1 '
        'ms. Inner loop batching will scale iterations to ensure timer '
        'resolution > 99.9%.',
      );
    }
  }
}
