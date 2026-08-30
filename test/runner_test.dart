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
  @override
  void setup() {
    setupCalls++;
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
    Blackhole.consumeInt(x);
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
  });
}
