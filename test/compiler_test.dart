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
        // The runner is a `.node.js` wrapper, not the compiled artifact
        // itself — `dart compile js` output assumes a browser/worker `self`
        // global for microtask/timer scheduling, absent under Node, so the
        // wrapper polyfills it before requiring the real artifact.
        check(result.runnerScriptPath).isNotNull();
        check(result.runnerScriptPath)
            .not((it) => it.equals(result.artifactPath));
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
          check(File(result.runnerScriptPath!).existsSync()).isTrue();
          check(File(result.runnerScriptPath!).readAsStringSync())
              .contains('instantiatedApp.invokeMain');
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

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
  });
}
