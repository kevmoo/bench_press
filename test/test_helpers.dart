import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:path/path.dart' as p;
import 'package:test_descriptor/test_descriptor.dart' as d;

const EnvironmentInfo defaultTestEnvironment = EnvironmentInfo(
  dartVersion: '3.14.0',
  os: 'linux',
  arch: 'x64',
);

File writeSyncBenchmark({
  String? dirPath,
  String fileName = 'smoke_bench.dart',
  String className = 'SmokeBenchmark',
  String name = 'smoke',
  String body = 'Blackhole.consume(1);',
  String? subDir,
}) {
  final root = dirPath ?? d.sandbox;
  final targetDirPath = subDir != null ? p.join(root, subDir) : root;
  Directory(targetDirPath).createSync(recursive: true);
  return File(p.join(targetDirPath, fileName))..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

final class $className extends Benchmark {
  $className() : super('$name');
  @override
  void run() {
    $body
  }
}

void main(List<String> args) => mainBenchmark($className(), args);
''');
}

File writeEmptyBenchmark({
  String? dirPath,
  String fileName = 'empty_bench.dart',
}) => File(p.join(dirPath ?? d.sandbox, fileName))
  ..writeAsStringSync('''
import 'package:bench_press/bench_press.dart';

void main(List<String> args) => mainBenchmarkSuite([], args);
''');

File writeBrokenBenchmark({
  String? dirPath,
  String fileName = 'bad_bench.dart',
}) =>
    File(p.join(dirPath ?? d.sandbox, fileName))
      ..writeAsStringSync('void main() { syntax error here ;;;\n');

File writeBenchPressYaml(String content, {String? dirPath}) =>
    File(p.join(dirPath ?? d.sandbox, 'bench_press.yaml'))
      ..writeAsStringSync(content);

BenchmarkMetrics createSampleMetrics({
  double meanNs = 100.0,
  double medianNs = 100.0,
  double minNs = 95.0,
  double maxNs = 105.0,
  double stddevNs = 5.0,
  double cv = 0.05,
  double p95Ns = 108.0,
  double p99Ns = 109.0,
  double opsPerSec = 10000000.0,
  bool isStable = true,
}) => BenchmarkMetrics(
  meanNs: meanNs,
  medianNs: medianNs,
  minNs: minNs,
  maxNs: maxNs,
  stddevNs: stddevNs,
  cv: cv,
  p95Ns: p95Ns,
  p99Ns: p99Ns,
  opsPerSec: opsPerSec,
  isStable: isStable,
);

BenchmarkEntry createSampleEntry({
  String name = 'sample_workload',
  String target = 'jit',
  String mode = 'sync',
  int samples = 5,
  BenchmarkMetrics? metrics,
  List<double> rawTrialsNs = const [],
}) => BenchmarkEntry(
  name: name,
  target: target,
  mode: mode,
  samples: samples,
  metrics: metrics ?? createSampleMetrics(),
  rawTrialsNs: rawTrialsNs,
);

BenchmarkSuiteResult createSampleSuite({
  required List<BenchmarkEntry> benchmarks,
  String timestamp = '2026-08-30T00:00:00.000Z',
  EnvironmentInfo environment = defaultTestEnvironment,
}) => BenchmarkSuiteResult(
  version: currentTelemetrySchemaVersion,
  timestamp: DateTime.parse(timestamp),
  environment: environment,
  benchmarks: benchmarks,
);

Future<ProcessExecutionResult> compileAndExecute(
  File sourceFile, {
  TargetRuntime runtime = TargetRuntime.jit,
  bool isolateMode = false,
  int trials = 2,
  bool forceRun = true,
  DartSdk sdk = const DartSdk(),
}) async {
  final compiler = TargetCompiler(sdk: sdk);
  final compilation = await compiler.compile(
    sourceFile: sourceFile,
    runtime: runtime,
  );
  final runner = BenchmarkProcessRunner(sdk: sdk);
  return await runner.execute(
    compilationResult: compilation,
    isolateMode: isolateMode,
    trials: trials,
    forceRun: forceRun,
  );
}

CompilationResult createMockCompilationResult({
  bool success = true,
  TargetRuntime runtime = TargetRuntime.wasm,
  String sourcePath = '/path/to/bench.dart',
  String? artifactPath = '/path/to/bench.wasm',
  String? runnerScriptPath = '/path/to/bench.mjs',
  String stderr = '',
  int exitCode = 0,
}) => CompilationResult(
  success: success,
  runtime: runtime,
  sourcePath: sourcePath,
  artifactPath: artifactPath,
  runnerScriptPath: runnerScriptPath,
  compilationDuration: Duration.zero,
  stdout: '',
  stderr: stderr,
  exitCode: exitCode,
);

File writeMockRunnerScript({
  String? dirPath,
  required String executableName,
  required String benchmarkName,
  double meanNs = 50.0,
}) {
  final script = File(p.join(dirPath ?? d.sandbox, executableName))
    ..writeAsStringSync('''#!/bin/sh
cat << 'END_OF_JSON'
<<<BENCH_PRESS_JSON_START>>>
{
  "version": 1,
  "timestamp": "2026-08-30T00:00:00.000Z",
  "environment": {"dart_version": "3.14.0", "os": "linux", "arch": "x64"},
  "benchmarks": [
    {
      "name": "$benchmarkName",
      "target": "wasm",
      "mode": "sync",
      "samples": 2,
      "metrics": {
        "mean_ns": $meanNs,
        "median_ns": $meanNs,
        "min_ns": ${meanNs - 5.0},
        "max_ns": ${meanNs + 5.0},
        "stddev_ns": 2.0,
        "cv": 0.04,
        "p95_ns": ${meanNs + 4.0},
        "p99_ns": ${meanNs + 5.0},
        "ops_per_sec": ${1000000000.0 / meanNs},
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
    Process.runSync('chmod', ['+x', script.path]);
  }
  return script;
}
