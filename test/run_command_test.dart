import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/cli/run_command.dart';
import 'package:bench_press/src/config/bench_press_config.dart';
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

    test('run --dry-run prints resolved matrix plan and exits 0', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
    flags: -O2
  axes:
    runtime: [jit, aot]
    flags: [-O2, -O4]
''');
      final benchFile = writeSyncBenchmark();

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'run',
        '--dry-run',
        '-c',
        configFile.path,
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.success.code);
    });

    test('run handles empty directory, invalid config targets, and invalid '
        'matrix config', () async {
      final runner = BenchPressCommandRunner();

      // Empty directory -> ExitCode.noInput
      final emptyCode = await runner.run(['run', d.sandbox]);
      check(emptyCode).equals(ExitCode.noInput.code);

      // Invalid defaults.targets in bench_press.yaml -> ExitCode.usage
      final badTargetsConfig = writeBenchPressYaml('''
defaults:
  targets: [not_a_valid_runtime]
''');
      final benchFile = writeSyncBenchmark();
      final badTargetsCode = await runner.run([
        'run',
        '-c',
        badTargetsConfig.path,
        benchFile.path,
      ]);
      check(badTargetsCode).equals(ExitCode.usage.code);

      // Invalid runtime in matrix axis -> ExitCode.config (ConfigValidator)
      final badMatrixConfig = writeBenchPressYaml('''
matrix:
  axes:
    runtime:
      - invalid_runtime
''');
      final badMatrixCode = await runner.run([
        'run',
        '-c',
        badMatrixConfig.path,
        benchFile.path,
      ]);
      check(badMatrixCode).equals(ExitCode.config.code);
    });

    test('run executes Cartesian matrix with runtime, flags, max-trials, '
        'json format, and diff fallback', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
    flags: --define=MODE=1
  axes:
    runtime: [jit]
    flags: [--define=MODE=1, --define=MODE=2]
''');
      final benchFile = writeSyncBenchmark();
      final corruptDiffFile = File(d.path('corrupt_base.json'))
        ..writeAsStringSync('{ invalid json');

      final runner = BenchPressCommandRunner();
      final jsonCode = await runner.run([
        'run',
        '-c',
        configFile.path,
        '--trials',
        '1',
        '--max-trials',
        '2',
        '--force-run',
        '--no-save',
        '--format',
        'json',
        benchFile.path,
      ]);
      check(jsonCode).equals(ExitCode.success.code);

      // Test --diff fallback when baseline file is malformed JSON
      final diffFallbackCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        '--diff',
        corruptDiffFile.path,
        benchFile.path,
      ]);
      check(diffFallbackCode).equals(ExitCode.success.code);

      // Test unavailable runtime (wasm with empty PATH) skips cleanly
      const noWasmSdk = DartSdk(environment: {'PATH': ''});
      final noWasmRunner = BenchPressCommandRunner(sdk: noWasmSdk);
      final unavailableCode = await noWasmRunner.run([
        'run',
        '-t',
        'wasm',
        '--no-save',
        benchFile.path,
      ]);
      check(unavailableCode).equals(ExitCode.software.code);
    });

    test('resolveTargetPath and resolveSdkFromCoordinate handle defaults '
        'and home tilde expansion', () {
      check(resolveTargetPath(['custom_dir'])).equals('custom_dir');
      check(resolveTargetPaths(['file_a.dart', 'file_b.dart']))
          .deepEquals(['file_a.dart', 'file_b.dart']);
      check(resolveTargetPath([])).equals('benchmark');
      check(resolveTargetPaths([])).deepEquals(['benchmark']);

      const baseSdk = DartSdk();
      final stockCoord = MatrixCoordinate(
        const {'sdk': 'stock'},
        true,
        const {'sdk': 'stock'},
      );
      check(resolveSdkFromCoordinate(stockCoord, baseSdk)).equals(baseSdk);

      final tildeCoord = MatrixCoordinate(
        const {'sdk': '~/.custom_sdk'},
        false,
        const {'sdk': '~/.custom_sdk'},
      );
      final expandedSdk = resolveSdkFromCoordinate(tildeCoord, baseSdk);
      check(expandedSdk.customSdkPath).isNotNull();
      check(expandedSdk.customSdkPath!).not((it) => it.startsWith('~'));
    });

    test(
      'run subcommand executes all positional benchmark files in order',
      () async {
        final fileA = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'first_bench.dart',
          className: 'FirstBenchmark',
          name: 'first_workload',
        );
        final fileB = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'second_bench.dart',
          className: 'SecondBenchmark',
          name: 'second_workload',
        );
        final outputFile = File(d.path('multi_file_results.json'));
        final runner = BenchPressCommandRunner();

        final exitCode = await runner.run([
          'run',
          '-t',
          'jit',
          '--trials',
          '1',
          '--force-run',
          '-o',
          outputFile.path,
          fileA.path,
          fileB.path,
        ]);

        check(exitCode).equals(ExitCode.success.code);
        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.map((b) => b.name).toList())
            .deepEquals(['first_workload', 'second_workload']);
      },
    );
  });
}
