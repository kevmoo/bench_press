import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'config.dart';

/// Exception thrown when a benchmark operation violates operational timing
/// bounds.
final class CalibrationException(
  final String message,
  final double perOpDurationMicroseconds,
) implements Exception {
  @override
  String toString() =>
      'CalibrationException: $message (Measured: '
      '${perOpDurationMicroseconds.toStringAsFixed(3)} µs/op)';
}

/// Represents the calibrated batch parameters for an inner measurement loop.
final class const CalibratedBatch({
  required final int iterations,
  required final double estimatedOpDurationMicroseconds,
});

/// Minimum elapsed duration in microseconds (5 ms) for a calibration probe
/// batch.
///
/// Running a probe batch for at least 5 ms ensures system timer quantization
/// jitter (< 1 µs on native platforms, 5–100 µs on web/browsers due to Spectre
/// mitigations) remains below 1%, providing an accurate baseline measurement
/// to extrapolate target batch iterations.
const int _minProbeDurationUs = 5000;

/// Maximum iteration ceiling (1,000,000) allowed during exponential
/// calibration probing.
///
/// Prevents runaway probing loops on ultra-fast, no-op, or
/// dead-code-eliminated benchmark operations, guaranteeing calibration
/// terminates in bounded time.
const int _maxProbeIterations = 1000000;

/// Maximum per-operation latency in microseconds (200 ms) permitted for
/// micro-benchmarks.
///
/// Operations exceeding 200 ms/op are considered macro-benchmarks that should
/// execute with fewer trials rather than through high-frequency inner loops.
const double _macroBenchmarkThresholdUs = 200000.0;

/// Sub-millisecond latency threshold in microseconds (1 ms) below which
/// inner-loop batching is activated to maintain high timer resolution
/// (> 99.9%).
const double _subMillisecondNoticeThresholdUs = 1000.0;

/// Utility for calibrating inner loop iteration counts.
abstract final class BenchmarkCalibrator() {
  /// Calibrates batch size for synchronous action to reach target duration.
  static CalibratedBatch calibrateSync(
    void Function() action,
    BenchmarkConfig config, {
    @visibleForTesting Stopwatch? stopwatch,
  }) {
    var iterations = 1;
    stopwatch ??= Stopwatch();

    // Exponential probing loop to find measurable duration
    while (true) {
      stopwatch.reset();
      stopwatch.start();
      for (var i = 0; i < iterations; i++) {
        action();
      }
      stopwatch.stop();

      final elapsedUs = stopwatch.elapsedMicroseconds;
      if (elapsedUs >= _minProbeDurationUs ||
          iterations >= _maxProbeIterations) {
        final perOpUs = elapsedUs / iterations;
        _validateOperationalBounds(elapsedUs, perOpUs, config);

        final targetUs = config.targetBatchDuration.inMicroseconds;
        final targetIters = perOpUs > 0.0
            ? math.max(1, (targetUs / perOpUs).round())
            : iterations;
        return CalibratedBatch(
          iterations: targetIters,
          estimatedOpDurationMicroseconds: perOpUs,
        );
      }

      final scaleFactor = _minProbeDurationUs / math.max(1, elapsedUs);
      iterations = math.min(
        iterations * 10,
        math.max(iterations * 2, (iterations * scaleFactor).round()),
      );
      iterations = math.min(iterations, _maxProbeIterations);
    }
  }

  /// Calibrates batch size for asynchronous action to reach target duration.
  static Future<CalibratedBatch> calibrateAsync(
    Future<void> Function() action,
    BenchmarkConfig config, {
    @visibleForTesting Stopwatch? stopwatch,
  }) async {
    var iterations = 1;
    stopwatch ??= Stopwatch();

    while (true) {
      stopwatch.reset();
      stopwatch.start();
      for (var i = 0; i < iterations; i++) {
        await action();
      }
      stopwatch.stop();

      final elapsedUs = stopwatch.elapsedMicroseconds;
      if (elapsedUs >= _minProbeDurationUs ||
          iterations >= _maxProbeIterations) {
        final perOpUs = elapsedUs / iterations;
        _validateOperationalBounds(elapsedUs, perOpUs, config);

        final targetUs = config.targetBatchDuration.inMicroseconds;
        final targetIters = perOpUs > 0.0
            ? math.max(1, (targetUs / perOpUs).round())
            : iterations;
        return CalibratedBatch(
          iterations: targetIters,
          estimatedOpDurationMicroseconds: perOpUs,
        );
      }

      final scaleFactor = _minProbeDurationUs / math.max(1, elapsedUs);
      iterations = math.min(
        iterations * 10,
        math.max(iterations * 2, (iterations * scaleFactor).round()),
      );
      iterations = math.min(iterations, _maxProbeIterations);
    }
  }

  static void _validateOperationalBounds(
    int elapsedUs,
    double perOpUs,
    BenchmarkConfig config,
  ) {
    if (elapsedUs <= 0) {
      if (!config.forceRun) {
        throw CalibrationException(
          'Maximum probe batch produced 0 elapsed ticks. '
          'Operation is too fast or timer resolution is insufficient.',
          perOpUs,
        );
      }
      config.logger?.call(
        'Warning: Maximum probe batch produced 0 elapsed ticks '
        '(elapsedUs == 0). Timer quantization detected; measurements may '
        'have high quantization error.',
      );
      return;
    }

    if (perOpUs > _macroBenchmarkThresholdUs) {
      throw CalibrationException(
        'Operation latency exceeds the 200 ms upper-bound threshold. '
        'Individual iterations > 200 ms should use macro-benchmarking with '
        'fewer trials.',
        perOpUs,
      );
    }

    if (perOpUs < _subMillisecondNoticeThresholdUs) {
      config.logger?.call(
        'Notice: Operation latency (${perOpUs.toStringAsFixed(1)} µs) is < 1 '
        'ms. Inner loop batching will scale iterations to ensure timer '
        'resolution > 99.9%.',
      );
    }
  }
}
