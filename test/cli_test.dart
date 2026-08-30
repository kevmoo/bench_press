import 'dart:convert';
import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('CLI End-to-End Execution', () {
    test(
      'dart run bin/bench_press.dart executes run and emits valid JSON',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('cli_e2e_');
        try {
          final benchFile = File(p.join(tempDir.path, 'e2e_bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class E2EBenchmark extends Benchmark {
  E2EBenchmark() : super('e2e_calc');
  @override
  void run() {
    Blackhole.consume(999);
  }
}

void main(List<String> args) => mainBenchmark(E2EBenchmark(), args);
''');

          final resultsFile = File(p.join(tempDir.path, 'e2e_results.json'));

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

          // Test JSON format output flag
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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('fail-on-unstable flag exits with code 2 when unstable benchmark '
        'is detected', () async {
      final tempDir = Directory.systemTemp.createTempSync('unstable_e2e_');
      try {
        // Create an existing telemetry file containing an unstable benchmark
        final resultsFile = File(p.join(tempDir.path, 'unstable_results.json'));
        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        const unstableMetrics = BenchmarkMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 90.0,
          maxNs: 110.0,
          stddevNs: 10.0,
          cv: 0.1,
          p95Ns: 108.0,
          p99Ns: 109.0,
          opsPerSec: 10000000.0,
          isStable: false, // Unstable flag
        );

        const entry = BenchmarkEntry(
          name: 'jitter_bench',
          target: 'jit',
          mode: 'sync',
          samples: 5,
          metrics: unstableMetrics,
        );

        final suite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [entry],
        );
        suite.saveToFile(resultsFile);

        final benchFile = File(p.join(tempDir.path, 'noop_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class NoopBench extends Benchmark {
  NoopBench() : super('noop');
  @override
  void run() => Blackhole.consume(0);
}

void main(List<String> args) => mainBenchmark(NoopBench(), args);
''');

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

        // Returns exit code 2 due to unstable benchmark in accumulated suite
        check(code).equals(2);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
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
        final tempDir = Directory.systemTemp.createTempSync('cli_group_e2e_');
        try {
          final benchFile = File(p.join(tempDir.path, 'group_bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final BenchmarkGroup stringGroup = BenchmarkGroup('String Construction', [
  BenchmarkVariant('concat', () => Blackhole.consume(1), isBaseline: true),
  BenchmarkVariant('buffer', () => Blackhole.consume(2)),
]);

final List<Object> benchmarks = [stringGroup];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
''');

          final resultsFile = File(p.join(tempDir.path, 'group_results.json'));

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
            benchFile.path,
          ]);

          check(result.exitCode).equals(0);
          check(resultsFile.existsSync()).isTrue();

          final stdout = result.stdout.toString();
          check(stdout).contains('### Group: String Construction (`jit`)');
          check(stdout).contains('`concat` (Baseline)');
          check(stdout).contains('`buffer`');
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'CLI executes run --diff with baseline.json and renders delta table',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('cli_diff_e2e_');
        try {
          final baseFile = File(p.join(tempDir.path, 'baseline.json'));
          const env = EnvironmentInfo(
            dartVersion: '3.14.0',
            os: 'linux',
            arch: 'x64',
          );

          const baseMetrics = BenchmarkMetrics(
            meanNs: 500.0,
            medianNs: 500.0,
            minNs: 480.0,
            maxNs: 520.0,
            stddevNs: 5.0,
            cv: 0.01,
            p95Ns: 510.0,
            p99Ns: 515.0,
            opsPerSec: 2000000.0,
            isStable: true,
          );

          const baseEntry = BenchmarkEntry(
            name: 'diff_cli_workload',
            target: 'jit',
            mode: 'sync',
            samples: 3,
            metrics: baseMetrics,
            rawTrialsNs: [490.0, 500.0, 510.0],
          );

          final baseSuite = BenchmarkSuiteResult(
            version: currentTelemetrySchemaVersion,
            timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
            environment: env,
            benchmarks: [baseEntry],
          );
          baseSuite.saveToFile(baseFile);

          final benchFile = File(p.join(tempDir.path, 'diff_bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class DiffCliBenchmark extends Benchmark {
  DiffCliBenchmark() : super('diff_cli_workload');
  @override
  void run() => Blackhole.consume(1234);
}

void main(List<String> args) => mainBenchmark(DiffCliBenchmark(), args);
''');

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
