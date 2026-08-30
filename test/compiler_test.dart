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
        check(result.runnerScriptPath).equals(result.artifactPath);
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
  });
}
