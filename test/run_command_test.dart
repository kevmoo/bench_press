import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bench_press/src/cli/command_runner.dart';
import 'package:bench_press/src/cli/compiler.dart';
import 'package:bench_press/src/cli/process_runner.dart';
import 'package:bench_press/src/cli/run_command.dart';
import 'package:bench_press/src/cli/sdk.dart';
import 'package:bench_press/src/config/bench_press_config.dart';
import 'package:bench_press/src/telemetry/schema.dart';
import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

CommandRunner<int> _fastRunRunner({DartSdk sdk = const DartSdk()}) {
  final runner = CommandRunner<int>('bench_press', 'test');
  runner.argParser.addFlag('verbose', abbr: 'v', negatable: false);
  runner.addCommand(
    RunCommand(
      sdk: sdk,
      compiler: TargetCompiler(sdk: sdk),
      processRunner: BenchmarkProcessRunner(sdk: sdk),
      hostCheckSampleDuration: Duration.zero,
    ),
  );
  return runner;
}

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
        check(outputFile.existsSync()).isTrue;

        final suite = loadSuiteFromFile(outputFile);
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
      check(outputFile.existsSync()).isTrue;

      final suite = loadSuiteFromFile(outputFile);
      check(suite.benchmarks.length).equals(2);
      check(suite.groups).contains('String Group');

      final concat = suite.findEntry('concat', 'jit');
      check(concat).isNotNull();
      check(concat!.isBaseline).isTrue;
      check(concat.coordinates['group']).equals('String Group');

      final buffer = suite.findEntry('buffer', 'jit');
      check(buffer).isNotNull();
      check(buffer!.isBaseline).isFalse;
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
      check(exitCode).not(.it()..equals(0));
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
      check(outputFile.existsSync()).isTrue;
      final suite = loadSuiteFromFile(outputFile);
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

    test('run --target narrows a runtime-axis matrix to the requested '
        'runtimes', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
  axes:
    runtime: [jit, aot]
''');
      final benchFile = writeSyncBenchmark();
      final outputFile = File(d.path('narrowed.json'));

      final exitCode = await BenchPressCommandRunner().run([
        'run',
        '-c',
        configFile.path,
        '-t',
        'jit',
        '--trials',
        '1',
        '--force-run',
        '-o',
        outputFile.path,
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.success.code);

      final suite = loadSuiteFromFile(outputFile);
      check(suite.benchmarks).isNotEmpty;
      check(
        because: 'the aot coordinate was not requested and must not run',
        suite.benchmarks.map((b) => b.target).toSet(),
      ).deepEquals({'jit'});
    });

    test('run --target with no matching runtime coordinate is a usage error, '
        'with and without --dry-run', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  axes:
    runtime: [jit, aot]
''');
      final benchFile = writeSyncBenchmark();
      final runner = BenchPressCommandRunner();

      final dryRunCode = await runner.run([
        'run',
        '--dry-run',
        '-c',
        configFile.path,
        '-t',
        'wasm',
        benchFile.path,
      ]);
      check(dryRunCode).equals(ExitCode.usage.code);

      final runCode = await runner.run([
        'run',
        '-c',
        configFile.path,
        '-t',
        'wasm',
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        benchFile.path,
      ]);
      check(runCode).equals(ExitCode.usage.code);
    });

    test('run saves to defaults.output unless -o overrides it', () async {
      final configured = File(d.path('configured.json'));
      final explicit = File(d.path('explicit.json'));
      final configFile = writeBenchPressYaml('''
defaults:
  output: ${configured.path}
''');
      final benchFile = writeSyncBenchmark();
      List<String> runArgs(List<String> extra) => [
        'run',
        '-c',
        configFile.path,
        '-t',
        'jit',
        '--trials',
        '2',
        '--force-run',
        ...extra,
        benchFile.path,
      ];

      check(await BenchPressCommandRunner().run(runArgs([]))).equals(0);
      check(configured.existsSync()).isTrue;

      configured.deleteSync();
      check(await BenchPressCommandRunner().run(runArgs(['-o', explicit.path])))
          .equals(0);
      check(explicit.existsSync()).isTrue;
      check(configured.existsSync()).isFalse;
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
      check(expandedSdk.customSdkPath!).not(.it()..startsWith('~'));
    });

    test('expandHomeDirectory expands only a leading tilde', () {
      check(expandHomeDirectory('results.json')).equals('results.json');
      check(expandHomeDirectory('out/~/results.json'))
          .equals('out/~/results.json');
      check(expandHomeDirectory('~/bench/results.json'))
        ..not(.it()..startsWith('~'))
        ..endsWith('/bench/results.json');
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
        final suite = loadSuiteFromFile(outputFile);
        check(suite.benchmarks.map((b) => b.name).toList())
            .deepEquals(['first_workload', 'second_workload']);
      },
    );

    test('run subcommand exits with software error when matrix sdk axis has '
        'invalid path even if stock sdk coordinate succeeds', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
    sdk: stock
  axes:
    runtime: [jit]
    sdk:
      stock: stock
      fork: ${d.path('non_existent_sdk_root')}
''');
      final benchFile = writeSyncBenchmark();

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'run',
        '-c',
        configFile.path,
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        benchFile.path,
      ]);

      check(exitCode).equals(ExitCode.software.code);
    });

    test('run subcommand executes --processes across multiple OS process '
        'rounds and rejects invalid values', () async {
      final benchFile = writeSyncBenchmark(
        subDir: 'benchmark',
        fileName: 'proc_bench.dart',
        className: 'ProcBenchmark',
        name: 'proc_workload',
        body: 'Blackhole.consume(42);',
      );
      final outputFile = File(d.path('proc_results.json'));
      final runner = BenchPressCommandRunner();

      final badCode = await runner.run([
        'run',
        '--processes',
        '0',
        benchFile.path,
      ]);
      check(badCode).equals(ExitCode.usage.code);

      final exitCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '2',
        '--processes',
        '2',
        '--force-run',
        '-o',
        outputFile.path,
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.success.code);
      final suite = loadSuiteFromFile(outputFile);
      final entry = suite.benchmarks.single;
      check(entry.processes).equals(2);
      check(entry.processMeansNs.length).equals(2);
      check(entry.processTrialsNs.length).equals(2);
      check(entry.samples).equals(4);
      check(entry.metrics.varianceComponents).isNotNull();
      check(entry.pairing).isNotNull();
      check(entry.pairing!.rounds).equals(2);
      check(entry.pairing!.interleaved).isTrue;

      final badThresholdCode = await runner.run([
        'run',
        '--threshold',
        '1.5',
        benchFile.path,
      ]);
      check(badThresholdCode).equals(ExitCode.usage.code);

      final thresholdCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '2',
        '--threshold',
        '0.02',
        '--force-run',
        '--no-save',
        benchFile.path,
      ]);
      check(thresholdCode).equals(ExitCode.success.code);
    });

    test(
      'separate --processes runs merged into one file stamp distinct groupIds',
      () async {
        final benchFile1 = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'proc_bench_1.dart',
          className: 'ProcBenchmark1',
          name: 'proc_workload_1',
          body: 'Blackhole.consume(42);',
        );
        final benchFile2 = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'proc_bench_2.dart',
          className: 'ProcBenchmark2',
          name: 'proc_workload_2',
          body: 'Blackhole.consume(43);',
        );
        final outputFile = File(d.path('merged_proc_results.json'));
        final runner = BenchPressCommandRunner();

        for (final file in [benchFile1, benchFile2]) {
          final code = await runner.run([
            'run',
            '-t',
            'jit',
            '--trials',
            '1',
            '--processes',
            '2',
            '--force-run',
            '-o',
            outputFile.path,
            file.path,
          ]);
          check(code).equals(ExitCode.success.code);
        }

        final mergedSuite = loadSuiteFromFile(outputFile);
        check(mergedSuite.benchmarks.length).equals(2);
        check(mergedSuite.benchmarks[0].pairing).isNotNull();
        check(mergedSuite.benchmarks[1].pairing).isNotNull();
        check(
          canPairEntries(mergedSuite.benchmarks[0], mergedSuite.benchmarks[1]),
        ).isFalse;
      },
    );

    test('multi-cell --processes 2 pairs coordinates and validates --pin-cpu / '
        'host_check telemetry', () async {
      final configFile = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
    flags: --define=ARM=0
  axes:
    runtime: [jit]
    flags: [--define=ARM=0, --define=ARM=1]
''');
      final benchFile = writeSyncBenchmark(
        subDir: 'benchmark',
        fileName: 'pair_matrix_bench.dart',
        className: 'PairMatrixBenchmark',
        name: 'pair_matrix_workload',
        body: 'Blackhole.consume(42);',
      );
      final outputFile = File(d.path('pair_matrix_results.json'));
      final runner = BenchPressCommandRunner();

      if (Platform.isLinux) {
        final invalidCoreCode = await runner.run([
          'run',
          '--pin-cpu',
          '99999',
          benchFile.path,
        ]);
        check(invalidCoreCode).equals(ExitCode.usage.code);
      }

      final exitCode = await runner.run([
        'run',
        '-c',
        configFile.path,
        '--trials',
        '1',
        '--processes',
        '2',
        '--force-run',
        '-o',
        outputFile.path,
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.success.code);

      final suite = loadSuiteFromFile(outputFile);
      check(suite.benchmarks.length).equals(2);
      check(canPairEntries(suite.benchmarks[0], suite.benchmarks[1])).isTrue;
      check(suite.benchmarks[0].pairing!.schedule).equals('abba_baab');
      if (Platform.isLinux) {
        check(suite.environment.extra['host_check'])
            .isA<Map<String, Object?>>();
      }
    });

    test(
      'run subcommand forwards --stop-at-ci and rejects invalid values',
      () async {
        final benchFile = writeSyncBenchmark(
          subDir: 'benchmark',
          fileName: 'stop_bench.dart',
          className: 'StopBenchmark',
          name: 'stop_workload',
          body: 'Blackhole.consume(42);',
        );
        final outputFile = File(d.path('stop_results.json'));
        final runner = BenchPressCommandRunner();

        for (final bad in ['0', '1.0', 'abc']) {
          final badCode = await runner.run([
            'run',
            '--stop-at-ci',
            bad,
            benchFile.path,
          ]);
          check(badCode).equals(ExitCode.usage.code);
        }

        final exitCode = await runner.run([
          'run',
          '-t',
          'jit',
          '--trials',
          '16',
          '--stop-at-ci',
          '0.99',
          '--force-run',
          '-o',
          outputFile.path,
          benchFile.path,
        ]);
        check(exitCode).equals(ExitCode.success.code);
        final suite = loadSuiteFromFile(outputFile);
        check(suite.benchmarks.single.samples).equals(8);
      },
    );

    test('RunCommand(hostCheckSampleDuration: Duration.zero) exercises odd '
        '--processes 3 interleaving, multi-process round failures, and '
        '--pin-cpu / --d8-path / --node-path handling in-process', () async {
      final fakeD8 = File(d.path('fake_d8'))..writeAsStringSync('');
      final fakeNode = File(d.path('fake_node'))..writeAsStringSync('');
      final groupBench = File(d.path('matrix_group_bench.dart'))
        ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

const _fastCfg = BenchmarkConfig(
  minWarmupIterations: 1,
  maxWarmupIterations: 2,
  targetBatchDuration: Duration(milliseconds: 1),
  forceRun: true,
);

final BenchmarkGroup grp = BenchmarkGroup(
  'G',
  [
    BenchmarkVariant('v_base', () => Blackhole.consume(1), isBaseline: true),
    BenchmarkVariant('v_cand', () => Blackhole.consume(2)),
  ],
  config: _fastCfg,
);

void main(List<String> args) => mainBenchmarkSuite([grp], args);
''');
      final runner = _fastRunRunner();

      // Valid --d8-path and --node-path normalize cleanly under --dry-run.
      final dryCode = await runner.run([
        'run',
        '--dry-run',
        '--d8-path',
        fakeD8.path,
        '--node-path',
        fakeNode.path,
        groupBench.path,
      ]);
      check(dryCode).equals(ExitCode.success.code);

      // Malformed --pin-cpu syntax fails upfront with usage error.
      final badPinSyntax = await runner.run([
        'run',
        '--pin-cpu',
        'not-a-cpu-list',
        groupBench.path,
      ]);
      check(badPinSyntax).equals(ExitCode.usage.code);

      if (Platform.isLinux) {
        // Out-of-range core fails via HostEnvironment.validateAffinity.
        final badPinCore = await runner.run([
          'run',
          '--pin-cpu',
          '99999',
          groupBench.path,
        ]);
        check(badPinCore).equals(ExitCode.usage.code);
      }

      // --pin-cpu 0 with --isolate-mode on JIT-only warns and runs unpinned.
      final isoPinJitOut = File(d.path('iso_pin_jit.json'));
      final isoPinCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--isolate-mode',
        '--pin-cpu',
        '0',
        '--trials',
        '1',
        '--force-run',
        '-o',
        isoPinJitOut.path,
        groupBench.path,
      ]);
      check(isoPinCode).equals(ExitCode.success.code);
      final isoSuite = loadSuiteFromFile(isoPinJitOut);
      if (Platform.isLinux) {
        final hc =
            isoSuite.environment.extra['host_check'] as Map<String, Object?>?;
        check(hc).isNotNull();
        check(hc!['os']).equals('linux');
        check(hc['is_supported']).equals(true);
      }

      // --pin-cpu 0 with --isolate-mode across a [jit, wasm] matrix where
      // wasm is unavailable warns that non-JIT targets remain pinned.
      final multiTargetConfig = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
  axes:
    runtime: [jit, wasm]
''');
      final noWasmFastRunner = _fastRunRunner(
        sdk: DartSdk(
          customSdkPath: File(Platform.resolvedExecutable).parent.parent.path,
          environment: const {'PATH': ''},
        ),
      );
      final isoMultiCode = await noWasmFastRunner.run([
        'run',
        '-c',
        multiTargetConfig.path,
        '--isolate-mode',
        '--pin-cpu',
        '0',
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        groupBench.path,
      ]);
      check(isoMultiCode).equals(ExitCode.success.code);

      // Odd --processes 3 across 2 matrix cells runs ABBA BAAB via
      // RoundScheduler.run, emits the odd-round warning, intersects group +
      // matrix isBaseline, and pairs matching variants across cells.
      final matrixConfig = writeBenchPressYaml('''
matrix:
  baseline:
    runtime: jit
    flags: --define=CELL=0
  axes:
    runtime: [jit]
    flags: [--define=CELL=0, --define=CELL=1]
''');
      final oddProcOut = File(d.path('odd_proc.json'));
      final oddProcCode = await runner.run([
        'run',
        '-c',
        matrixConfig.path,
        '--isolate-mode',
        '--trials',
        '1',
        '--processes',
        '3',
        '--force-run',
        '-o',
        oddProcOut.path,
        groupBench.path,
      ]);
      check(oddProcCode).equals(ExitCode.success.code);
      final oddSuite = loadSuiteFromFile(oddProcOut);
      check(oddSuite.benchmarks.length).equals(4);
      final baselines = oddSuite.benchmarks.where((b) => b.isBaseline);
      check(baselines.length).equals(1);
      check(baselines.single.name).equals('v_base');
      check(baselines.single.coordinates['flags']).equals('--define=CELL=0');
      final vBaseCells = oddSuite.getEntriesForBenchmark('v_base');
      check(vBaseCells.length).equals(2);
      check(canPairEntries(vBaseCells[0], vBaseCells[1])).isTrue;
      check(vBaseCells[0].pairing!.rounds).equals(3);
      check(vBaseCells[0].pairing!.schedule).equals('abba_baab');

      // Subprocess/round failure on round 2 of a --processes 2 run exits with
      // ExitCode.software, retains round 1's sample, and withholds pairing.
      final markerPath = d.path('round_fail_marker').replaceAll(r'\', '/');
      final flakyBench = File(d.path('flaky_proc_bench.dart'))
        ..writeAsStringSync('''
import 'dart:io';
import 'package:bench_press/bench_press.dart';

final class FlakyProcBench extends Benchmark {
  FlakyProcBench()
    : super(
        'flaky_proc',
        config: const BenchmarkConfig(
          minWarmupIterations: 1,
          maxWarmupIterations: 2,
          targetBatchDuration: Duration(milliseconds: 1),
          forceRun: true,
        ),
      );
  @override
  void run() {
    Blackhole.consume(1);
  }
}

void main(List<String> args) {
  final marker = File('$markerPath');
  if (marker.existsSync()) {
    throw StateError('Simulated failure on second process round');
  }
  marker.writeAsStringSync('ran_once');
  mainBenchmark(FlakyProcBench(), args);
}
''');
      final partialOut = File(d.path('partial_proc.json'));
      final partialCode = await runner.run([
        'run',
        '-t',
        'jit',
        '--isolate-mode',
        '--trials',
        '2',
        '--processes',
        '2',
        '--force-run',
        '-o',
        partialOut.path,
        flakyBench.path,
      ]);
      check(partialCode).equals(ExitCode.software.code);
      check(partialOut.existsSync()).isTrue;
      final partialSuite = loadSuiteFromFile(partialOut);
      final partialEntry = partialSuite.benchmarks.single;
      check(partialEntry.name).equals('flaky_proc');
      check(partialEntry.processes).equals(1);
      check(partialEntry.pairing).isNull;
    });
  });
}
