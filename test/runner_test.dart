import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

final class _CountingBenchmark(
  super.name, {
  super.config,
  final bool shouldThrowInRun = false,
}) extends Benchmark {
  int setupCalls = 0;
  int runCalls = 0;
  int teardownCalls = 0;
  int warmupCompleteCalls = 0;

  @override
  void setup() {
    setupCalls++;
  }

  @override
  void warmupComplete() {
    warmupCompleteCalls++;
  }

  @override
  void run() {
    runCalls++;
    if (shouldThrowInRun) {
      throw StateError('Simulated failure during benchmark run');
    }
    var x = 0;
    for (var i = 0; i < 50; i++) {
      x += i;
    }
    Blackhole.consume(x);
  }

  @override
  void teardown() {
    teardownCalls++;
  }
}

final class _AsyncCountingBenchmark(
  super.name, {
  super.config,
  final bool shouldThrowInRun = false,
}) extends AsyncBenchmark {
  int setupCalls = 0;
  int runCalls = 0;
  int teardownCalls = 0;
  @override
  Future<void> setup() async {
    setupCalls++;
  }

  @override
  Future<void> run() async {
    runCalls++;
    if (shouldThrowInRun) {
      throw StateError('Simulated async failure during benchmark run');
    }
    Blackhole.consume(runCalls);
  }

  @override
  Future<void> teardown() async {
    teardownCalls++;
  }
}

