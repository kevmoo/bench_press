import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('BenchPressCommandRunner', () {
    test('--version flag prints version and exits cleanly', () async {
      final runner = BenchPressCommandRunner();
      final code = await runner.run(['--version']);
      check(code).equals(0);
    });

    test('--help prints available commands and usage', () async {
      final runner = BenchPressCommandRunner();
      final code = await runner.run(['--help']);
      check(code).equals(0);
    });

    test(
      'run subcommand executes benchmarks and saves json telemetry',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('runner_test_');
        try {
          final benchDir = Directory(p.join(tempDir.path, 'benchmark'))
            ..createSync();
          final benchFile = File(p.join(benchDir.path, 'calc_bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class CalcBenchmark extends Benchmark {
  CalcBenchmark() : super('calc_workload');
  @override
  void run() {
    var x = 0;
    for (var i = 0; i < 10; i++) {
      x += i;
    }
    Blackhole.consumeInt(x);
  }
}

void main(List<String> args) => mainBenchmark(CalcBenchmark(), args);
''');

          final outputFile = File(p.join(tempDir.path, 'results.json'));
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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('validate subcommand conducts fast smoke test', () async {
      final tempDir = Directory.systemTemp.createTempSync('validate_test_');
      try {
        final benchFile = File(p.join(tempDir.path, 'smoke_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class SmokeBenchmark extends Benchmark {
  SmokeBenchmark() : super('smoke');
  @override
  void run() {
    Blackhole.consume(123);
  }
}

void main(List<String> args) => mainBenchmark(SmokeBenchmark(), args);
''');

        final runner = BenchPressCommandRunner();
        final exitCode = await runner.run([
          'validate',
          '-t',
          'jit',
          benchFile.path,
        ]);

        check(exitCode).equals(0);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'report subcommand renders markdown report from stored JSON',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('report_test_');
        try {
          final telemetryFile = File(p.join(tempDir.path, 'suite.json'));
          final markdownOut = File(p.join(tempDir.path, 'report.md'));

          const env = EnvironmentInfo(
            dartVersion: '3.14.0',
            os: 'linux',
            arch: 'x64',
          );

          const metrics = BenchmarkMetrics(
            meanNs: 100.0,
            medianNs: 100.0,
            minNs: 95.0,
            maxNs: 110.0,
            stddevNs: 5.0,
            cv: 0.05,
            p95Ns: 108.0,
            p99Ns: 109.0,
            opsPerSec: 10000000.0,
            isStable: true,
          );

          const entry = BenchmarkEntry(
            name: 'report_workload',
            target: 'jit',
            mode: 'sync',
            samples: 5,
            metrics: metrics,
          );

          final suite = BenchmarkSuiteResult(
            version: currentTelemetrySchemaVersion,
            timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
            environment: env,
            benchmarks: [entry],
          );
          suite.saveToFile(telemetryFile);

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('diff subcommand compares two JSON telemetry files', () async {
      final tempDir = Directory.systemTemp.createTempSync('diff_test_');
      try {
        final baseFile = File(p.join(tempDir.path, 'base.json'));
        final curFile = File(p.join(tempDir.path, 'cur.json'));
        final diffOut = File(p.join(tempDir.path, 'diff.md'));

        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        const baseMetrics = BenchmarkMetrics(
          meanNs: 200.0,
          medianNs: 200.0,
          minNs: 190.0,
          maxNs: 210.0,
          stddevNs: 5.0,
          cv: 0.025,
          p95Ns: 205.0,
          p99Ns: 208.0,
          opsPerSec: 5000000.0,
          isStable: true,
        );

        const curMetrics = BenchmarkMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 95.0,
          maxNs: 105.0,
          stddevNs: 3.0,
          cv: 0.03,
          p95Ns: 102.0,
          p99Ns: 104.0,
          opsPerSec: 10000000.0,
          isStable: true,
        );

        const baseEntry = BenchmarkEntry(
          name: 'opt_task',
          target: 'jit',
          mode: 'sync',
          samples: 5,
          metrics: baseMetrics,
          rawTrialsNs: [190.0, 195.0, 200.0, 205.0, 210.0],
        );

        const curEntry = BenchmarkEntry(
          name: 'opt_task',
          target: 'jit',
          mode: 'sync',
          samples: 5,
          metrics: curMetrics,
          rawTrialsNs: [95.0, 98.0, 100.0, 102.0, 105.0],
        );

        final baseSuite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [baseEntry],
        );
        baseSuite.saveToFile(baseFile);

        final curSuite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
          environment: env,
          benchmarks: [curEntry],
        );
        curSuite.saveToFile(curFile);

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
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('run subcommand executes BenchmarkGroup and records groups', () async {
      final tempDir = Directory.systemTemp.createTempSync('group_runner_test_');
      try {
        final benchFile = File(p.join(tempDir.path, 'group_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final BenchmarkGroup stringGroup = BenchmarkGroup('String Group', [
  BenchmarkVariant('concat', () => Blackhole.consume(1), isBaseline: true),
  BenchmarkVariant('buffer', () => Blackhole.consume(2)),
]);

final List<Object> benchmarks = [stringGroup];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
''');

        final outputFile = File(p.join(tempDir.path, 'group_results.json'));
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
          benchFile.path,
        ]);

        check(exitCode).equals(0);
        check(outputFile.existsSync()).isTrue();

        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.length).equals(2);
        check(suite.groups).contains('String Group');

        final concat = suite.findEntry('concat', 'jit');
        check(concat).isNotNull();
        check(concat!.isBaseline).isTrue();
        check(concat.group).equals('String Group');

        final buffer = suite.findEntry('buffer', 'jit');
        check(buffer).isNotNull();
        check(buffer!.isBaseline).isFalse();
        check(buffer.group).equals('String Group');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'run subcommand with --diff against baseline JSON file renders delta',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('diff_run_test_');
        try {
          final baseFile = File(p.join(tempDir.path, 'baseline.json'));
          const env = EnvironmentInfo(
            dartVersion: '3.14.0',
            os: 'linux',
            arch: 'x64',
          );
          const baseEntry = BenchmarkEntry(
            name: 'diff_target',
            target: 'jit',
            mode: 'sync',
            samples: 5,
            metrics: BenchmarkMetrics(
              meanNs: 1000.0,
              medianNs: 1000.0,
              minNs: 950.0,
              maxNs: 1050.0,
              stddevNs: 10.0,
              cv: 0.01,
              p95Ns: 1020.0,
              p99Ns: 1040.0,
              opsPerSec: 1000000.0,
              isStable: true,
            ),
            rawTrialsNs: [980.0, 1000.0, 1020.0],
          );
          final baseSuite = BenchmarkSuiteResult(
            version: currentTelemetrySchemaVersion,
            timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
            environment: env,
            benchmarks: [baseEntry],
          );
          baseSuite.saveToFile(baseFile);

          final benchFile = File(p.join(tempDir.path, 'bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class DiffTarget extends Benchmark {
  DiffTarget() : super('diff_target');
  @override
  void run() => Blackhole.consume(42);
}

void main(List<String> args) => mainBenchmark(DiffTarget(), args);
''');

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
