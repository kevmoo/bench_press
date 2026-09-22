import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('BenchmarkProcessRunner', () {
    test(
      'executes JIT benchmark and extracts suite result from json-output',
      () async {
        final sourceFile = writeSyncBenchmark(
          fileName: 'simple_bench.dart',
          className: 'SyncBench',
          name: 'sync_bench',
        );

        final result = await compileAndExecute(sourceFile);

        check(result.success).isTrue();
        check(result.runtime).equals(TargetRuntime.jit);
        check(result.suiteResult).isNotNull();
        check(result.suiteResult!.benchmarks.length).equals(1);
        check(result.suiteResult!.benchmarks.first.name).equals('sync_bench');
        check(result.suiteResult!.benchmarks.first.samples).equals(2);
        check(result.exitCode).equals(0);
      },
    );

    test('executes JIT benchmark in isolate mode', () async {
      final sourceFile = writeSyncBenchmark(
        fileName: 'isolate_bench.dart',
        className: 'IsolateBench',
        name: 'isolate_bench',
        body: 'Blackhole.consume(2);',
      );

      final result = await compileAndExecute(sourceFile, isolateMode: true);

      check(result.success).isTrue();
      check(result.suiteResult).isNotNull();
      check(result.suiteResult!.benchmarks.first.name).equals('isolate_bench');
    });

    test(
      'captures unhandled exception and stack trace in isolate mode',
      () async {
        await d.file('failing_isolate_bench.dart', '''
void main(List<String> args) {
  throw StateError('Simulated isolate crash');
}
''').create();

        final result = await compileAndExecute(
          File(d.path('failing_isolate_bench.dart')),
          isolateMode: true,
          trials: 1,
          forceRun: false,
        );

        check(result.success).isFalse();
        check(result.exitCode).equals(1);
        check(result.errorMessage).isNotNull();
        check(result.errorMessage!).contains('Unhandled isolate exception');
        check(result.errorMessage!).contains('Simulated isolate crash');
        check(result.stderr).contains('Unhandled isolate exception');
        check(result.stderr).contains('Simulated isolate crash');
      },
    );

    test('captures stderr and failure when benchmark crashes', () async {
      await d.file('failing_bench.dart', '''
void main(List<String> args) {
  throw StateError('Simulated process crash');
}
''').create();

      final result = await compileAndExecute(
        File(d.path('failing_bench.dart')),
        trials: 1,
        forceRun: false,
      );

      check(result.success).isFalse();
      check(result.exitCode).not((it) => it.equals(0));
      check(result.errorMessage).isNotNull();
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
        final compilation = createMockCompilationResult(
          success: false,
          runtime: TargetRuntime.aot,
          artifactPath: null,
          runnerScriptPath: null,
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
      final sourceFile = writeSyncBenchmark(
        fileName: 'aot_bench.dart',
        className: 'AotBench',
        name: 'aot_bench',
      );

      final result = await compileAndExecute(
        sourceFile,
        runtime: TargetRuntime.aot,
      );

      check(result.success).isTrue();
      check(result.runtime).equals(TargetRuntime.aot);
      check(result.suiteResult).isNotNull();
      check(result.suiteResult!.benchmarks.first.name).equals('aot_bench');
    });

    test('executes Wasm/JS benchmark using discovered runner', () async {
      writeMockRunnerScript(
        executableName: 'node',
        benchmarkName: 'mock_wasm_bench',
      );

      final compilation = createMockCompilationResult();
      final runner = BenchmarkProcessRunner(
        sdk: DartSdk(environment: {'PATH': d.sandbox}),
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
    });

    test(
      'prioritizes customD8Path over ambient Node on PATH for Wasm and JS',
      () async {
        writeMockRunnerScript(
          executableName: 'node',
          benchmarkName: 'ran_with_node',
        );
        final mockD8 = writeMockRunnerScript(
          executableName: 'my_d8',
          benchmarkName: 'ran_with_d8',
          meanNs: 25.0,
        );

        final compilation = createMockCompilationResult();
        final runnerWithD8Override = BenchmarkProcessRunner(
          sdk: DartSdk(
            customD8Path: mockD8.path,
            environment: {'PATH': d.sandbox},
          ),
        );

        if (!Platform.isWindows) {
          final result = await runnerWithD8Override.execute(
            compilationResult: compilation,
            trials: 2,
            forceRun: true,
          );

          check(result.success).isTrue();
          check(result.suiteResult).isNotNull();
          check(result.suiteResult!.benchmarks.first.name)
              .equals('ran_with_d8');
        }
      },
    );

    test(
      'throws StateError or failure when runner is missing for Wasm',
      () async {
        final compilation = createMockCompilationResult();
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
        final compilation = createMockCompilationResult(
          runtime: TargetRuntime.js,
          artifactPath: '/path/to/bench.js',
          runnerScriptPath: '/path/to/bench.js',
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
      final compilation = createMockCompilationResult(
        runtime: TargetRuntime.jit,
        artifactPath: '/path/to/bench.dart',
        runnerScriptPath: null,
      );

      const runner = BenchmarkProcessRunner();
      final result = await runner.execute(
        compilationResult: compilation,
        workingDirectory: '/non_existent_working_dir_54321',
      );

      check(result.success).isFalse();
      check(result.errorMessage).isNotNull();
    });

    test('returns failure with explicitSdkError for JIT execution when '
        'customSdkPath is invalid instead of falling back to PATH', () async {
      final compilation = createMockCompilationResult(
        runtime: TargetRuntime.jit,
        artifactPath: '/path/to/bench.dart',
        runnerScriptPath: null,
      );
      final invalidSdkPath = d.path('non_existent_sdk_root');
      final runner = BenchmarkProcessRunner(
        sdk: DartSdk(customSdkPath: invalidSdkPath),
      );

      final result = await runner.execute(compilationResult: compilation);

      check(result.success).isFalse();
      check(result.errorMessage).isNotNull();
      check(result.errorMessage!).contains(invalidSdkPath);
    });
  });
}
