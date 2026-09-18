import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('RunCommand', () {
    test(
      'run subcommand executes benchmarks and saves json telemetry',
      () async {
        final benchFile = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'calc_bench.dart',
          className: 'CalcBenchmark',
          name: 'calc_workload',
          body: '''
    var x = 0;
    for (var i = 0; i < 10; i++) {
      x += i;
    }
    Blackhole.consume(x);''',
        );

        final outputFile = File(d.path('results.json'));
        final runner = BenchPressCommandRunner();

        final exitCode = await runner.run([
          'run',
          '-t',
          'jit',
          '--trials',
          '2',
          '--force-run',
          '-o',
          outputFile.path,
          benchFile.path,
        ]);

        check(exitCode).equals(0);
        check(outputFile.existsSync()).isTrue();

        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.length).equals(1);
        check(suite.benchmarks.first.name).equals('calc_workload');
        check(suite.benchmarks.first.target).equals('jit');
      },
    );

    test('run subcommand executes BenchmarkGroup and records groups', () async {
      await d.file('group_bench.dart', '''
import 'package:bench_press/bench_press.dart';

final BenchmarkGroup stringGroup = BenchmarkGroup('String Group', [
  BenchmarkVariant('concat', () => Blackhole.consume(1), isBaseline: true),
  BenchmarkVariant('buffer', () => Blackhole.consume(2)),
]);

final List<Object> benchmarks = [stringGroup];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
''').create();

      final outputFile = File(d.path('group_results.json'));
      final runner = BenchPressCommandRunner();

      final exitCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '2',
        '--force-run',
        '--save',
        outputFile.path,
        d.path('group_bench.dart'),
      ]);

      check(exitCode).equals(0);
      check(outputFile.existsSync()).isTrue();

      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(suite.benchmarks.length).equals(2);
      check(suite.groups).contains('String Group');

      final concat = suite.findEntry('concat', 'jit');
      check(concat).isNotNull();
      check(concat!.isBaseline).isTrue();
      check(concat.coordinates['group']).equals('String Group');

      final buffer = suite.findEntry('buffer', 'jit');
      check(buffer).isNotNull();
      check(buffer!.isBaseline).isFalse();
      check(buffer.coordinates['group']).equals('String Group');
    });

    test(
      'run subcommand with --diff against baseline JSON file renders delta',
      () async {
        final baseFile = File(d.path('baseline.json'));
        final baseEntry = createSampleEntry(
          name: 'diff_target',
          metrics: createSampleMetrics(
            meanNs: 1000.0,
            medianNs: 1000.0,
            minNs: 950.0,
            maxNs: 1050.0,
            stddevNs: 10.0,
            cv: 0.01,
            p95Ns: 1020.0,
            p99Ns: 1040.0,
            opsPerSec: 1000000.0,
          ),
          rawTrialsNs: const [980.0, 1000.0, 1020.0],
        );
        createSampleSuite(benchmarks: [baseEntry]).saveToFile(baseFile);

        final benchFile = writeSyncBenchmark(
          fileName: 'bench.dart',
          className: 'DiffTarget',
          name: 'diff_target',
          body: 'Blackhole.consume(42);',
        );

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'run',
          '-t',
          'jit',
          '--trials',
          '2',
          '--force-run',
          '--no-save',
          '--diff',
          baseFile.path,
          benchFile.path,
        ]);

        check(exitCode).equals(0);
      },
    );

    test('run subcommand exits with error on invalid target', () async {
      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'run',
        '-t',
        'invalid_target',
        'benchmark/',
      ]);
      check(exitCode).not((it) => it.equals(0));
    });

    test(
      'run subcommand exits with usage error on non-Dart file target',
      () async {
        await d.file('bench.txt', 'text').create();
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run(['run', d.path('bench.txt')]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test(
      'run subcommand exits with noInput error on non-existent directory',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'run',
          '/non_existent_bench_dir_123',
        ]);
        check(exitCode).equals(ExitCode.noInput.code);
      },
    );

    test(
      'run subcommand exits with usage error on non-existent --d8-path',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'run',
          '--d8-path',
          '/non_existent_d8_123',
        ]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test(
      'run subcommand exits with usage error on non-existent --node-path',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'run',
          '--node-path',
          '/non_existent_node_123',
        ]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test(
      'run subcommand exits with software error when target compilation fails',
      () async {
        final benchFile = writeBrokenBenchmark(fileName: 'broken_bench.dart');

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run(['run', '-t', 'jit', benchFile.path]);
        check(exitCode).equals(ExitCode.software.code);
      },
    );

    test(
      'run subcommand exits with software error when target execution crashes',
      () async {
        final benchFile = writeSyncBenchmark(
          fileName: 'crash_bench.dart',
          className: 'CrashingBenchmark',
          name: 'crash_bench',
          body: "throw StateError('Intentional crash');",
        );

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'run',
          '-t',
          'jit',
          '--trials',
          '1',
          '--force-run',
          '--no-save',
          benchFile.path,
        ]);
        check(exitCode).equals(ExitCode.software.code);
      },
    );

    test('run subcommand exits with software error when target produces zero '
        'results', () async {
      final benchFile = writeEmptyBenchmark();

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--no-save',
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.software.code);
    });

    test('run subcommand preserves successful results but exits with software '
        'error on partial target failure', () async {
      writeSyncBenchmark(
        fileName: 'good_bench.dart',
        className: 'GoodBenchmark',
        name: 'good_bench',
      );
      writeBrokenBenchmark(fileName: 'bad_bench.dart');

      final outputFile = File(d.path('results.json'));
      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '1',
        '--force-run',
        '--save',
        outputFile.path,
        d.sandbox,
      ]);

      check(exitCode).equals(ExitCode.software.code);
      check(outputFile.existsSync()).isTrue();
      final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
      check(suite.benchmarks.length).equals(1);
      check(suite.benchmarks.first.name).equals('good_bench');
    });
  });
}
