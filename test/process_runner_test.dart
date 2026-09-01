import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('BenchmarkProcessRunner', () {
    test(
      'executes JIT benchmark and extracts suite result from json-output',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('process_test_');
        try {
          final sourceFile = File(p.join(tempDir.path, 'simple_bench.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class SyncBench extends Benchmark {
  SyncBench() : super('sync_bench');
  @override
  void run() {
    Blackhole.consume(1);
  }
}

void main(List<String> args) => mainBenchmark(SyncBench(), args);
''');

          const compiler = TargetCompiler();
          final compilation = await compiler.compile(
            sourceFile: sourceFile,
            runtime: TargetRuntime.jit,
          );

          const runner = BenchmarkProcessRunner();
          final result = await runner.execute(
            compilationResult: compilation,
            trials: 2,
            forceRun: true,
          );

          check(result.success).isTrue();
          check(result.runtime).equals(TargetRuntime.jit);
          check(result.suiteResult).isNotNull();
          check(result.suiteResult!.benchmarks.length).equals(1);
          check(result.suiteResult!.benchmarks.first.name).equals('sync_bench');
          check(result.suiteResult!.benchmarks.first.samples).equals(2);
          check(result.exitCode).equals(0);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('executes JIT benchmark in isolate mode', () async {
      final tempDir = Directory.systemTemp.createTempSync('isolate_test_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'isolate_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class IsolateBench extends Benchmark {
  IsolateBench() : super('isolate_bench');
  @override
  void run() {
    Blackhole.consume(2);
  }
}

void main(List<String> args) => mainBenchmark(IsolateBench(), args);
''');

        const compiler = TargetCompiler();
        final compilation = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.jit,
        );

        const runner = BenchmarkProcessRunner();
        final result = await runner.execute(
          compilationResult: compilation,
          isolateMode: true,
          trials: 2,
          forceRun: true,
        );

        check(result.success).isTrue();
        check(result.suiteResult).isNotNull();
        check(result.suiteResult!.benchmarks.first.name)
            .equals('isolate_bench');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'captures unhandled exception and stack trace in isolate mode',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'isolate_error_test_',
        );
        try {
          final sourceFile =
              File(p.join(tempDir.path, 'failing_isolate_bench.dart'))
                ..writeAsStringSync('''
void main(List<String> args) {
  throw StateError('Simulated isolate crash');
}
''');

          const compiler = TargetCompiler();
          final compilation = await compiler.compile(
            sourceFile: sourceFile,
            runtime: TargetRuntime.jit,
          );

          const runner = BenchmarkProcessRunner();
          final result = await runner.execute(
            compilationResult: compilation,
            isolateMode: true,
            trials: 1,
          );

          check(result.success).isFalse();
          check(result.exitCode).equals(1);
          check(result.errorMessage).isNotNull();
          check(result.errorMessage!).contains('Unhandled isolate exception');
          check(result.errorMessage!).contains('Simulated isolate crash');
          check(result.stderr).contains('Unhandled isolate exception');
          check(result.stderr).contains('Simulated isolate crash');
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('captures stderr and failure when benchmark crashes', () async {
      final tempDir = Directory.systemTemp.createTempSync('failing_proc_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'failing_bench.dart'))
          ..writeAsStringSync('''
void main(List<String> args) {
  throw StateError('Simulated process crash');
}
''');

        const compiler = TargetCompiler();
        final compilation = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.jit,
        );

        const runner = BenchmarkProcessRunner();
        final result = await runner.execute(
          compilationResult: compilation,
          trials: 1,
        );

        check(result.success).isFalse();
        check(result.exitCode).not((it) => it.equals(0));
        check(result.errorMessage).isNotNull();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('ProcessExecutionResult toString produces descriptive output', () {
      const result = ProcessExecutionResult(
        success: true,
        runtime: TargetRuntime.jit,
        exitCode: 0,
        executionDuration: Duration(milliseconds: 200),
        stdout: '',
        stderr: '',
      );

      check(result.toString()).contains('ProcessExecutionResult(jit');
      check(result.toString()).contains('success: true');
      check(result.toString()).contains('200ms');
    });

    test(
      'returns failure immediately for uncompiled compilation result',
      () async {
        const compilation = CompilationResult(
          success: false,
          runtime: TargetRuntime.aot,
          sourcePath: '/path/to/bench.dart',
          compilationDuration: Duration.zero,
          stdout: '',
          stderr: 'Compilation failed',
          exitCode: 1,
        );

        const runner = BenchmarkProcessRunner();
        final result = await runner.execute(compilationResult: compilation);

        check(result.success).isFalse();
        check(result.exitCode).equals(1);
        check(result.errorMessage)
            .equals('Cannot execute uncompiled or failed target.');
      },
    );

    test('executes AOT compiled benchmark', () async {
      final tempDir = Directory.systemTemp.createTempSync('aot_proc_test_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'aot_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class AotBench extends Benchmark {
  AotBench() : super('aot_bench');
  @override
  void run() => Blackhole.consume(1);
}

void main(List<String> args) => mainBenchmark(AotBench(), args);
''');

        const compiler = TargetCompiler();
        final compilation = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.aot,
        );

        const runner = BenchmarkProcessRunner();
        final result = await runner.execute(
          compilationResult: compilation,
          trials: 2,
          forceRun: true,
        );

        check(result.success).isTrue();
        check(result.runtime).equals(TargetRuntime.aot);
        check(result.suiteResult).isNotNull();
        check(result.suiteResult!.benchmarks.first.name).equals('aot_bench');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('executes Wasm/JS benchmark using discovered runner', () async {
      final tempDir = Directory.systemTemp.createTempSync('mock_runner_test_');
      try {
        final mockNode = File(p.join(tempDir.path, 'node'))
          ..writeAsStringSync(r'''#!/bin/sh
cat << 'END_OF_JSON'
<<<BENCH_PRESS_JSON_START>>>
{
  "version": 1,
  "timestamp": "2026-08-30T00:00:00.000Z",
  "environment": {"dart_version": "3.14.0", "os": "linux", "arch": "x64"},
  "benchmarks": [
    {
      "name": "mock_wasm_bench",
      "target": "wasm",
      "mode": "sync",
      "samples": 2,
      "metrics": {
        "mean_ns": 50.0,
        "median_ns": 50.0,
        "min_ns": 45.0,
        "max_ns": 55.0,
        "stddev_ns": 2.0,
        "cv": 0.04,
        "p95_ns": 54.0,
        "p99_ns": 55.0,
        "ops_per_sec": 20000000.0,
        "is_stable": true
      }
    }
  ]
}
<<<BENCH_PRESS_JSON_END>>>
END_OF_JSON
exit 0
''');
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['+x', mockNode.path]);
        }

        const compilation = CompilationResult(
          success: true,
          runtime: TargetRuntime.wasm,
          sourcePath: '/path/to/bench.dart',
          artifactPath: '/path/to/bench.wasm',
          runnerScriptPath: '/path/to/bench.mjs',
          compilationDuration: Duration.zero,
          stdout: '',
          stderr: '',
          exitCode: 0,
        );

        final runner = BenchmarkProcessRunner(
          sdk: DartSdk(environment: {'PATH': tempDir.path}),
        );

        if (!Platform.isWindows) {
          final result = await runner.execute(
            compilationResult: compilation,
            trials: 2,
            forceRun: true,
          );

          check(result.success).isTrue();
          check(result.runtime).equals(TargetRuntime.wasm);
          check(result.suiteResult).isNotNull();
          check(result.suiteResult!.benchmarks.first.name)
              .equals('mock_wasm_bench');
        }
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'throws StateError or failure when runner is missing for Wasm',
      () async {
        const compilation = CompilationResult(
          success: true,
          runtime: TargetRuntime.wasm,
          sourcePath: '/path/to/bench.dart',
          artifactPath: '/path/to/bench.wasm',
          runnerScriptPath: '/path/to/bench.mjs',
          compilationDuration: Duration.zero,
          stdout: '',
          stderr: '',
          exitCode: 0,
        );

        const runner = BenchmarkProcessRunner(
          sdk: DartSdk(environment: {'PATH': ''}),
        );

        final result = await runner.execute(compilationResult: compilation);
        check(result.success).isFalse();
        check(result.errorMessage).isNotNull();
        check(result.errorMessage!).contains('No Wasm runner');
      },
    );

    test(
      'throws StateError or failure when runner is missing for JS',
      () async {
        const compilation = CompilationResult(
          success: true,
          runtime: TargetRuntime.js,
          sourcePath: '/path/to/bench.dart',
          artifactPath: '/path/to/bench.js',
          runnerScriptPath: '/path/to/bench.js',
          compilationDuration: Duration.zero,
          stdout: '',
          stderr: '',
          exitCode: 0,
        );

        const runner = BenchmarkProcessRunner(
          sdk: DartSdk(environment: {'PATH': ''}),
        );

        final result = await runner.execute(compilationResult: compilation);
        check(result.success).isFalse();
        check(result.errorMessage).isNotNull();
        check(result.errorMessage!).contains('No JavaScript runner');
      },
    );

    test('handles execution exception gracefully', () async {
      const compilation = CompilationResult(
        success: true,
        runtime: TargetRuntime.jit,
        sourcePath: '/path/to/bench.dart',
        artifactPath: '/path/to/bench.dart',
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: '',
        exitCode: 0,
      );

      const runner = BenchmarkProcessRunner();
      final result = await runner.execute(
        compilationResult: compilation,
        workingDirectory: '/non_existent_working_dir_54321',
      );

      check(result.success).isFalse();
      check(result.errorMessage).isNotNull();
    });
  });
}
