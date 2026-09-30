import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/cli/suite_runner.dart';
import 'package:bench_press/src/telemetry/schema.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

final class _SampleBench({
  super.config,
  final Throughput? declaredThroughput,
  final void Function()? onWarmupComplete,
}) extends Benchmark {
  this : super('sample_sync');

  @override
  Throughput? get throughput => declaredThroughput;

  @override
  void warmupComplete() => onWarmupComplete?.call();

  @override
  void run() {
    var sum = 0;
    for (var i = 0; i < 20; i++) {
      sum += i;
    }
    Blackhole.consume(sum);
  }
}

final class _SampleAsyncBench({
  super.config,
  final Throughput? declaredThroughput,
  final void Function()? onWarmupComplete,
}) extends AsyncBenchmark {
  this : super('sample_async');

  @override
  Throughput? get throughput => declaredThroughput;

  @override
  Future<void> warmupComplete() async => onWarmupComplete?.call();

  @override
  Future<void> run() async {
    Blackhole.consume(42);
  }
}

void main() {
  group('Suite Runner & JSON Streaming Markers', () {
    test('wrapJsonInMarkers and extractJsonFromStdout round-trip cleanly', () {
      const originalJson = '{\n  "version": 1\n}';
      final wrapped = wrapJsonInMarkers(originalJson);

      check(wrapped).contains(benchPressJsonStartMarker);
      check(wrapped).contains(benchPressJsonEndMarker);

      final extracted = extractJsonFromStdout(
        'Some logs...\n$wrapped\nMore logs...',
      );
      check(extracted).equals(originalJson);

      final notFound = extractJsonFromStdout('Random output without markers');
      check(notFound).isNull();
    });

    test(
      'mainBenchmarkSuite executes benchmarks and writes json output',
      () async {
        final outputFile = File(d.path('output.json'));

        final args = [
          '--json-output',
          outputFile.path,
          '--trials',
          '2',
          '--min-warmup',
          '2',
          '--max-warmup',
          '5',
          '--target-batch-ms',
          '1',
          '--force-run',
          '--target',
          'jit',
        ];

        await mainBenchmarkSuite([
          _SampleBench(),
          _SampleAsyncBench(),
          BenchmarkVariant('variant_sync', () => Blackhole.consume(1)),
        ], args);

        check(outputFile.existsSync()).isTrue();
        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.length).equals(3);
        check(suite.findEntry('sample_sync', 'jit')).isNotNull();
        check(suite.findEntry('sample_async', 'jit')).isNotNull();
        check(suite.findEntry('variant_sync', 'jit')).isNotNull();
      },
    );

    test('mainBenchmarkSuite delegates throughput and warmupComplete for '
        'wrapped Benchmark and AsyncBenchmark instances', () async {
      final outputFile = File(d.path('delegation_out.json'));
      var syncWarmupCompleteCalls = 0;
      var asyncWarmupCompleteCalls = 0;

      await mainBenchmarkSuite(
        [
          _SampleBench(
            declaredThroughput: const ByteThroughput(1024),
            onWarmupComplete: () => syncWarmupCompleteCalls++,
          ),
          _SampleAsyncBench(
            declaredThroughput: const ElementThroughput(64),
            onWarmupComplete: () => asyncWarmupCompleteCalls++,
          ),
        ],
        [
          '--json-output',
          outputFile.path,
          '--trials',
          '2',
          '--min-warmup',
          '1',
          '--max-warmup',
          '2',
          '--target-batch-ms',
          '1',
          '--force-run',
        ],
      );

      check(syncWarmupCompleteCalls).equals(1);
      check(asyncWarmupCompleteCalls).equals(1);

      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      final syncEntry = suite.findEntry('sample_sync', 'jit')!;
      final asyncEntry = suite.findEntry('sample_async', 'jit')!;
      check(syncEntry.throughput).equals(const ByteThroughput(1024));
      check(asyncEntry.throughput).equals(const ElementThroughput(64));
    });

    test('mainBenchmarkSuite preserves programmatic BenchmarkConfig unless '
        'explicitly overridden by CLI flags', () async {
      final outputFile = File(d.path('programmatic_config.json'));
      const programmaticConfig = BenchmarkConfig(
        trials: 2,
        minWarmupIterations: 1,
        maxWarmupIterations: 2,
        targetBatchDuration: Duration(milliseconds: 1),
        forceRun: true,
      );

      final group = BenchmarkGroup('cfg_group', [
        BenchmarkVariant('grp_var', () => Blackhole.consume(1)),
      ], config: programmaticConfig);
      final matrix = Benchmark.matrix<int>(
        cases: [1],
        name: (c) => 'cfg_matrix_$c',
        baseline: const ('mat_base', Blackhole.consume),
        candidates: {'mat_cand': (c) => Blackhole.consume(c + 1)},
        config: programmaticConfig,
      );

      // Pass only --json-output (no --trials, --force-run, etc.): all items
      // must honor their programmatic config (trials: 2, forceRun: true).
      await mainBenchmarkSuite(
        [
          _SampleBench(config: programmaticConfig),
          _SampleAsyncBench(config: programmaticConfig),
          group,
          matrix,
        ],
        ['--json-output', outputFile.path],
      );

      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(suite.benchmarks.length).equals(5);
      for (final entry in suite.benchmarks) {
        check(entry.samples).equals(2);
      }

      // Now pass --trials 3 without --force-run: trials is overridden to 3
      // while programmatic forceRun/minWarmup/targetBatchDuration remain.
      final overrideFile = File(d.path('override_config.json'));
      await mainBenchmarkGroup(group, [
        '--json-output',
        overrideFile.path,
        '--trials',
        '3',
      ]);
      final overrideSuite = BenchmarkSuiteResult.loadFromFile(overrideFile);
      check(overrideSuite.benchmarks.single.samples).equals(3);
    });

    test('mainBenchmark and mainAsyncBenchmark handle validate flag', () async {
      final outputFile = File(d.path('val_out.json'));
      final args = ['--validate', '--json-output', outputFile.path];

      mainBenchmark(_SampleBench(), args);
      check(outputFile.existsSync()).isTrue();
      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(suite.benchmarks.first.samples).equals(1);

      await mainAsyncBenchmark(_SampleAsyncBench(), args);
      final asyncSuite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(asyncSuite.benchmarks.first.samples).equals(1);
    });

    test('mainBenchmarkSuite executes single top-level BenchmarkGroup directly '
        'and warms up all variants before trials', () async {
      final outputFile = File(d.path('group_output.json'));
      final events = <String>[];
      var v1InTrials = false;
      var v2InTrials = false;

      final args = [
        '--json-output',
        outputFile.path,
        '--validate',
        '--target',
        'jit',
      ];

      final group = BenchmarkGroup('test_group', [
        BenchmarkVariant(
          'g_var1',
          () {
            if (v1InTrials) events.add('trial:g_var1');
            Blackhole.consume(1);
          },
          warmupComplete: () {
            events.add('warm:g_var1');
            v1InTrials = true;
          },
        ),
        BenchmarkVariant(
          'g_var2',
          () {
            if (v2InTrials) events.add('trial:g_var2');
            Blackhole.consume(2);
          },
          warmupComplete: () {
            events.add('warm:g_var2');
            v2InTrials = true;
          },
        ),
      ]);

      await mainBenchmarkSuite(group, args);

      check(outputFile.existsSync()).isTrue();
      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(suite.benchmarks.length).equals(2);
      check(suite.findEntry('g_var1', 'jit')).isNotNull();
      check(suite.findEntry('g_var2', 'jit')).isNotNull();
      // Both variants complete warmup before either variant runs a trial.
      check(events.indexOf('warm:g_var2'))
          .isLessThan(events.indexOf('trial:g_var1'));
    });

    test('mainBenchmarkSuite throws descriptive ArgumentError on null argument '
        'or null elements', () async {
      await check(mainBenchmarkSuite([null], [])).throws<ArgumentError>();

      check(() => validateBenchmarks([null]))
          .throws<ArgumentError>()
          .has((e) => e.message, 'message')
          .equals('Benchmark suite list cannot contain null elements.');

      check(() => validateBenchmarks(null))
          .throws<ArgumentError>()
          .has((e) => e.message, 'message')
          .equals('Benchmark suite argument cannot be null.');
    });
  });
}
