import 'dart:async';

import 'blackhole.dart';
import 'harness.dart';

/// Result from executing a single calibrated measurement batch.
final class BatchMeasurement {
  /// The calibrated iteration count executed during the batch.
  final int iterations;

  /// Total elapsed time in microseconds for the entire batch.
  final int totalElapsedMicroseconds;

  /// Derived per-operation latency in nanoseconds.
  final double perOpNanoseconds;

  const BatchMeasurement({
    required this.iterations,
    required this.totalElapsedMicroseconds,
    required this.perOpNanoseconds,
  });
}

/// Executes monomorphic inner measurement batch loops.
abstract final class BatchRunner {
  /// Runs a single synchronous measurement batch for [benchmark] with
  /// [iterations].
  static BatchMeasurement runSync(Benchmark benchmark, int iterations) {
    final stopwatch = Stopwatch();

    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      benchmark.run();
    }
    stopwatch.stop();

    // Drain the Blackhole to prevent dead-store elimination of writes
    Blackhole.drain();

    final elapsedUs = stopwatch.elapsedMicroseconds;
    final perOpNs = (elapsedUs * 1000.0) / iterations;

    return BatchMeasurement(
      iterations: iterations,
      totalElapsedMicroseconds: elapsedUs,
      perOpNanoseconds: perOpNs,
    );
  }

  /// Runs a single asynchronous measurement batch for [benchmark] with
  /// [iterations].
  static Future<BatchMeasurement> runAsync(
    AsyncBenchmark benchmark,
    int iterations,
  ) async {
    final stopwatch = Stopwatch();

    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      await benchmark.run();
    }
    stopwatch.stop();

    Blackhole.drain();

    final elapsedUs = stopwatch.elapsedMicroseconds;
    final perOpNs = (elapsedUs * 1000.0) / iterations;

    return BatchMeasurement(
      iterations: iterations,
      totalElapsedMicroseconds: elapsedUs,
      perOpNanoseconds: perOpNs,
    );
  }

  /// Runs a synchronous measurement batch for a [variant].
  static BatchMeasurement runVariantSync(
    BenchmarkVariant variant,
    int iterations,
  ) {
    final stopwatch = Stopwatch();

    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      variant.executeSync();
    }
    stopwatch.stop();

    Blackhole.drain();

    final elapsedUs = stopwatch.elapsedMicroseconds;
    final perOpNs = (elapsedUs * 1000.0) / iterations;

    return BatchMeasurement(
      iterations: iterations,
      totalElapsedMicroseconds: elapsedUs,
      perOpNanoseconds: perOpNs,
    );
  }
}
