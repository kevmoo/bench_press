import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../config.dart';
import '../harness.dart';
import '../runner.dart';
import '../telemetry/schema.dart';

/// Marker line indicating the beginning of embedded benchmark telemetry JSON.
const String benchPressJsonStartMarker = '<<<BENCH_PRESS_JSON_START>>>';

/// Marker line indicating the conclusion of embedded benchmark telemetry JSON.
const String benchPressJsonEndMarker = '<<<BENCH_PRESS_JSON_END>>>';

/// Formats and wraps a JSON string in canonical bench_press streaming markers.
String wrapJsonInMarkers(String jsonString) =>
    '$benchPressJsonStartMarker\n$jsonString\n$benchPressJsonEndMarker';

/// Extracts embedded benchmark telemetry JSON from subprocess stdout text,
/// or returns `null` if markers are absent or malformed.
String? extractJsonFromStdout(String stdout) {
  final startIndex = stdout.indexOf(benchPressJsonStartMarker);
  if (startIndex == -1) return null;

  final afterStart = stdout.substring(
    startIndex + benchPressJsonStartMarker.length,
  );
  final endIndex = afterStart.indexOf(benchPressJsonEndMarker);
  if (endIndex == -1) return null;

  final jsonSnippet = afterStart.substring(0, endIndex).trim();
  return jsonSnippet.isNotEmpty ? jsonSnippet : null;
}

/// Standalone CLI entrypoint for a single synchronous [Benchmark].
void mainBenchmark(Benchmark benchmark, List<String> args) {
  mainBenchmarkSuite([benchmark], args);
}

/// Standalone CLI entrypoint for a single asynchronous [AsyncBenchmark].
Future<void> mainAsyncBenchmark(
  AsyncBenchmark benchmark,
  List<String> args,
) async {
  await mainBenchmarkSuite([benchmark], args);
}

/// Standalone CLI entrypoint for an arbitrary collection of benchmarks
/// ([Benchmark], [AsyncBenchmark], or [BenchmarkVariant]).
Future<void> mainBenchmarkSuite(
  List<Object> benchmarks,
  List<String> args,
) async {
  final parser = ArgParser()
    ..addOption('json-output', help: 'Path to write output telemetry JSON')
    ..addFlag('json', help: 'Emit streaming JSON markers to stdout')
    ..addOption('target', defaultsTo: 'jit', help: 'Target runtime identifier')
    ..addOption('trials', help: 'Override measurement trials count')
    ..addOption('min-warmup', help: 'Override minimum warmup iterations')
    ..addOption('max-warmup', help: 'Override maximum warmup iterations')
    ..addOption('target-batch-ms', help: 'Override target batch duration (ms)')
    ..addFlag(
      'force-run',
      help: 'Bypass calibration safety aborts on sub-10µs runs',
    )
    ..addFlag(
      'validate',
      help: 'Execute fast smoke check (1 trial, 1 warmup iteration)',
    );

  final cleanArgs = args.isNotEmpty && args.first == '--'
      ? args.sublist(1)
      : args;

  ArgResults parsed;
  try {
    parsed = parser.parse(cleanArgs);
  } on FormatException catch (e) {
    stderr.writeln('Argument error: ${e.message}');
    exit(1);
  }

  final target = parsed['target'] as String;
  final isValidate = parsed['validate'] as bool;
  final config = _buildConfigFromArgs(parsed, isValidate: isValidate);

  final results = <BenchmarkResult>[];
  for (final item in benchmarks) {
    if (item is Benchmark) {
      final bench = _applyConfigToBenchmark(item, config);
      final result = BenchmarkRunner.run(bench);
      results.add(result);
    } else if (item is AsyncBenchmark) {
      final bench = _applyConfigToAsyncBenchmark(item, config);
      final result = await BenchmarkRunner.runAsync(bench);
      results.add(result);
    } else if (item is BenchmarkVariant) {
      final result = await BenchmarkRunner.runVariant(item, config: config);
      results.add(result);
    } else {
      throw ArgumentError(
        'Unsupported benchmark type: ${item.runtimeType}. '
        'Expected Benchmark, AsyncBenchmark, or BenchmarkVariant.',
      );
    }
  }

  final suiteResult = BenchmarkSuiteResult.fromResults(
    results,
    target: target,
    environment: EnvironmentInfo.current(),
  );

  final jsonText = const JsonEncoder.withIndent('  ')
      .convert(suiteResult.toJson());

  final jsonOutputPath = parsed['json-output'] as String?;
  if (jsonOutputPath != null && jsonOutputPath.isNotEmpty) {
    try {
      final file = File(jsonOutputPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$jsonText\n');
    } on Object catch (e) {
      stderr.writeln('Warning: Failed to write JSON output: $e');
    }
  }

  // Always emit stream markers for subprocess communication
  stdout.writeln(wrapJsonInMarkers(jsonText));
}

BenchmarkConfig _buildConfigFromArgs(
  ArgResults parsed, {
  required bool isValidate,
}) {
  if (isValidate) {
    return const BenchmarkConfig(
      trials: 1,
      minWarmupIterations: 1,
      maxWarmupIterations: 2,
      targetBatchDuration: Duration(milliseconds: 1),
      forceRun: true,
    );
  }

  final trials = int.tryParse(parsed['trials'] as String? ?? '');
  final minWarmup = int.tryParse(parsed['min-warmup'] as String? ?? '');
  final maxWarmup = int.tryParse(parsed['max-warmup'] as String? ?? '');
  final batchMs = int.tryParse(parsed['target-batch-ms'] as String? ?? '');
  final forceRun = parsed['force-run'] as bool;

  return BenchmarkConfig(
    trials: trials ?? 15,
    minWarmupIterations: minWarmup ?? 10,
    maxWarmupIterations: maxWarmup ?? 200,
    targetBatchDuration: batchMs != null
        ? Duration(milliseconds: batchMs)
        : const Duration(milliseconds: 10),
    forceRun: forceRun,
  );
}

Benchmark _applyConfigToBenchmark(Benchmark benchmark, BenchmarkConfig config) {
  if (benchmark.config == config) return benchmark;
  return _ConfiguredBenchmark(benchmark, config);
}

AsyncBenchmark _applyConfigToAsyncBenchmark(
  AsyncBenchmark benchmark,
  BenchmarkConfig config,
) {
  if (benchmark.config == config) return benchmark;
  return _ConfiguredAsyncBenchmark(benchmark, config);
}

final class _ConfiguredBenchmark extends Benchmark {
  final Benchmark _delegate;

  _ConfiguredBenchmark(this._delegate, BenchmarkConfig config)
    : super(_delegate.name, config: config);

  @override
  void setup() => _delegate.setup();

  @override
  void run() => _delegate.run();

  @override
  void teardown() => _delegate.teardown();
}

final class _ConfiguredAsyncBenchmark extends AsyncBenchmark {
  final AsyncBenchmark _delegate;

  _ConfiguredAsyncBenchmark(this._delegate, BenchmarkConfig config)
    : super(_delegate.name, config: config);

  @override
  Future<void> setup() => _delegate.setup();

  @override
  Future<void> run() => _delegate.run();

  @override
  Future<void> teardown() => _delegate.teardown();
}
