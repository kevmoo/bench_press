import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

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
      if (warmupResult.estimatedOpNanoseconds.isFinite)
        'estimated_op_ns': warmupResult.estimatedOpNanoseconds,
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
  static BenchmarkResult run(
    Benchmark benchmark, {
    @visibleForTesting
    BatchMeasurement Function(Benchmark benchmark, int iterations)? runBatch,
  }) {
    benchmark.setup();
    try {
      final config = benchmark.config;
      final provisional = BenchmarkCalibrator.calibrateSync(
        benchmark.run,
        config,
      );

      final warmupDetector = AdaptiveWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final measurement = (runBatch ?? BatchRunner.runSync)(
          benchmark,
          provisional.iterations,
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
      benchmark.warmupComplete();

      final calibrated =
          BenchmarkCalibrator.calibratedBatchFromWarmup(warmupResult, config) ??
          BenchmarkCalibrator.calibrateSync(benchmark.run, config);
      _logRecalibrationSwing(provisional, calibrated, config);

      final trials = <double>[];
      for (var i = 0; i < config.trials; i++) {
        final measurement = (runBatch ?? BatchRunner.runSync)(
          benchmark,
          calibrated.iterations,
        );
        trials.add(measurement.perOpNanoseconds);
      }

      if (_shouldScaleTrials(trials, config)) {
        config.logger?.call(
          'High variance detected in initial trials. '
          'Adaptively scaling up to ${config.maxTrials} trials.',
        );
        while (_shouldScaleTrials(trials, config)) {
          final measurement = (runBatch ?? BatchRunner.runSync)(
            benchmark,
            calibrated.iterations,
          );
          trials.add(measurement.perOpNanoseconds);
        }
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
  static Future<BenchmarkResult> runAsync(
    AsyncBenchmark benchmark, {
    @visibleForTesting
    Future<BatchMeasurement> Function(AsyncBenchmark benchmark, int iterations)?
    runBatch,
  }) async {
    await benchmark.setup();
    try {
      final config = benchmark.config;
      final provisional = await BenchmarkCalibrator.calibrateAsync(
        benchmark.run,
        config,
      );

      final warmupDetector = AdaptiveWarmupDetector(config: config);
      final warmupStopwatch = Stopwatch()..start();

      while (true) {
        final measurement = await (runBatch ?? BatchRunner.runAsync)(
          benchmark,
          provisional.iterations,
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
      await benchmark.warmupComplete();

      final calibrated =
          BenchmarkCalibrator.calibratedBatchFromWarmup(warmupResult, config) ??
          await BenchmarkCalibrator.calibrateAsync(benchmark.run, config);
      _logRecalibrationSwing(provisional, calibrated, config);

      final trials = <double>[];
      for (var i = 0; i < config.trials; i++) {
        final measurement = await (runBatch ?? BatchRunner.runAsync)(
          benchmark,
          calibrated.iterations,
        );
        trials.add(measurement.perOpNanoseconds);
      }

      if (_shouldScaleTrials(trials, config)) {
        config.logger?.call(
          'High variance detected in initial trials. '
          'Adaptively scaling up to ${config.maxTrials} trials.',
        );
        while (_shouldScaleTrials(trials, config)) {
          final measurement = await (runBatch ?? BatchRunner.runAsync)(
            benchmark,
            calibrated.iterations,
          );
          trials.add(measurement.perOpNanoseconds);
        }
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
  }) async => (await runVariants([variant], config: config)).single;

  /// Runs [variants] together: each variant completes `setup`, warmup,
  /// `warmupComplete`, and batch calibration first, then measurement trials
  /// execute in `ABBA BAAB` interleaved visits across all variants so linear
  /// and quadratic host drift cancel across the group. Each visit records a
  /// block of trials per variant (sized for four visits), and each switch
  /// between variants runs two discarded batches first, so no measured trial
  /// is among the first to execute after a different variant.
  ///
  /// When [BenchmarkConfig.maxTrials] is set, lockstep rounds continue across
  /// all variants while any variant's CV exceeds the stability threshold.
  static Future<List<BenchmarkResult>> runVariants(
    List<BenchmarkVariant> variants, {
    BenchmarkConfig config = const BenchmarkConfig(),
  }) async {
    if (variants.isEmpty) return <BenchmarkResult>[];

    final initialized = <BenchmarkVariant>[];
    try {
      final prepared = <_PreparedVariant>[];
      for (final variant in variants) {
        variant.setup?.call();
        initialized.add(variant);
        prepared.add(await _prepareVariant(variant, config));
      }

      await _collectInterleavedTrials(prepared, config);

      return [for (final item in prepared) _buildVariantResult(item, config)];
    } finally {
      _teardownVariants(initialized);
    }
  }

  static Future<_PreparedVariant> _prepareVariant(
    BenchmarkVariant variant,
    BenchmarkConfig config,
  ) async {
    final probe = variant.action();
    final isAsync = probe is Future;
    if (isAsync) {
      await probe;
    }
    final provisional = isAsync
        ? await BenchmarkCalibrator.calibrateAsync(variant.executeAsync, config)
        : BenchmarkCalibrator.calibrateSync(variant.executeSync, config);

    final warmupResult = await _warmupVariant(
      variant,
      provisional.iterations,
      config,
      isAsync: isAsync,
    );
    variant.warmupComplete?.call();

    final calibrated =
        BenchmarkCalibrator.calibratedBatchFromWarmup(warmupResult, config) ??
        (isAsync
            ? await BenchmarkCalibrator.calibrateAsync(
                variant.executeAsync,
                config,
              )
            : BenchmarkCalibrator.calibrateSync(variant.executeSync, config));
    _logRecalibrationSwing(provisional, calibrated, config);

    return (
      variant: variant,
      isAsync: isAsync,
      warmupResult: warmupResult,
      calibrated: calibrated,
      trials: <double>[],
    );
  }

  static Future<WarmupResult> _warmupVariant(
    BenchmarkVariant variant,
    int iterations,
    BenchmarkConfig config, {
    required bool isAsync,
  }) async {
    final warmupDetector = AdaptiveWarmupDetector(config: config);
    final warmupStopwatch = Stopwatch()..start();

    while (true) {
      final perOpNs = await _measureVariantBatch(
        variant,
        iterations,
        isAsync: isAsync,
      );
      warmupDetector.addSample(perOpNs);

      final elapsedSec = warmupStopwatch.elapsedMicroseconds / 1000000.0;
      if (warmupDetector.isDone(elapsedSeconds: elapsedSec)) {
        break;
      }
    }
    warmupStopwatch.stop();

    return warmupDetector.finish(
      elapsedSeconds: warmupStopwatch.elapsedMicroseconds / 1000000.0,
    );
  }

  /// Batches run and discarded whenever the measured variant changes.
  ///
  /// The first batches after a switch carry state left by the previous
  /// variant. On Wasm the penalty decays over roughly two ~100 ms batches and,
  /// with every trial a switch, doubled per-cell `robust_cv`; a single discard
  /// recovered only half of that. Two discards bring interleaved runs back to
  /// the spread sequential execution gives.
  static const int _discardsOnSwitch = 2;

  static Future<void> _collectInterleavedTrials(
    List<_PreparedVariant> prepared,
    BenchmarkConfig config,
  ) async {
    // Measured trials per variant per visit. The `ABBA BAAB` visit schedule
    // cancels linear and quadratic drift over four visits, so blocks are sized
    // to give exactly four visits across [BenchmarkConfig.trials].
    final block = math.max(1, (config.trials / 4).ceil());
    var visit = 0;
    _PreparedVariant? last;
    while (prepared.any((p) => p.trials.length < config.trials)) {
      last = await _runInterleavedVisit(
        prepared,
        visit++,
        block: block,
        target: config.trials,
        last: last,
      );
    }
    if (_anyShouldScale(prepared, config)) {
      config.logger?.call(
        'High variance detected in initial trials. '
        'Adaptively scaling up to ${config.maxTrials} trials.',
      );
      while (_anyShouldScale(prepared, config)) {
        last = await _runInterleavedVisit(
          prepared,
          visit++,
          block: block,
          target: config.maxTrials!,
          last: last,
        );
      }
    }
  }

  /// Executes one visit across [prepared], reversing traversal order when
  /// `(visit & 1) != ((visit >> 1) & 1)` (`AB`, `BA`, `BA`, `AB`, ...).
  ///
  /// Each variant records up to [block] trials, never exceeding [target].
  /// [last] is the variant measured most recently (null before the first
  /// visit); whenever the variant changes, [_discardsOnSwitch] batches run and
  /// are thrown away before the measured ones. Returns the variant measured
  /// last in this visit.
  static Future<_PreparedVariant?> _runInterleavedVisit(
    List<_PreparedVariant> prepared,
    int visit, {
    required int block,
    required int target,
    required _PreparedVariant? last,
  }) async {
    final reverse = (visit & 1) != ((visit >> 1) & 1);
    final count = prepared.length;
    for (var i = 0; i < count; i++) {
      final item = prepared[reverse ? count - 1 - i : i];
      final remaining = math.min(block, target - item.trials.length);
      if (remaining <= 0) continue;
      if (!identical(item, last)) {
        for (var d = 0; d < _discardsOnSwitch; d++) {
          await _measureVariantBatch(
            item.variant,
            item.calibrated.iterations,
            isAsync: item.isAsync,
          );
        }
      }
      for (var k = 0; k < remaining; k++) {
        item.trials.add(
          await _measureVariantBatch(
            item.variant,
            item.calibrated.iterations,
            isAsync: item.isAsync,
          ),
        );
      }
      last = item;
    }
    return last;
  }

  static bool _anyShouldScale(
    List<_PreparedVariant> prepared,
    BenchmarkConfig config,
  ) => prepared.any((p) => _shouldScaleTrials(p.trials, config));

  static BenchmarkResult _buildVariantResult(
    _PreparedVariant item,
    BenchmarkConfig config,
  ) {
    final metrics = BenchmarkMetrics.fromSamples(
      item.trials,
      isStable: item.warmupResult.isStable,
    );
    return BenchmarkResult(
      name: item.variant.name,
      mode: item.isAsync ? 'async' : 'sync',
      metrics: metrics,
      warmupResult: item.warmupResult,
      rawTrialLatenciesNs: item.trials,
      calibratedBatch: item.calibrated,
      config: config,
      group: item.variant.group,
      isBaseline: item.variant.isBaseline,
      throughput: item.variant.throughput,
    );
  }

  static void _teardownVariants(List<BenchmarkVariant> initialized) {
    Object? firstError;
    StackTrace? firstStack;
    for (final variant in initialized) {
      try {
        variant.teardown?.call();
      } on Object catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  static void _logRecalibrationSwing(
    CalibratedBatch provisional,
    CalibratedBatch calibrated,
    BenchmarkConfig config,
  ) {
    final provIter = provisional.iterations;
    final calIter = calibrated.iterations;
    if (provIter <= 0 || calIter <= 0) return;
    final ratio = math.max(provIter, calIter) / math.min(provIter, calIter);
    if (ratio > 10.0) {
      config.logger?.call(
        'Post-warmup recalibration changed batch size $provIter -> $calIter '
        '(${ratio.toStringAsFixed(1)}x). Cold-probe estimate was unreliable; '
        'using post-warmup value.',
      );
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

  /// Whether trial collection should continue scaling up to
  /// [BenchmarkConfig.maxTrials].
  @visibleForTesting
  static bool shouldScaleTrials(List<double> trials, BenchmarkConfig config) =>
      _shouldScaleTrials(trials, config);

  static bool _shouldScaleTrials(List<double> trials, BenchmarkConfig config) {
    final maxTrials = config.maxTrials;
    if (maxTrials == null || maxTrials <= config.trials) {
      return false;
    }
    if (trials.length >= maxTrials) {
      return false;
    }
    if (trials.length < 2) {
      return false;
    }
    final metrics = BenchmarkMetrics.fromSamples(trials);
    // Scale if standard CV exceeds the stability threshold (e.g. CV > 5%),
    // indicating high variance or transient bimodal outliers (such as GC
    // pauses).
    return metrics.cv > BenchmarkMetrics.maxCvThreshold;
  }
}

typedef _PreparedVariant = ({
  BenchmarkVariant variant,
  bool isAsync,
  WarmupResult warmupResult,
  CalibratedBatch calibrated,
  List<double> trials,
});
