import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:meta/meta.dart';

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

/// Standalone CLI entrypoint for a single [BenchmarkGroup].
Future<void> mainBenchmarkGroup(BenchmarkGroup group, List<String> args) async {
  await mainBenchmarkSuite([group], args);
}

/// Standalone CLI entrypoint for a [BenchmarkMatrix].
Future<void> mainBenchmarkMatrix(
  BenchmarkMatrix<dynamic> matrix,
  List<String> args,
) async {
  await mainBenchmarkSuite(matrix, args);
}

/// Standalone CLI entrypoint for an arbitrary collection or single instance of
/// benchmarks ([Benchmark], [AsyncBenchmark], [BenchmarkVariant],
/// [BenchmarkGroup], or [BenchmarkMatrix]).
Future<void> mainBenchmarkSuite(Object benchmarks, List<String> args) async {
  validateBenchmarks(benchmarks);
  final parser = ArgParser()
    ..addOption('json-output', help: 'Path to write output telemetry JSON')
    ..addFlag('json', help: 'Emit streaming JSON markers to stdout')
    ..addOption('target', defaultsTo: 'jit', help: 'Target runtime identifier')
    ..addOption('trials', help: 'Override measurement trials count')
    ..addOption(
      'max-trials',
      help: 'Override maximum measurement trials ceiling for adaptive scaling',
    )
    ..addOption('min-warmup', help: 'Override minimum warmup iterations')
    ..addOption('max-warmup', help: 'Override maximum warmup iterations')
    ..addOption('target-batch-ms', help: 'Override target batch duration (ms)')
    ..addFlag(
      'force-run',
      help:
          'Bypass calibration safety aborts on zero-elapsed-time timer '
          'quantization.',
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
    stderr.writeln();
    stderr.writeln(parser.usage);
    exitCode = ExitCode.usage.code;
    return;
  }

  final target = parsed.option('target') ?? 'jit';
  final isValidate = parsed.flag('validate');
  final config = _buildConfigFromArgs(parsed, isValidate: isValidate);

  final benchmarkList = benchmarks is Iterable
      ? List<Object>.from(benchmarks)
      : <Object>[benchmarks];

  final results = <BenchmarkResult>[];
  for (final item in benchmarkList) {
    if (item is Benchmark) {
      results.add(BenchmarkRunner.run(_applyConfigToBenchmark(item, config)));
    } else {
      results.addAll(await _executeAsyncBenchmarkItem(item, config));
    }
  }

  _finishSuite(
    results,
    target: target,
    jsonOutputPath: parsed.option('json-output'),
  );
}

@visibleForTesting
void validateBenchmarks(Object? benchmarks) {
  if (benchmarks == null) {
    throw ArgumentError('Benchmark suite argument cannot be null.');
  }
  if (benchmarks is Iterable && benchmarks.any((e) => e == null)) {
    throw ArgumentError('Benchmark suite list cannot contain null elements.');
  }
}

void _writeJsonOutput(String? jsonOutputPath, String jsonText) {
  if (jsonOutputPath == null || jsonOutputPath.isEmpty) return;
  try {
    final file = File(jsonOutputPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$jsonText\n');
  } on Object catch (e) {
    stderr.writeln('Warning: Failed to write JSON output: $e');
  }
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

  final trials = int.tryParse(parsed.option('trials') ?? '');
  final maxTrials = int.tryParse(parsed.option('max-trials') ?? '');
  final minWarmup = int.tryParse(parsed.option('min-warmup') ?? '');
  final maxWarmup = int.tryParse(parsed.option('max-warmup') ?? '');
  final batchMs = int.tryParse(parsed.option('target-batch-ms') ?? '');
  final forceRun = parsed.flag('force-run');

  return BenchmarkConfig(
    trials: trials ?? 15,
    maxTrials: maxTrials,
    minWarmupIterations: minWarmup ?? 10,
    maxWarmupIterations: maxWarmup ?? 200,
    targetBatchDuration: batchMs != null
        ? Duration(milliseconds: batchMs)
        : const Duration(milliseconds: 100),
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

void _finishSuite(
  List<BenchmarkResult> results, {
  required String target,
  required String? jsonOutputPath,
}) {
  final suiteResult = BenchmarkSuiteResult.fromResults(
    results,
    target: target,
    environment: EnvironmentInfo.current(),
  );

  final jsonText = const JsonEncoder.withIndent('  ')
      .convert(suiteResult.toJson());

  _writeJsonOutput(jsonOutputPath, jsonText);

  // Always emit stream markers for subprocess communication
  stdout.writeln(wrapJsonInMarkers(jsonText));
}

Future<List<BenchmarkResult>> _executeAsyncBenchmarkItem(
  Object item,
  BenchmarkConfig config,
) async {
  switch (item) {
    case AsyncBenchmark b:
      return [
        await BenchmarkRunner.runAsync(_applyConfigToAsyncBenchmark(b, config)),
      ];
    case BenchmarkVariant b:
      return [await BenchmarkRunner.runVariant(b, config: config)];
    case BenchmarkGroup g:
      return await _runGroupVariants(g, config);
    case BenchmarkMatrix<dynamic> m:
      return await _runMatrixVariants(m, config);
    default:
      throw ArgumentError(
        'Unsupported benchmark type: ${item.runtimeType}. '
        'Expected Benchmark, AsyncBenchmark, BenchmarkVariant, '
        'BenchmarkGroup, or BenchmarkMatrix.',
      );
  }
}

Future<List<BenchmarkResult>> _runGroupVariants(
  BenchmarkGroup g,
  BenchmarkConfig config,
) async => [
  for (final v in g.variants)
    await BenchmarkRunner.runVariant(v, config: config),
];

Future<List<BenchmarkResult>> _runMatrixVariants(
  BenchmarkMatrix<dynamic> m,
  BenchmarkConfig config,
) async => [
  for (final g in m)
    for (final v in g.variants)
      await BenchmarkRunner.runVariant(v, config: config),
];

final class _ConfiguredBenchmark(
  final Benchmark _delegate,
  BenchmarkConfig config,
) extends Benchmark {
  this
    : super(
        _delegate.name,
        config: config,
        group: _delegate.group,
        isBaseline: _delegate.isBaseline,
      );

  @override
  void setup() => _delegate.setup();

  @override
  void run() => _delegate.run();

  @override
  void teardown() => _delegate.teardown();
}

final class _ConfiguredAsyncBenchmark(
  final AsyncBenchmark _delegate,
  BenchmarkConfig config,
) extends AsyncBenchmark {
  this
    : super(
        _delegate.name,
        config: config,
        group: _delegate.group,
        isBaseline: _delegate.isBaseline,
      );

  @override
  Future<void> setup() => _delegate.setup();

  @override
  Future<void> run() => _delegate.run();

  @override
  Future<void> teardown() => _delegate.teardown();
}
