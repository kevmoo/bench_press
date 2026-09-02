import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/cli/suite_runner.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

final class _SampleBench() extends Benchmark {
  this : super('sample_sync');

  @override
  void run() {
    var sum = 0;
    for (var i = 0; i < 20; i++) {
      sum += i;
    }
    Blackhole.consumeInt(sum);
  }
}

final class _SampleAsyncBench() extends AsyncBenchmark {
  this : super('sample_async');

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
        final tempDir = Directory.systemTemp.createTempSync('suite_test_');
        try {
          final outputFile = File(p.join(tempDir.path, 'output.json'));

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('mainBenchmark and mainAsyncBenchmark handle validate flag', () async {
      final tempDir = Directory.systemTemp.createTempSync('validate_flag_');
      try {
        final outputFile = File(p.join(tempDir.path, 'val_out.json'));
        final args = ['--validate', '--json-output', outputFile.path];

        mainBenchmark(_SampleBench(), args);
        check(outputFile.existsSync()).isTrue();
        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.first.samples).equals(1);

        await mainAsyncBenchmark(_SampleAsyncBench(), args);
        final asyncSuite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(asyncSuite.benchmarks.first.samples).equals(1);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'mainBenchmarkSuite executes single top-level BenchmarkGroup directly',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'suite_group_test_',
        );
        try {
          final outputFile = File(p.join(tempDir.path, 'group_output.json'));

          final args = [
            '--json-output',
            outputFile.path,
            '--validate',
            '--target',
            'jit',
          ];

          final group = BenchmarkGroup('test_group', [
            BenchmarkVariant('g_var1', () => Blackhole.consume(1)),
            BenchmarkVariant('g_var2', () => Blackhole.consume(2)),
          ]);

          await mainBenchmarkSuite(group, args);

          check(outputFile.existsSync()).isTrue();
          final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
          check(suite.benchmarks.length).equals(2);
          check(suite.findEntry('g_var1', 'jit')).isNotNull();
          check(suite.findEntry('g_var2', 'jit')).isNotNull();
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

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
