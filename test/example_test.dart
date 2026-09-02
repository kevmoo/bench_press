import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Example & CLI Entrypoint Smoke Tests', () {
    test('bin/bench_press.dart runs with --version', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'bin/bench_press.dart',
        '--version',
      ]);

      check(result.exitCode).equals(0);
      check(result.stdout.toString()).contains('bench_press');
    });

    test('bin/bench_press.dart runs with --help', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'bin/bench_press.dart',
        '--help',
      ]);

      check(result.exitCode).equals(0);
      check(result.stdout.toString()).contains('A modern, statistically sound');
    });

    test(
      'example/bench_press_example.dart executes standalone demonstrations',
      () async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'example/bench_press_example.dart',
        ]);

        check(result.exitCode).equals(0);
        final output = result.stdout.toString();
        check(output).contains('=== Running Standalone Benchmark Reports ===');
        check(output).contains('Benchmark: fibonacci_recursive');
        check(output).contains('Benchmark: async_microtask_batch');
        check(output).contains('=== Model 1: BenchmarkGroup Results ===');
        check(output).contains('plus_concat (Baseline)');
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}