void main() {
  group('BenchmarkRunner & Lifecycle Orchestrator', () {
    test('executes synchronous benchmark lifecycle completely', () {
      const config = BenchmarkConfig(
        trials: 10,
        minWarmupIterations: 5,
        maxWarmupIterations: 20,
        targetBatchDuration: Duration(milliseconds: 5),
        forceRun: true,
      );

      final bench = _CountingBenchmark('sync_test', config: config);
      final result = BenchmarkRunner.run(bench);

      check(bench.setupCalls).equals(1);
      check(bench.teardownCalls).equals(1);
      check(bench.runCalls).isGreaterThan(10);

      check(result.name).equals('sync_test');
      check(result.rawTrialLatenciesNs.length).equals(10);
      check(result.metrics.meanNs).isGreaterThan(0.0);
      check(result.metrics.minNs).isGreaterThan(0.0);
      check(result.metrics.opsPerSec).isGreaterThan(0.0);
      check(result.calibratedBatch.iterations).isGreaterThan(0);
    });

    test('guarantees teardown executes even when sync run throws', () {
      const config = BenchmarkConfig(
        forceRun: true,
        targetBatchDuration: Duration(milliseconds: 1),
      );
      final bench = _CountingBenchmark(
        'failing_sync',
        config: config,
        shouldThrowInRun: true,
      );

      check(() => BenchmarkRunner.run(bench)).throws<StateError>();
      check(bench.setupCalls).equals(1);
      check(bench.teardownCalls).equals(1);
    });

    test('executes asynchronous benchmark lifecycle completely', () async {
      const config = BenchmarkConfig(
        trials: 5,
        minWarmupIterations: 5,
        maxWarmupIterations: 15,
        targetBatchDuration: Duration(milliseconds: 5),
        forceRun: true,
      );

      final bench = _AsyncCountingBenchmark('async_test', config: config);
      final result = await BenchmarkRunner.runAsync(bench);

      check(bench.setupCalls).equals(1);
      check(bench.teardownCalls).equals(1);
      check(bench.runCalls).isGreaterThan(5);

      check(result.name).equals('async_test');
      check(result.rawTrialLatenciesNs.length).equals(5);
      check(result.metrics.meanNs).isGreaterThan(0.0);
      check(result.metrics.opsPerSec).isGreaterThan(0.0);
    });

    test('guarantees teardown executes even when async run throws', () async {
      const config = BenchmarkConfig(
        forceRun: true,
        targetBatchDuration: Duration(milliseconds: 1),
      );
      final bench = _AsyncCountingBenchmark(
        'failing_async',
        config: config,
        shouldThrowInRun: true,
      );

      await check(BenchmarkRunner.runAsync(bench)).throws<StateError>();
      check(bench.setupCalls).equals(1);
      check(bench.teardownCalls).equals(1);
    });

    test('executes BenchmarkVariant lifecycle cleanly', () async {
      var setups = 0;
      var teardowns = 0;
      var executions = 0;

      final variant = BenchmarkVariant(
        'variant_test',
        () {
          executions++;
          Blackhole.consume(executions);
        },
        setup: () => setups++,
        teardown: () => teardowns++,
      );

      final result = await BenchmarkRunner.runVariant(
        variant,
        config: const BenchmarkConfig(
          trials: 5,
          minWarmupIterations: 5,
          maxWarmupIterations: 15,
          targetBatchDuration: Duration(milliseconds: 5),
          forceRun: true,
        ),
      );

      check(setups).equals(1);
      check(teardowns).equals(1);
      check(executions).isGreaterThan(5);
      check(result.name).equals('variant_test');
      check(result.rawTrialLatenciesNs.length).equals(5);
    });

    test('Benchmark.report() runs and returns BenchmarkResult', () {
      final bench = _CountingBenchmark(
        'report_test',
        config: const BenchmarkConfig(
          trials: 5,
          minWarmupIterations: 5,
          maxWarmupIterations: 15,
          targetBatchDuration: Duration(milliseconds: 5),
          forceRun: true,
        ),
      );

      final result = bench.report();
      check(result.name).equals('report_test');
      check(result.rawTrialLatenciesNs.length).equals(5);

      final json = result.toJson();
      check(json['name']).equals('report_test');
      check(json['samples']).equals(5);
      check(json['metrics']).isA<Map<String, Object?>>();
    });

    test('AsyncBenchmark.report() runs and returns BenchmarkResult', () async {
      final bench = _AsyncCountingBenchmark(
        'async_report_test',
        config: const BenchmarkConfig(
          trials: 5,
          minWarmupIterations: 5,
          maxWarmupIterations: 15,
          targetBatchDuration: Duration(milliseconds: 5),
          forceRun: true,
        ),
      );

      final result = await bench.report();
      check(result.name).equals('async_report_test');
      check(result.rawTrialLatenciesNs.length).equals(5);
    });

    test(
      'BenchmarkVariant.report() runs and returns BenchmarkResult',
      () async {
        final variant = BenchmarkVariant('variant_report', () {
          Blackhole.consume(123);
        });

        final result = await variant.report(
          config: const BenchmarkConfig(
            trials: 5,
            minWarmupIterations: 5,
            maxWarmupIterations: 15,
            targetBatchDuration: Duration(milliseconds: 5),
            forceRun: true,
          ),
        );

        check(result.name).equals('variant_report');
        check(result.rawTrialLatenciesNs.length).equals(5);
      },
    );

    test('adaptively scales trials up to maxTrials when variance is high', () {
      final logs = <String>[];
      final bench = _CountingBenchmark(
        'mock_spiking',
        config: BenchmarkConfig(
          trials: 5,
          maxTrials: 10,
          minWarmupIterations: 20,
          maxWarmupIterations: 20,
          targetBatchDuration: const Duration(milliseconds: 1),
          forceRun: true,
          logger: logs.add,
        ),
      );

      var trialCount = 0;
      final result = BenchmarkRunner.run(
        bench,
        runBatch: (b, iters) {
          if (bench.warmupCompleteCalls == 0) {
            return BatchMeasurement(
              iterations: iters,
              totalElapsedMicroseconds: (100.0 * iters / 1000.0).round(),
              perOpNanoseconds: 100.0,
            );
          }
          trialCount++;
          // First trial spikes to 200.0 ns to induce high initial variance.
          final perOpNs = (trialCount == 1) ? 200.0 : 100.0;
          return BatchMeasurement(
            iterations: iters,
            totalElapsedMicroseconds: (perOpNs * iters / 1000.0).round(),
            perOpNanoseconds: perOpNs,
          );
        },
      );

      check(result.warmupResult.isStable).isTrue();
      check(result.rawTrialLatenciesNs.length).equals(10);
      check(result.metrics.isStable).isTrue();
      check(result.metrics.isRobustStable).isTrue();
      check(logs.any((l) => l.contains('Adaptively scaling up to 10 trials')))
          .isTrue();
    });

    test(
      'does not scale trials beyond configured trials when variance is low',
      () {
        final logs = <String>[];
        final bench = _CountingBenchmark(
          'mock_non_spiking',
          config: BenchmarkConfig(
            trials: 5,
            maxTrials: 10,
            minWarmupIterations: 20,
            maxWarmupIterations: 20,
            targetBatchDuration: const Duration(milliseconds: 1),
            forceRun: true,
            logger: logs.add,
          ),
        );

        final result = BenchmarkRunner.run(
          bench,
          runBatch: (b, iters) => BatchMeasurement(
            iterations: iters,
            totalElapsedMicroseconds: (100.0 * iters / 1000.0).round(),
            perOpNanoseconds: 100.0,
          ),
        );

        check(result.warmupResult.isStable).isTrue();
        check(result.rawTrialLatenciesNs.length).equals(5);
        check(result.metrics.isStable).isTrue();
        check(logs.any((l) => l.contains('Adaptively scaling'))).isFalse();
      },
    );
  });

  group('BenchmarkRunner.shouldScaleTrials', () {
    test('returns false when maxTrials is null', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          200.0,
          100.0,
        ], const BenchmarkConfig(trials: 3)),
      ).isFalse();
    });

    test('returns false when maxTrials <= trials', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          200.0,
          100.0,
        ], const BenchmarkConfig(trials: 5, maxTrials: 5)),
      ).isFalse();
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          200.0,
          100.0,
        ], const BenchmarkConfig(trials: 5, maxTrials: 3)),
      ).isFalse();
    });

    test('returns false when trials.length >= maxTrials', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          200.0,
          100.0,
          200.0,
          100.0,
        ], const BenchmarkConfig(trials: 3, maxTrials: 5)),
      ).isFalse();
    });

    test('returns false when trials has fewer than 2 samples', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
        ], const BenchmarkConfig(trials: 1, maxTrials: 5)),
      ).isFalse();
    });

    test('returns false when variance is within stability threshold', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          101.0,
          99.0,
          100.5,
          99.5,
        ], const BenchmarkConfig(trials: 5, maxTrials: 10)),
      ).isFalse();
    });

    test('returns true when variance exceeds stability threshold', () {
      check(
        BenchmarkRunner.shouldScaleTrials([
          100.0,
          100.0,
          100.0,
          100.0,
          200.0,
        ], const BenchmarkConfig(trials: 5, maxTrials: 10)),
      ).isTrue();
    });
  });

  group('Change 3: Post-warmup recalibration', () {
    test('runSync and runAsync recalibrate after warmupComplete, report the '
        'post-warmup calibratedBatch, and log >10x swings', () async {
      final syncLogs = <String>[];
      final syncBench = _TieringSyncBenchmark(
        'tiered_sync',
        config: BenchmarkConfig(
          trials: 3,
          minWarmupIterations: 5,
          maxWarmupIterations: 5,
          targetBatchDuration: const Duration(milliseconds: 2),
          forceRun: true,
          logger: syncLogs.add,
        ),
      );

      var warmupObservedBatch = 0;
      var trialObservedBatch = 0;
      final syncResult = BenchmarkRunner.run(
        syncBench,
        runBatch: (b, iters) {
          if (!syncBench.isWarm) {
            warmupObservedBatch = iters;
          } else {
            trialObservedBatch = iters;
          }
          return BatchMeasurement(
            iterations: iters,
            totalElapsedMicroseconds: 100,
            perOpNanoseconds: 100.0,
          );
        },
      );

      check(syncBench.warmupCompleteCalled).isTrue();
      check(trialObservedBatch).isGreaterThan(warmupObservedBatch * 10);
      check(syncResult.calibratedBatch.iterations).equals(trialObservedBatch);
      check(
        syncLogs.any(
          (l) => l.contains(
            'Post-warmup recalibration changed batch size '
            '$warmupObservedBatch -> $trialObservedBatch',
          ),
        ),
      ).isTrue();

      final asyncLogs = <String>[];
      final asyncBench = _TieringAsyncBenchmark(
        'tiered_async',
        config: BenchmarkConfig(
          trials: 3,
          minWarmupIterations: 5,
          maxWarmupIterations: 5,
          targetBatchDuration: const Duration(milliseconds: 2),
          forceRun: true,
          logger: asyncLogs.add,
        ),
      );

      var asyncWarmupBatch = 0;
      var asyncTrialBatch = 0;
      final asyncResult = await BenchmarkRunner.runAsync(
        asyncBench,
        runBatch: (b, iters) async {
          if (!asyncBench.isWarm) {
            asyncWarmupBatch = iters;
          } else {
            asyncTrialBatch = iters;
          }
          return BatchMeasurement(
            iterations: iters,
            totalElapsedMicroseconds: 100,
            perOpNanoseconds: 100.0,
          );
        },
      );

      check(asyncBench.warmupCompleteCalled).isTrue();
      check(asyncTrialBatch).isGreaterThan(asyncWarmupBatch * 10);
      check(asyncResult.calibratedBatch.iterations).equals(asyncTrialBatch);
      check(
        asyncLogs.any(
          (l) => l.contains(
            'Post-warmup recalibration changed batch size '
            '$asyncWarmupBatch -> $asyncTrialBatch',
          ),
        ),
      ).isTrue();
    });
  });
}

final class _TieringSyncBenchmark(super.name, {super.config})
    extends Benchmark {
  bool isWarm = false;
  bool warmupCompleteCalled = false;

  @override
  void warmupComplete() {
    isWarm = true;
    warmupCompleteCalled = true;
  }

  @override
  void run() {
    if (!isWarm) {
      // Cold tier: ~1.5ms busy wait so provisional calibration picks batch = 1
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 1500) {}
    } else {
      // Warm tier: sub-microsecond work so post-warmup calibration picks > 100
      Blackhole.consume(42);
    }
  }
}

final class _TieringAsyncBenchmark(super.name, {super.config})
    extends AsyncBenchmark {
  bool isWarm = false;
  bool warmupCompleteCalled = false;

  @override
  Future<void> warmupComplete() async {
    isWarm = true;
    warmupCompleteCalled = true;
  }

  @override
  Future<void> run() async {
    if (!isWarm) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 1500) {}
    } else {
      Blackhole.consume(42);
    }
  }
}
