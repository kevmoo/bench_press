import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('CLI End-to-End Execution', () {
    test(
      'dart run bin/bench_press.dart executes run and emits valid JSON',
      () async {
        final benchFile = writeSyncBenchmark(
          fileName: 'e2e_bench.dart',
          className: 'E2EBenchmark',
          name: 'e2e_calc',
          body: 'Blackhole.consume(999);',
        );
        final resultsFile = File(d.path('e2e_results.json'));

        final result = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '-t',
          'jit',
          '--trials',
          '2',
          '--force-run',
          '-o',
          resultsFile.path,
          benchFile.path,
        ]);

        check(result.exitCode).equals(0);
        check(resultsFile.existsSync()).isTrue();

        final suite = BenchmarkSuiteResult.loadFromFile(resultsFile);
        check(suite.benchmarks.length).equals(1);
        check(suite.benchmarks.first.name).equals('e2e_calc');

        final jsonResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '-t',
          'jit',
          '--trials',
          '1',
          '--force-run',
          '--no-save',
          '--format',
          'json',
          benchFile.path,
        ]);

        check(jsonResult.exitCode).equals(0);
        final decoded = jsonDecode(jsonResult.stdout.toString());
        check(decoded).isA<Map<String, Object?>>();
      },
    );

    test('fail-on-unstable flag exits with code 2 when unstable benchmark '
        'is detected', () async {
      final resultsFile = File(d.path('unstable_results.json'));
      final entry = createSampleEntry(
        name: 'jitter_bench',
        metrics: createSampleMetrics(
          minNs: 90.0,
          maxNs: 110.0,
          stddevNs: 10.0,
          cv: 0.1,
          isStable: false,
        ),
      );
      createSampleSuite(benchmarks: [entry]).saveToFile(resultsFile);

      final benchFile = writeSyncBenchmark(
        fileName: 'noop_bench.dart',
        className: 'NoopBench',
        name: 'noop',
        body: 'Blackhole.consume(0);',
      );

      final runner = BenchPressCommandRunner();
      final code = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '1',
        '--force-run',
        '--fail-on-unstable',
        '-o',
        resultsFile.path,
        benchFile.path,
      ]);

      check(code).equals(2);
    });

    test('--version prints version on stdout and exits with code 0', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/bench_press.dart',
        '--version',
      ]);

      check(result.exitCode).equals(0);
      check(result.stdout.toString()).contains('bench_press version:');
      check(result.stderr.toString().trim()).isEmpty();
    });

    test('--help prints usage on stdout and exits with code 0', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/bench_press.dart',
        '--help',
      ]);

      check(result.exitCode).equals(0);
      check(result.stdout.toString()).contains('A modern, statistically sound');
      check(result.stdout.toString()).contains('Available commands:');
    });

    test(
      'invalid option prints error and usage to stderr with exit code 64',
      () async {
        final result = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          '--non-existent-option-xyz',
        ]);

        check(result.exitCode).equals(64);
        check(result.stderr.toString())
            .contains('Could not find an option named');
        check(result.stderr.toString())
            .contains('Usage: bench_press <command>');
      },
    );

    test('missing input file in report command exits with code 66', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/bench_press.dart',
        'report',
        '-f',
        'non_existent_telemetry_file_12345.json',
      ]);

      check(result.exitCode).equals(66);
      check(result.stderr.toString()).contains('does not exist');
    });

    test(
      'CLI executes BenchmarkGroup and renders Model 1 comparison table',
      () async {
        await d.file('group_bench.dart', '''
import 'package:bench_press/bench_press.dart';

final BenchmarkGroup stringGroup = BenchmarkGroup('String Construction', [
  BenchmarkVariant('concat', () => Blackhole.consume(1), isBaseline: true),
  BenchmarkVariant('buffer', () => Blackhole.consume(2)),
]);

final List<Object> benchmarks = [stringGroup];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
''').create();

        final resultsFile = File(d.path('group_results.json'));

        final result = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '-t',
          'jit',
          '--trials',
          '2',
          '--force-run',
          '--save',
          resultsFile.path,
          d.path('group_bench.dart'),
        ]);

        check(result.exitCode).equals(0);
        check(resultsFile.existsSync()).isTrue();

        final stdout = result.stdout.toString();
        check(stdout).contains('### Group: String Construction (`jit`)');
        check(stdout).contains('`concat` (Baseline)');
        check(stdout).contains('`buffer`');
      },
    );

    test(
      'CLI executes run --diff with baseline.json and renders delta table',
      () async {
        final baseFile = File(d.path('baseline.json'));
        final baseEntry = createSampleEntry(
          name: 'diff_cli_workload',
          samples: 3,
          metrics: createSampleMetrics(
            meanNs: 500.0,
            medianNs: 500.0,
            minNs: 480.0,
            maxNs: 520.0,
            stddevNs: 5.0,
            cv: 0.01,
            p95Ns: 510.0,
            p99Ns: 515.0,
            opsPerSec: 2000000.0,
          ),
          rawTrialsNs: const [490.0, 500.0, 510.0],
        );
        createSampleSuite(benchmarks: [baseEntry]).saveToFile(baseFile);

        final benchFile = writeSyncBenchmark(
          fileName: 'diff_bench.dart',
          className: 'DiffCliBenchmark',
          name: 'diff_cli_workload',
          body: 'Blackhole.consume(1234);',
        );

        final result = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
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

        check(result.exitCode).equals(0);
        final stdout = result.stdout.toString();
        check(stdout).contains('### Baseline Delta: `${baseFile.path}`');
        check(stdout).contains('diff_cli_workload');
        check(stdout).contains('95% CI (Fieller)');
      },
    );

    test(
      'bench_press diff supports positional arguments <baseline> [current]',
      () async {
        final baseFile = File(d.path('base.json'));
        final currFile = File(d.path('curr.json'));

        final baseMetrics = createSampleMetrics(
          minNs: 90.0,
          maxNs: 110.0,
          stddevNs: 2.0,
          cv: 0.02,
          p95Ns: 103.0,
          p99Ns: 105.0,
        );
        final currMetrics = createSampleMetrics(
          meanNs: 50.0,
          medianNs: 50.0,
          minNs: 45.0,
          maxNs: 55.0,
          stddevNs: 1.0,
          cv: 0.02,
          p95Ns: 52.0,
          p99Ns: 53.0,
          opsPerSec: 20000000.0,
        );

        createSampleSuite(
          benchmarks: [
            createSampleEntry(
              name: 'pos_test_bench',
              samples: 3,
              metrics: baseMetrics,
              rawTrialsNs: const [98.0, 100.0, 102.0],
            ),
            createSampleEntry(
              name: 'unique_curr_bench',
              samples: 3,
              metrics: baseMetrics,
              rawTrialsNs: const [98.0, 100.0, 102.0],
            ),
          ],
        ).saveToFile(baseFile);

        createSampleSuite(
          benchmarks: [
            createSampleEntry(
              name: 'pos_test_bench',
              samples: 3,
              metrics: currMetrics,
              rawTrialsNs: const [49.0, 50.0, 51.0],
            ),
            createSampleEntry(
              name: 'unique_curr_bench',
              samples: 3,
              metrics: currMetrics,
              rawTrialsNs: const [49.0, 50.0, 51.0],
            ),
          ],
        ).saveToFile(currFile);

        final outFile = File(d.path('diff_out.md'));
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'diff',
          baseFile.path,
          currFile.path,
          '-o',
          outFile.path,
        ]);
        check(exitCode).equals(0);
        check(outFile.existsSync()).isTrue();
        final report = outFile.readAsStringSync();
        check(report).contains('pos_test_bench');
        check(report).contains('95% CI (Fieller)');

        final outFlagFile = File(d.path('diff_flag_out.md'));
        final exitCodeFlag = await runner.run([
          'diff',
          '-b',
          baseFile.path,
          currFile.path,
          '-o',
          outFlagFile.path,
        ]);
        check(exitCodeFlag).equals(0);
        check(outFlagFile.existsSync()).isTrue();
        final flagReport = outFlagFile.readAsStringSync();
        check(flagReport).contains('pos_test_bench');
        check(flagReport).contains('unique_curr_bench');

        await check(
          runner.run(['diff', baseFile.path, currFile.path, 'extra.json']),
        ).throws<UsageException>();
        await check(
          runner.run([
            'diff',
            '-b',
            baseFile.path,
            currFile.path,
            'extra.json',
          ]),
        ).throws<UsageException>();
        await check(
          runner.run([
            'diff',
            baseFile.path,
            currFile.path,
            '-c',
            currFile.path,
          ]),
        ).throws<UsageException>();
        await check(
          runner.run([
            'diff',
            '-b',
            baseFile.path,
            '-c',
            currFile.path,
            currFile.path,
          ]),
        ).throws<UsageException>();
      },
    );

    test('run rejects a malformed --pin-cpu with exit code 64', () async {
      // A malformed CPU list must not degrade to an unpinned run: that would
      // exit 0 and emit a full report of numbers that look pinned, with the
      // only trace on stderr — the stream discarded when capturing the report.
      final result = await Process.run('dart', [
        'run',
        'bin/bench_press.dart',
        'run',
        '--pin-cpu',
        '0..3',
      ]);
      check(result.exitCode).equals(64);
      check(result.stderr.toString()).contains('Invalid --pin-cpu value');
      check(
        because: 'a rejected run must not emit a benchmark report',
        result.stdout.toString(),
      ).not((s) => s.contains('| Benchmark |'));
    });

    test('--pin-cpu on a jit-only --isolate-mode run pins nothing', () async {
      final benchFile = writeSyncBenchmark(
        fileName: 'pin_isolate_bench.dart',
        className: 'PinIsolateBenchmark',
        name: 'pin_isolate',
        body: 'Blackhole.consume(1);',
      );
      final result = await Process.run('dart', [
        'run',
        'bin/bench_press.dart',
        'run',
        '-t',
        'jit',
        '--isolate-mode',
        '--pin-cpu',
        '0',
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        benchFile.path,
      ]);
      final err = result.stderr.toString();
      check(err).contains('--pin-cpu does not apply to --isolate-mode');
      // The run is jit-only, so there is no spawned target left to pin. Saying
      // "Non-JIT targets are still pinned" here would be vacuously true and
      // read as reassurance.
      check(
        because: 'jit-only isolate run has no other target to pin',
        err,
      ).contains('no other targets, so nothing is pinned');
    });

    test(
      'run and validate reject non-existent --d8-path with exit code 64',
      () async {
        final runResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '--d8-path',
          '/non_existent_d8_path_xyz',
        ]);
        check(runResult.exitCode).equals(64);
        check(runResult.stderr.toString()).contains(
          'Custom D8 executable "/non_existent_d8_path_xyz" does not exist.',
        );

        final validateResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'validate',
          '--d8-path',
          '/non_existent_d8_path_xyz',
        ]);
        check(validateResult.exitCode).equals(64);
        check(validateResult.stderr.toString()).contains(
          'Custom D8 executable "/non_existent_d8_path_xyz" does not exist.',
        );
      },
    );

    test(
      'run and validate reject non-existent --node-path with exit code 64',
      () async {
        final runResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '--node-path',
          '/non_existent_node_path_xyz',
        ]);
        check(runResult.exitCode).equals(64);
        check(runResult.stderr.toString()).contains(
          'Custom Node.js executable "/non_existent_node_path_xyz" does not exist.',
        );

        final validateResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'validate',
          '--node-path',
          '/non_existent_node_path_xyz',
        ]);
        check(validateResult.exitCode).equals(64);
        check(validateResult.stderr.toString()).contains(
          'Custom Node.js executable "/non_existent_node_path_xyz" does not exist.',
        );
      },
    );

    test(
      'run and validate accept valid --d8-path and --node-path flags',
      () async {
        await d.file('dummy_d8', '').create();
        await d.file('dummy_node', '').create();
        final benchFile = writeSyncBenchmark(
          fileName: 'runner_bench.dart',
          className: 'FlagBench',
          name: 'flag_bench',
        );

        final valResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'validate',
          '-t',
          'jit',
          '--d8-path',
          d.path('dummy_d8'),
          '--node-path',
          d.path('dummy_node'),
          benchFile.path,
        ]);
        check(valResult.exitCode).equals(0);

        final runResult = await Process.run('dart', [
          'run',
          'bin/bench_press.dart',
          'run',
          '-t',
          'jit',
          '--trials',
          '1',
          '--force-run',
          '--no-save',
          '--d8-path',
          d.path('dummy_d8'),
          '--node-path',
          d.path('dummy_node'),
          benchFile.path,
        ]);
        check(runResult.exitCode).equals(0);
      },
    );

    test('run accepts --no-cache flag and executes cleanly', () async {
      final benchFile = writeSyncBenchmark(
        fileName: 'no_cache_bench.dart',
        className: 'NoCacheBench',
        name: 'no_cache_bench',
        body: 'Blackhole.consume(42);',
      );

      final runner = BenchPressCommandRunner();
      final code = await runner.run([
        'run',
        '-t',
        'jit',
        '--trials',
        '1',
        '--force-run',
        '--no-save',
        '--no-cache',
        benchFile.path,
      ]);
      check(code).equals(0);
    });
  });
}
