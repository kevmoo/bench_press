import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('TargetCompiler', () {
    test(
      'JIT compilation returns instant success pointing to source',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('compiler_jit_');
        try {
          final dummySource = File(p.join(tempDir.path, 'dummy.dart'))
            ..writeAsStringSync('void main() {}');

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('AOT compilation builds standalone binary', () async {
      final tempDir = Directory.systemTemp.createTempSync('compiler_aot_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'simple_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class FastBenchmark extends Benchmark {
  FastBenchmark() : super('fast');
  @override
  void run() {
    Blackhole.consume(1);
  }
}

void main(List<String> args) => mainBenchmark(FastBenchmark(), args);
''');

        const compiler = TargetCompiler();
        final outDir = Directory(p.join(tempDir.path, 'bin'));

        final result = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.aot,
          outputDir: outDir,
        );

        check(result.success).isTrue();
        check(result.artifactPath).isNotNull();
        check(File(result.artifactPath!).existsSync()).isTrue();
        check(result.exitCode).equals(0);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('JS compilation builds javascript artifact', () async {
      final tempDir = Directory.systemTemp.createTempSync('compiler_js_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'simple_js.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class JsBenchmark extends Benchmark {
  JsBenchmark() : super('js_bench');
  @override
  void run() {
    Blackhole.consume(2);
  }
}

void main(List<String> args) => mainBenchmark(JsBenchmark(), args);
''');

        const compiler = TargetCompiler();
        final outDir = Directory(p.join(tempDir.path, 'js_out'));

        final result = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.js,
          outputDir: outDir,
        );

        check(result.success).isTrue();
        check(result.artifactPath).isNotNull();
        check(File(result.artifactPath!).existsSync()).isTrue();
        // The runner is a `.node.cjs` wrapper, not the compiled artifact
        // itself — `dart compile js` output assumes a browser/worker `self`
        // global for microtask/timer scheduling, absent under Node, so the
        // wrapper polyfills it before requiring the real artifact.
        check(result.runnerScriptPath).isNotNull();
        check(result.runnerScriptPath)
            .not((it) => it.equals(result.artifactPath));
        check(result.runnerScriptPath!).endsWith('.node.cjs');
        check(File(result.runnerScriptPath!).existsSync()).isTrue();
        check(File(result.runnerScriptPath!).readAsStringSync())
            .contains('globalThis.self');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'WASM compilation builds wasm artifact and .run.mjs wrapper',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('compiler_wasm_');
        try {
          final sourceFile = File(p.join(tempDir.path, 'simple_wasm.dart'))
            ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class WasmBenchmark extends Benchmark {
  WasmBenchmark() : super('wasm_bench');
  @override
  void run() {
    Blackhole.consume(3);
  }
}

void main(List<String> args) => mainBenchmark(WasmBenchmark(), args);
''');

          const compiler = TargetCompiler();
          final outDir = Directory(p.join(tempDir.path, 'wasm_out'));

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
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('compiled JS benchmark executes cleanly under Node.js with '
        'package.json type: module', () async {
      final sdk = const DartSdk();
      if (sdk.nodeExecutable == null) return;

      final tempDir = Directory.systemTemp.createTempSync('compiler_js_exec_');
      try {
        // Verify that .node.cjs works even when a parent directory has
        // "type": "module".
        File(p.join(tempDir.path, 'package.json'))
            .writeAsStringSync('{"type": "module"}');

        final sourceFile = File(p.join(tempDir.path, 'exec_js.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class SimpleJsBenchmark extends Benchmark {
  SimpleJsBenchmark() : super('simple_js');
  @override
  void run() => Blackhole.consume(42);
}

void main(List<String> args) => mainBenchmark(SimpleJsBenchmark(), args);
''');

        const compiler = TargetCompiler();
        final outDir = Directory(p.join(tempDir.path, 'js_out'));

        final compileResult = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.js,
          outputDir: outDir,
        );

        check(compileResult.success).isTrue();
        check(compileResult.runnerScriptPath).isNotNull();

        final runner = BenchmarkProcessRunner(sdk: sdk);
        final runResult = await runner.execute(
          compilationResult: compileResult,
          validate: true,
        );

        check(runResult.success).isTrue();
        check(runResult.exitCode).equals(0);
        check(runResult.suiteResult).isNotNull();
        check(runResult.suiteResult!.benchmarks).isNotEmpty();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('compiled WASM benchmark executes cleanly under Node.js', () async {
      final sdk = const DartSdk();
      if (sdk.nodeExecutable == null) return;

      final tempDir = Directory.systemTemp.createTempSync(
        'compiler_wasm_exec_',
      );
      try {
        final sourceFile = File(p.join(tempDir.path, 'exec_wasm.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class SimpleWasmBenchmark extends Benchmark {
  SimpleWasmBenchmark() : super('simple_wasm');
  @override
  void run() => Blackhole.consume(100);
}

void main(List<String> args) => mainBenchmark(SimpleWasmBenchmark(), args);
''');

        const compiler = TargetCompiler();
        final outDir = Directory(p.join(tempDir.path, 'wasm_out'));

        final compileResult = await compiler.compile(
          sourceFile: sourceFile,
          runtime: TargetRuntime.wasm,
          outputDir: outDir,
        );

        check(compileResult.success).isTrue();
        check(compileResult.runnerScriptPath).isNotNull();

        final runner = BenchmarkProcessRunner(sdk: sdk);
        final runResult = await runner.execute(
          compilationResult: compileResult,
          validate: true,
        );

        check(runResult.success).isTrue();
        check(runResult.exitCode).equals(0);
        check(runResult.suiteResult).isNotNull();
        check(runResult.suiteResult!.benchmarks).isNotEmpty();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns failure when SDK is not found', () async {
      final tempDir = Directory.systemTemp.createTempSync('no_sdk_');
      try {
        final source = File(p.join(tempDir.path, 'dummy.dart'))
          ..writeAsStringSync('void main() {}');

        const compiler = TargetCompiler(
          sdk: DartSdk(
            customSdkPath: '/non_existent_path',
            environment: {'PATH': ''},
          ),
        );

        final result = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
        );

        check(result.success).isFalse();
        check(result.stderr).contains('Dart SDK executable not found');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
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
      final tempDir = Directory.systemTemp.createTempSync('invalid_dart_');
      try {
        final source = File(p.join(tempDir.path, 'invalid.dart'))
          ..writeAsStringSync('void main() { this is not valid dart syntax }');

        const compiler = TargetCompiler();
        final result = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
        );

        check(result.success).isFalse();
        check(result.exitCode).not((it) => it.equals(0));
        check(result.artifactPath).isNull();
        check(result.stderr).isNotEmpty();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('compile handles execution exception gracefully', () async {
      final tempDir = Directory.systemTemp.createTempSync('exception_test_');
      try {
        final source = File(p.join(tempDir.path, 'dummy.dart'))
          ..writeAsStringSync('void main() {}');

        const compiler = TargetCompiler();
        final result = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          workingDirectory: '/non_existent_working_dir_12345',
        );

        check(result.success).isFalse();
        check(result.stderr).contains('Compiler execution failed');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('compile passes extra compilerFlags', () async {
      final tempDir = Directory.systemTemp.createTempSync('flags_test_');
      try {
        final source = File(p.join(tempDir.path, 'flagged_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class FlagBench extends Benchmark {
  FlagBench() : super('flag_bench');
  @override
  void run() => Blackhole.consume(1);
}

void main(List<String> args) => mainBenchmark(FlagBench(), args);
''');

        const compiler = TargetCompiler();
        final result = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          compilerFlags: ['--define=CUSTOM_DEFINE=true'],
        );

        check(result.success).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('compilation caching caches artifact, hits cache on repeat, '
        'invalidates on source edit, and respects useCache: false', () async {
      final tempDir = Directory.systemTemp.createTempSync('cache_test_');
      try {
        final source = File(p.join(tempDir.path, 'cache_bench.dart'))
          ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class CacheBench extends Benchmark {
  CacheBench() : super('cache_bench');
  @override
  void run() => Blackhole.consume(1);
}

void main(List<String> args) => mainBenchmark(CacheBench(), args);
''');

        const compiler = TargetCompiler();
        final outDir1 = Directory(p.join(tempDir.path, 'out1'));

        // 1. First compilation -> cache miss (cacheHit: false)
        final result1 = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          outputDir: outDir1,
        );
        check(result1.success).isTrue();
        check(result1.cacheHit).isFalse();
        check(result1.artifactPath).isNotNull();
        check(File(result1.artifactPath!).existsSync()).isTrue();

        // 2. Second compilation with identical source -> cache hit
        final outDir2 = Directory(p.join(tempDir.path, 'out2'));
        final result2 = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          outputDir: outDir2,
        );
        check(result2.success).isTrue();
        check(result2.cacheHit).isTrue();
        check(result2.compilationDuration).equals(Duration.zero);
        check(result2.artifactPath).isNotNull();
        check(File(result2.artifactPath!).existsSync()).isTrue();

        // 3. Passing useCache: false bypasses cache (cacheHit: false)
        final result3 = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          outputDir: outDir2,
          useCache: false,
        );
        check(result3.success).isTrue();
        check(result3.cacheHit).isFalse();

        // 4. Modifying source file invalidates cache (cacheHit: false)
        source.writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class CacheBench extends Benchmark {
  CacheBench() : super('cache_bench_modified');
  @override
  void run() => Blackhole.consume(2);
}

void main(List<String> args) => mainBenchmark(CacheBench(), args);
''');
        final result4 = await compiler.compile(
          sourceFile: source,
          runtime: TargetRuntime.aot,
          outputDir: outDir2,
        );
        check(result4.success).isTrue();
        check(result4.cacheHit).isFalse();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
