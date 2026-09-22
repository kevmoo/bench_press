import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('TargetCompiler', () {
    test(
      'JIT compilation returns instant success pointing to source',
      () async {
        await d.file('dummy.dart', 'void main() {}').create();
        final dummySource = File(d.path('dummy.dart'));

        const compiler = TargetCompiler();
        final result = await compiler.compile(
          sourceFile: dummySource,
          runtime: TargetRuntime.jit,
        );

        check(result.success).isTrue();
        check(result.runtime).equals(TargetRuntime.jit);
        check(result.artifactPath)
            .equals(p.normalize(dummySource.absolute.path));
        check(result.runnerScriptPath).isNull();
        check(result.exitCode).equals(0);
      },
    );

    test('AOT compilation builds standalone binary', () async {
      final sourceFile = writeSyncBenchmark(
        fileName: 'simple_bench.dart',
        className: 'FastBenchmark',
        name: 'fast',
      );

      const compiler = TargetCompiler();
      final outDir = Directory(d.path('bin'));

      final result = await compiler.compile(
        sourceFile: sourceFile,
        runtime: TargetRuntime.aot,
        outputDir: outDir,
      );

      check(result.success).isTrue();
      check(result.artifactPath).isNotNull();
      check(File(result.artifactPath!).existsSync()).isTrue();
      check(result.exitCode).equals(0);
    });

    test('JS compilation builds javascript artifact', () async {
      final sourceFile = writeSyncBenchmark(
        fileName: 'simple_js.dart',
        className: 'JsBenchmark',
        name: 'js_bench',
        body: 'Blackhole.consume(2);',
      );

      const compiler = TargetCompiler();
      final outDir = Directory(d.path('js_out'));

      final result = await compiler.compile(
        sourceFile: sourceFile,
        runtime: TargetRuntime.js,
        outputDir: outDir,
      );

      check(result.success).isTrue();
      check(result.artifactPath).isNotNull();
      check(File(result.artifactPath!).existsSync()).isTrue();
      check(result.runnerScriptPath).isNotNull();
      check(result.runnerScriptPath)
          .not((it) => it.equals(result.artifactPath));
      check(result.runnerScriptPath!).endsWith('.node.cjs');
      check(File(result.runnerScriptPath!).existsSync()).isTrue();
      check(File(result.runnerScriptPath!).readAsStringSync())
          .contains('globalThis.self');
    });

    test(
      'WASM compilation builds wasm artifact and .run.mjs wrapper',
      () async {
        final sourceFile = writeSyncBenchmark(
          fileName: 'simple_wasm.dart',
          className: 'WasmBenchmark',
          name: 'wasm_bench',
          body: 'Blackhole.consume(3);',
        );

        const compiler = TargetCompiler();
        final outDir = Directory(d.path('wasm_out'));

        final result = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.wasm,
          outputDir: outDir,
        );

        check(result.success).isTrue();
        check(result.artifactPath).isNotNull();
        check(File(result.artifactPath!).existsSync()).isTrue();
        check(result.runnerScriptPath).isNotNull();
        check(result.runnerScriptPath)
            .not((it) => it.equals(result.artifactPath));
        check(result.runnerScriptPath!).endsWith('.run.mjs');
        check(File(result.runnerScriptPath!).existsSync()).isTrue();
        check(File(result.runnerScriptPath!).readAsStringSync())
            .contains('instantiatedApp.invokeMain');
      },
    );

    test('compiled JS benchmark executes cleanly under Node.js with '
        'package.json type: module', () async {
      const sdk = DartSdk();
      if (sdk.nodeExecutable == null) return;

      await d.file('package.json', '{"type": "module"}').create();
      final sourceFile = writeSyncBenchmark(
        fileName: 'exec_js.dart',
        className: 'SimpleJsBenchmark',
        name: 'simple_js',
        body: 'Blackhole.consume(42);',
      );

      const compiler = TargetCompiler();
      final outDir = Directory(d.path('js_out'));

      final compileResult = await compiler.compile(
        sourceFile: sourceFile,
        runtime: TargetRuntime.js,
        outputDir: outDir,
      );

      check(compileResult.success).isTrue();
      check(compileResult.runnerScriptPath).isNotNull();

      const runner = BenchmarkProcessRunner(sdk: sdk);
      final runResult = await runner.execute(
        compilationResult: compileResult,
        validate: true,
      );

      check(runResult.success).isTrue();
      check(runResult.exitCode).equals(0);
      check(runResult.suiteResult).isNotNull();
      check(runResult.suiteResult!.benchmarks).isNotEmpty();
    });

    test('compiled WASM benchmark executes cleanly under Node.js', () async {
      const sdk = DartSdk();
      if (sdk.nodeExecutable == null) return;

      final sourceFile = writeSyncBenchmark(
        fileName: 'exec_wasm.dart',
        className: 'SimpleWasmBenchmark',
        name: 'simple_wasm',
        body: 'Blackhole.consume(100);',
      );

      const compiler = TargetCompiler();
      final outDir = Directory(d.path('wasm_out'));

      final compileResult = await compiler.compile(
        sourceFile: sourceFile,
        runtime: TargetRuntime.wasm,
        outputDir: outDir,
      );

      check(compileResult.success).isTrue();
      check(compileResult.runnerScriptPath).isNotNull();

      const runner = BenchmarkProcessRunner(sdk: sdk);
      final runResult = await runner.execute(
        compilationResult: compileResult,
        validate: true,
      );

      check(runResult.success).isTrue();
      check(runResult.exitCode).equals(0);
      check(runResult.suiteResult).isNotNull();
      check(runResult.suiteResult!.benchmarks).isNotEmpty();
    });

    test('returns failure when SDK is not found', () async {
      await d.file('dummy.dart', 'void main() {}').create();

      const compiler = TargetCompiler(
        sdk: DartSdk(
          customSdkPath: '/non_existent_path',
          environment: {'PATH': ''},
        ),
      );

      final result = await compiler.compile(
        sourceFile: File(d.path('dummy.dart')),
        runtime: TargetRuntime.aot,
      );

      check(result.success).isFalse();
      // The configured path is the actual cause, so it must be named. The
      // previous message blamed PATH and DART_SDK, neither of which was
      // consulted once customSdkPath was supplied.
      check(result.stderr).contains('/non_existent_path');
    });

    test('CompilationResult toString produces descriptive output', () {
      const result = CompilationResult(
        success: true,
        runtime: TargetRuntime.aot,
        sourcePath: '/path/to/bench.dart',
        artifactPath: '/path/to/bench.exe',
        compilationDuration: Duration(milliseconds: 150),
        stdout: '',
        stderr: '',
        exitCode: 0,
      );

      check(result.toString()).contains('CompilationResult(aot');
      check(result.toString()).contains('success: true');
      check(result.toString()).contains('150ms');
    });

    test('returns failure when compiling invalid Dart source', () async {
      await d
          .file('invalid.dart', 'void main() { this is not valid dart syntax }')
          .create();

      const compiler = TargetCompiler();
      final result = await compiler.compile(
        sourceFile: File(d.path('invalid.dart')),
        runtime: TargetRuntime.aot,
      );

      check(result.success).isFalse();
      check(result.exitCode).not((it) => it.equals(0));
      check(result.artifactPath).isNull();
      check(result.stderr).isNotEmpty();
    });

    test('compile handles execution exception gracefully', () async {
      await d.file('dummy.dart', 'void main() {}').create();

      const compiler = TargetCompiler();
      final result = await compiler.compile(
        sourceFile: File(d.path('dummy.dart')),
        runtime: TargetRuntime.aot,
        workingDirectory: '/non_existent_working_dir_12345',
      );

      check(result.success).isFalse();
      check(result.stderr).contains('Compiler execution failed');
    });

    test('compile passes extra compilerFlags', () async {
      final source = writeSyncBenchmark(
        fileName: 'flagged_bench.dart',
        className: 'FlagBench',
        name: 'flag_bench',
      );

      const compiler = TargetCompiler();
      final result = await compiler.compile(
        sourceFile: source,
        runtime: TargetRuntime.aot,
        compilerFlags: ['--define=CUSTOM_DEFINE=true'],
      );

      check(result.success).isTrue();
    });

    test('compilation caching caches artifact, hits cache on repeat, '
        'invalidates on source edit, and respects useCache: false', () async {
      final source = writeSyncBenchmark(
        fileName: 'cache_bench.dart',
        className: 'CacheBench',
        name: 'cache_bench',
      );

      const compiler = TargetCompiler();
      final outDir = Directory(d.path('out'));

      final result1 = await compiler.compile(
        sourceFile: source,
        runtime: TargetRuntime.aot,
        outputDir: outDir,
      );
      check(result1.success).isTrue();
      check(result1.cacheHit).isFalse();
      check(result1.artifactPath).isNotNull();
      check(File(result1.artifactPath!).existsSync()).isTrue();

      final result2 = await compiler.compile(
        sourceFile: source,
        runtime: TargetRuntime.aot,
        outputDir: outDir,
      );
      check(result2.success).isTrue();
      check(result2.cacheHit).isTrue();
      check(result2.compilationDuration).equals(Duration.zero);
      check(result2.artifactPath).isNotNull();
      check(File(result2.artifactPath!).existsSync()).isTrue();

      const runner = BenchmarkProcessRunner();
      final execResult = await runner.execute(
        compilationResult: result2,
        validate: true,
      );
      check(execResult.success).isTrue();

      final result3 = await compiler.compile(
        sourceFile: source,
        runtime: TargetRuntime.aot,
        outputDir: outDir,
        useCache: false,
      );
      check(result3.success).isTrue();
      check(result3.cacheHit).isFalse();

      writeSyncBenchmark(
        fileName: 'cache_bench.dart',
        className: 'CacheBench',
        name: 'cache_bench_modified',
        body: 'Blackhole.consume(2);',
      );
      final result4 = await compiler.compile(
        sourceFile: source,
        runtime: TargetRuntime.aot,
        outputDir: outDir,
      );
      check(result4.success).isTrue();
      check(result4.cacheHit).isFalse();
    });
  });
}
