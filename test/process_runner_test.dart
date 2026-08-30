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
  });
}
