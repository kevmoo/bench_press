import 'dart:async';

import 'batch_runner.dart';
import 'blackhole.dart';
import 'calibration.dart';
import 'config.dart';
import 'harness.dart';
import 'stats/kbssd.dart';
import 'stats/metrics.dart';

/// The comprehensive result of executing a benchmark through its full
/// lifecycle.
final class BenchmarkResult {
  /// The unique identifier or name of the benchmark.
  final String name;

  /// Statistical summary metrics computed from the measurement trials.
  final BenchmarkMetrics metrics;

  /// Diagnostic metadata from the warmup phase.
  final WarmupResult warmupResult;

  /// The raw per-operation latencies (in nanoseconds) recorded for each trial.
  final List<double> rawTrialLatenciesNs;

  /// The calibrated batch parameters used for inner loop timing.
  final CalibratedBatch calibratedBatch;

  /// The configuration options applied during execution.
  final BenchmarkConfig config;

  const BenchmarkResult({
    required this.name,
    required this.metrics,
    required this.warmupResult,
    required this.rawTrialLatenciesNs,
    required this.calibratedBatch,
    required this.config,
  });

  /// Converts the benchmark result to a canonical JSON representation.
  Map<String, Object?> toJson() => {
    'name': name,
    'metrics': metrics.toJson(),
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
abstract final class BenchmarkRunner {
  /// Runs a synchronous [Benchmark] through its full lifecycle.
  static BenchmarkResult run(Benchmark benchmark) {
    benchmark.setup();
    try {
      final config = benchmark.config;
      final calibrated = BenchmarkCalibrator.calibrateSync(
        benchmark.run,
        config,
      );

      final warmupDetector = KbssdWarmupDetector(config: config);
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

      final warmupDetector = KbssdWarmupDetector(config: config);
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
        metrics: metrics,
        warmupResult: warmupResult,
        rawTrialLatenciesNs: trials,
        calibratedBatch: calibrated,
        config: config,
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
      final calibrated = await BenchmarkCalibrator.calibrateAsync(
        variant.executeAsync,
        config,
      );

      final warmupDetector = KbssdWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final batchStopwatch = Stopwatch()..start();
        for (var i = 0; i < calibrated.iterations; i++) {
          await variant.executeAsync();
        }
        batchStopwatch.stop();
        Blackhole.drain();

        final elapsedUs = batchStopwatch.elapsedMicroseconds;
        final perOpNs = (elapsedUs * 1000.0) / calibrated.iterations;
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
        final batchStopwatch = Stopwatch()..start();
        for (var j = 0; j < calibrated.iterations; j++) {
          await variant.executeAsync();
        }
        batchStopwatch.stop();
        Blackhole.drain();

        final elapsedUs = batchStopwatch.elapsedMicroseconds;
        final perOpNs = (elapsedUs * 1000.0) / calibrated.iterations;
        trials.add(perOpNs);
      }

      final metrics = BenchmarkMetrics.fromSamples(
        trials,
        isStable: warmupResult.isStable,
      );

      return BenchmarkResult(
        name: variant.name,
        metrics: metrics,
        warmupResult: warmupResult,
        rawTrialLatenciesNs: trials,
        calibratedBatch: calibrated,
        config: config,
      );
    } finally {
      variant.teardown?.call();
    }
  }
}
