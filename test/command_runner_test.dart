import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('BenchPressCommandRunner', () {
    test('--version flag prints version and exits cleanly', () async {
      final runner = BenchPressCommandRunner();
      final code = await runner.run(['--version']);
      check(code).equals(0);
    });

    test('benchPressVersion matches version in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec);
      check(match).isNotNull();
      check(benchPressVersion).equals(match!.group(1)!);
    });

    test('--help prints available commands and usage', () async {
      final runner = BenchPressCommandRunner();
      final code = await runner.run(['--help']);
      check(code).equals(0);
    });

    test('validate subcommand conducts fast smoke test', () async {
      final benchFile = writeSyncBenchmark(body: 'Blackhole.consume(123);');

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'validate',
        '-t',
        'jit',
        benchFile.path,
      ]);

      check(exitCode).equals(0);
    });

    test(
      'report subcommand renders markdown report from stored JSON',
      () async {
        final telemetryFile = File(d.path('suite.json'));
        final markdownOut = File(d.path('report.md'));

        final entry = createSampleEntry(
          name: 'report_workload',
          metrics: createSampleMetrics(maxNs: 110.0),
        );
        createSampleSuite(benchmarks: [entry]).saveToFile(telemetryFile);

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'report',
          '-f',
          telemetryFile.path,
          '-o',
          markdownOut.path,
          '--title',
          'Custom Test Suite',
        ]);

        check(exitCode).equals(0);
        check(markdownOut.existsSync()).isTrue();
        final content = markdownOut.readAsStringSync();
        check(content).contains('Custom Test Suite');
        check(content).contains('report_workload');
      },
    );

    test('diff subcommand compares two JSON telemetry files', () async {
      final baseFile = File(d.path('base.json'));
      final curFile = File(d.path('cur.json'));
      final diffOut = File(d.path('diff.md'));

      final baseEntry = createSampleEntry(
        name: 'opt_task',
        metrics: createSampleMetrics(
          meanNs: 200.0,
          medianNs: 200.0,
          minNs: 190.0,
          maxNs: 210.0,
          stddevNs: 5.0,
          cv: 0.025,
          p95Ns: 205.0,
          p99Ns: 208.0,
          opsPerSec: 5000000.0,
        ),
        rawTrialsNs: const [190.0, 195.0, 200.0, 205.0, 210.0],
      );
      final curEntry = createSampleEntry(
        name: 'opt_task',
        metrics: createSampleMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 95.0,
          maxNs: 105.0,
          stddevNs: 3.0,
          cv: 0.03,
          p95Ns: 102.0,
          p99Ns: 104.0,
          opsPerSec: 10000000.0,
        ),
        rawTrialsNs: const [95.0, 98.0, 100.0, 102.0, 105.0],
      );

      createSampleSuite(benchmarks: [baseEntry]).saveToFile(baseFile);
      createSampleSuite(
        benchmarks: [curEntry],
        timestamp: '2026-08-30T01:00:00.000Z',
      ).saveToFile(curFile);

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'diff',
        '-b',
        baseFile.path,
        '-c',
        curFile.path,
        '-o',
        diffOut.path,
      ]);

      check(exitCode).equals(0);
      check(diffOut.existsSync()).isTrue();
      final diffContent = diffOut.readAsStringSync();
      check(diffContent).contains('opt_task');
      check(diffContent).contains('2.00x');
    });

    test('diff subcommand exits with error on missing baseline file', () async {
      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'diff',
        '-b',
        '/non_existent_path_base_123.json',
        '-c',
        '/non_existent_path_cur_123.json',
      ]);
      check(exitCode).not((it) => it.equals(0));
    });

    test('report subcommand exits with error on malformed JSON file', () async {
      await d.file('bad.json', '{ this is not valid json }').create();

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run(['report', '-f', d.path('bad.json')]);
      check(exitCode).not((it) => it.equals(0));
    });

    test('validate subcommand exits with error on invalid target', () async {
      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'validate',
        '-t',
        'invalid_target',
        'benchmark/',
      ]);
      check(exitCode).not((it) => it.equals(0));
    });

    test(
      'validate subcommand exits with usage error on non-Dart file target',
      () async {
        await d.file('bench.txt', 'text').create();
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run(['validate', d.path('bench.txt')]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test(
      'validate subcommand exits with noInput error on non-existent directory',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '/non_existent_bench_dir_123',
        ]);
        check(exitCode).equals(ExitCode.noInput.code);
      },
    );

    test(
      'validate subcommand exits with usage error on non-existent --d8-path',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '--d8-path',
          '/non_existent_d8_123',
        ]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test(
      'validate subcommand exits with usage error on non-existent --node-path',
      () async {
        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '--node-path',
          '/non_existent_node_123',
        ]);
        check(exitCode).equals(ExitCode.usage.code);
      },
    );

    test('BenchmarkEntry.copyWith updates group and isBaseline', () {
      final entry = createSampleEntry(
        name: 'test_bench',
        metrics: createSampleMetrics(
          minNs: 90.0,
          maxNs: 110.0,
          p95Ns: 105.0,
          p99Ns: 108.0,
        ),
      );

      final withGroup = entry.copyWith(
        coordinates: {'group': 'SDK1'},
        isBaseline: true,
      );
      check(withGroup.name).equals('test_bench');
      check(withGroup.target).equals('jit');
      check(withGroup.coordinates['group']).equals('SDK1');
      check(withGroup.isBaseline).isTrue();
      check(withGroup.key).equals('test_bench:jit:group=SDK1');

      final unchanged = withGroup.copyWith();
      check(unchanged.coordinates['group']).equals('SDK1');
      check(unchanged.isBaseline).isTrue();
    });

    test('validate subcommand exits with software error when target produces '
        'zero results', () async {
      final benchFile = writeEmptyBenchmark();

      final runner = BenchPressCommandRunner();
      final exitCode = await runner.run([
        'validate',
        '-t',
        'jit',
        benchFile.path,
      ]);
      check(exitCode).equals(ExitCode.software.code);
    });

    test(
      'validate subcommand preserves injected compiler and processRunner',
      () {
        const customSdk = DartSdk(customSdkPath: '/mock/sdk');
        const customCompiler = TargetCompiler(sdk: customSdk);
        const customRunner = BenchmarkProcessRunner(sdk: customSdk);

        final runner = BenchPressCommandRunner(
          sdk: customSdk,
          compiler: customCompiler,
          processRunner: customRunner,
        );

        final validateCmd = runner.commands['validate'] as ValidateCommand;
        check(validateCmd.sdk).equals(customSdk);
        check(identical(validateCmd.compiler, customCompiler)).isTrue();
        check(identical(validateCmd.processRunner, customRunner)).isTrue();
      },
    );

    test(
      'validate subcommand validates multiple targets in matrix execution',
      () async {
        final configFile = writeBenchPressYaml('''
matrix:
  axes:
    flag:
      - opt1
''');
        final benchFile = writeSyncBenchmark();

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '-c',
          configFile.path,
          '-t',
          'jit,aot',
          benchFile.path,
        ]);
        check(exitCode).equals(0);
      },
    );

    test(
      'validate subcommand fails with software error when matrix target fails',
      () async {
        final configFile = writeBenchPressYaml('''
matrix:
  axes:
    mode:
      - fast
''');
        final benchFile = writeBrokenBenchmark();

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '-c',
          configFile.path,
          '-t',
          'jit',
          benchFile.path,
        ]);
        check(exitCode).equals(ExitCode.software.code);
      },
    );
  });
}
