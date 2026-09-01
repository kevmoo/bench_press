import 'dart:async';

import 'batch_runner.dart';
import 'blackhole.dart';
import 'calibration.dart';
import 'config.dart';
import 'harness.dart';
import 'stats/metrics.dart';
import 'stats/warmup.dart';
import 'throughput.dart';

/// The comprehensive result of executing a benchmark through its full
/// lifecycle.
final class const BenchmarkResult({
  /// The unique identifier or name of the benchmark.
  required final String name,

  /// Statistical summary metrics computed from the measurement trials.
  required final BenchmarkMetrics metrics,

  /// Diagnostic metadata from the warmup phase.
  required final WarmupResult warmupResult,

  /// The raw per-operation latencies (in nanoseconds) recorded for each trial.
  required final List<double> rawTrialLatenciesNs,

  /// The calibrated batch parameters used for inner loop timing.
  required final CalibratedBatch calibratedBatch,

  /// The configuration options applied during execution.
  required final BenchmarkConfig config,

  /// Optional group identifier for intra-run variant comparisons.
  final String? group,

  /// Whether this variant was designated as the baseline for its group.
  final bool isBaseline = false,

  /// Declared throughput processed per invocation (bytes or element count).
  final Throughput? throughput,

  /// The execution mode ('sync' or 'async').
  final String mode = 'sync',
}) {
  /// Converts the benchmark result to a canonical JSON representation.
  Map<String, Object?> toJson() => {
    'name': name,
    'mode': mode,
    'metrics': metrics.toJson(),
    if (group != null) 'group': group,
    if (isBaseline) 'is_baseline': isBaseline,
    if (throughput != null) 'throughput': throughput!.toJson(),
    'warmup': {
      'is_stable': warmupResult.isStable,
      'total_iterations': warmupResult.totalWarmupIterations,
      'converged_at': warmupResult.convergedAtIteration,
      'best_mmd': warmupResult.bestMmd,
      'elapsed_seconds': warmupResult.elapsedSeconds,
    },
    'samples': rawTrialLatenciesNs.length,
    'raw_trials_ns': rawTrialLatenciesNs,
    'calibrated_batch_iterations': calibratedBatch.iterations,
  };

  @override
  String toString() =>
      'BenchmarkResult($name: ${metrics.meanNs.toStringAsFixed(1)} ns/op, '
      '${metrics.opsPerSec.toStringAsFixed(0)} ops/s, '
      'trials: ${rawTrialLatenciesNs.length}, '
      'stable: ${metrics.isStable})';
}

/// Orchestrates the end-to-end benchmark lifecycle: setup -> calibration ->
/// warmup -> measurement trials -> summary metrics calculation -> teardown.
abstract final class BenchmarkRunner() {
  /// Runs a synchronous [Benchmark] through its full lifecycle.
  static BenchmarkResult run(Benchmark benchmark) {
    benchmark.setup();
    try {
      final config = benchmark.config;
      final calibrated = BenchmarkCalibrator.calibrateSync(
        benchmark.run,
        config,
      );

      final warmupDetector = AdaptiveWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final measurement = BatchRunner.runSync(
          benchmark,
          calibrated.iterations,
        );
        warmupDetector.addSample(measurement.perOpNanoseconds);

        final elapsedSec = warmupStopwatch.elapsedMicroseconds / 1000000.0;
        if (warmupDetector.isDone(elapsedSeconds: elapsedSec)) {
          break;
        }
      }
      warmupStopwatch.stop();

      final warmupResult = warmupDetector.finish(
        elapsedSeconds: warmupStopwatch.elapsedMicroseconds / 1000000.0,
      );

      final trials = <double>[];
      for (var i = 0; i < config.trials; i++) {
        final measurement = BatchRunner.runSync(
          benchmark,
          calibrated.iterations,
        );
        trials.add(measurement.perOpNanoseconds);
      }

      final metrics = BenchmarkMetrics.fromSamples(
        trials,
        isStable: warmupResult.isStable,
      );

      return BenchmarkResult(
        name: benchmark.name,
        metrics: metrics,
        warmupResult: warmupResult,
        rawTrialLatenciesNs: trials,
        calibratedBatch: calibrated,
        config: config,
        group: benchmark.group,
        isBaseline: benchmark.isBaseline,
        throughput: benchmark.throughput,
      );
    } finally {
      benchmark.teardown();
    }
  }

  /// Runs an asynchronous [AsyncBenchmark] through its full lifecycle.
  static Future<BenchmarkResult> runAsync(AsyncBenchmark benchmark) async {
    await benchmark.setup();
    try {
      final config = benchmark.config;
      final calibrated = await BenchmarkCalibrator.calibrateAsync(
        benchmark.run,
        config,
      );

      final warmupDetector = AdaptiveWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final measurement = await BatchRunner.runAsync(
          benchmark,
          calibrated.iterations,
        );
        warmupDetector.addSample(measurement.perOpNanoseconds);

        final elapsedSec = warmupStopwatch.elapsedMicroseconds / 1000000.0;
        if (warmupDetector.isDone(elapsedSeconds: elapsedSec)) {
          break;
        }
      }
      warmupStopwatch.stop();

      final warmupResult = warmupDetector.finish(
        elapsedSeconds: warmupStopwatch.elapsedMicroseconds / 1000000.0,
      );

      final trials = <double>[];
      for (var i = 0; i < config.trials; i++) {
        final measurement = await BatchRunner.runAsync(
          benchmark,
          calibrated.iterations,
        );
        trials.add(measurement.perOpNanoseconds);
      }

      final metrics = BenchmarkMetrics.fromSamples(
        trials,
        isStable: warmupResult.isStable,
      );

      return BenchmarkResult(
        name: benchmark.name,
        mode: 'async',
        metrics: metrics,
        warmupResult: warmupResult,
        rawTrialLatenciesNs: trials,
        calibratedBatch: calibrated,
        config: config,
        group: benchmark.group,
        isBaseline: benchmark.isBaseline,
        throughput: benchmark.throughput,
      );
    } finally {
      await benchmark.teardown();
    }
  }

  /// Runs a [BenchmarkVariant] through its full lifecycle.
  static Future<BenchmarkResult> runVariant(
    BenchmarkVariant variant, {
    BenchmarkConfig config = const BenchmarkConfig(),
  }) async {
    variant.setup?.call();
    try {
      final probe = variant.action();
      final isAsync = probe is Future;
      if (isAsync) {
        await probe;
      }
      final calibrated = isAsync
          ? await BenchmarkCalibrator.calibrateAsync(
              variant.executeAsync,
              config,
            )
          : BenchmarkCalibrator.calibrateSync(variant.executeSync, config);

      final warmupDetector = AdaptiveWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final perOpNs = await _measureVariantBatch(
          variant,
          calibrated.iterations,
          isAsync: isAsync,
        );
        warmupDetector.addSample(perOpNs);

        final elapsedSec = warmupStopwatch.elapsedMicroseconds / 1000000.0;
        if (warmupDetector.isDone(elapsedSeconds: elapsedSec)) {
          break;
        }
      }
      warmupStopwatch.stop();

      final warmupResult = warmupDetector.finish(
        elapsedSeconds: warmupStopwatch.elapsedMicroseconds / 1000000.0,
      );

      final trials = <double>[];
      for (var i = 0; i < config.trials; i++) {
        final perOpNs = await _measureVariantBatch(
          variant,
          calibrated.iterations,
          isAsync: isAsync,
        );
        trials.add(perOpNs);
      }

      final metrics = BenchmarkMetrics.fromSamples(
        trials,
        isStable: warmupResult.isStable,
      );

      return BenchmarkResult(
        name: variant.name,
        mode: isAsync ? 'async' : 'sync',
        metrics: metrics,
        warmupResult: warmupResult,
        rawTrialLatenciesNs: trials,
        calibratedBatch: calibrated,
        config: config,
        group: variant.group,
        isBaseline: variant.isBaseline,
        throughput: variant.throughput,
      );
    } finally {
      variant.teardown?.call();
    }
  }

  static Future<double> _measureVariantBatch(
    BenchmarkVariant variant,
    int iterations, {
    required bool isAsync,
  }) async {
    if (!isAsync) {
      final measurement = BatchRunner.runVariantSync(variant, iterations);
      return measurement.perOpNanoseconds;
    }
    final batchStopwatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      await variant.executeAsync();
    }
    batchStopwatch.stop();
    Blackhole.drain();
    final elapsedUs = batchStopwatch.elapsedMicroseconds;
    return (elapsedUs * 1000.0) / iterations;
  }
}
