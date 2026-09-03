import 'dart:async';

import 'package:bench_press/bench_press.dart';

/// 1. Synchronous Class-Based Benchmark
///
/// Subclass [Benchmark], provide a name, and implement [run].
/// Optionally override [setup] and [teardown] for resource lifecycles.
final class FibonacciBenchmark() extends Benchmark {
  this : super('fibonacci_recursive');

  int _fib(int n) => n <= 1 ? n : _fib(n - 1) + _fib(n - 2);

  @override
  void run() {
    final result = _fib(20);
    Blackhole.consume(result);
  }
}

/// 2. Asynchronous Class-Based Benchmark
///
/// Subclass [AsyncBenchmark] when benchmarking asynchronous pipelines
/// (such as I/O, streams, or asynchronous workers).
final class AsyncDelayBenchmark() extends AsyncBenchmark {
  this
    : super(
        'async_microtask_batch',
        config: const BenchmarkConfig(
          trials: 5,
          minWarmupIterations: 5,
          maxWarmupIterations: 20,
          targetBatchDuration: Duration(milliseconds: 5),
          forceRun: true,
        ),
      );

  @override
  Future<void> run() async {
    await Future<void>.microtask(() {
      Blackhole.consume(42);
    });
  }
}

/// 3. Compositional Functional Benchmark Variant
///
/// Use [BenchmarkVariant] for rapid, closure-based comparisons without
/// defining dedicated classes.
final BenchmarkVariant variantBenchmark = BenchmarkVariant(
  'string_buffer_variant',
  () {
    final sb = StringBuffer();
    for (var i = 0; i < 250; i++) {
      sb.write('token_$i');
    }
    Blackhole.consume(sb.toString());
  },
  throughput: const Throughput.elements(250, unit: 'tokens'),
);

/// 4. Model 1: Intra-Run Apples-to-Apples Comparison Group
///
/// Use [BenchmarkGroup] to evaluate competing implementations executed within
/// the exact same process and thermal envelope.
final BenchmarkGroup stringBuildingGroup = BenchmarkGroup(
  'String Construction',
  [
    BenchmarkVariant(
      'plus_concat',
      () {
        var s = '';
        for (var i = 0; i < 50; i++) {
          s += 'token';
        }
        Blackhole.consume(s);
      },
      isBaseline: true,
      throughput: const Throughput.elements(50, unit: 'tokens'),
    ),
    BenchmarkVariant('string_buffer', () {
      final sb = StringBuffer();
      for (var i = 0; i < 50; i++) {
        sb.write('token');
      }
      Blackhole.consume(sb.toString());
    }, throughput: const Throughput.elements(50, unit: 'tokens')),
    BenchmarkVariant('join', () {
      final list = List.filled(50, 'token');
      Blackhole.consume(list.join());
    }, throughput: const Throughput.elements(50, unit: 'tokens')),
  ],
);

/// 5. Discovered Benchmark Collection
///
/// Top-level `benchmarks` collection automatically discovered by
/// `bench_press run`.
final List<Object> benchmarks = [
  FibonacciBenchmark(),
  AsyncDelayBenchmark(),
  variantBenchmark,
  stringBuildingGroup,
];

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    // If CLI arguments are provided (e.g. from `bench_press run`),
    // delegate to the benchmark suite runner.
    await mainBenchmarkSuite(benchmarks, args);
    return;
  }

  // Otherwise, run standalone demonstrations via `.report()`:
  print('=== Running Standalone Benchmark Reports ===\n');

  // Run synchronous benchmark
  final fibResult = FibonacciBenchmark().report();
  print('Benchmark: ${fibResult.name}');
  print('  Mean:       ${fibResult.metrics.meanNs.toStringAsFixed(1)} ns');
  print('  Median:     ${fibResult.metrics.medianNs.toStringAsFixed(1)} ns');
  print('  Min:        ${fibResult.metrics.minNs.toStringAsFixed(1)} ns');
  print(
    '  Ops/sec:    ${fibResult.metrics.opsPerSec.toStringAsFixed(0)} ops/s',
  );
  print('  Is Stable:  ${fibResult.metrics.isStable ? "✅ Yes" : "⚠️ No"}\n');

  // Run asynchronous benchmark
  final asyncResult = await AsyncDelayBenchmark().report();
  print('Benchmark: ${asyncResult.name}');
  print('  Mean:       ${asyncResult.metrics.meanNs.toStringAsFixed(1)} ns');
  print(
    '  Ops/sec:    ${asyncResult.metrics.opsPerSec.toStringAsFixed(0)} ops/s\n',
  );

  // Run variant benchmark
  final varResult = await variantBenchmark.report(
    config: const BenchmarkConfig(forceRun: true),
  );
  print('Benchmark: ${varResult.name}');
  print('  Mean:       ${varResult.metrics.meanNs.toStringAsFixed(1)} ns');
  print(
    '  Ops/sec:    ${varResult.metrics.opsPerSec.toStringAsFixed(0)} ops/s\n',
  );

  // Run benchmark group (Model 1)
  print('=== Model 1: BenchmarkGroup Results ===');
  final groupResults = await stringBuildingGroup.report(
    config: const BenchmarkConfig(forceRun: true),
  );
  for (final res in groupResults) {
    final baseTag = res.isBaseline ? ' (Baseline)' : '';
    print(
      '  ${res.name}$baseTag: ${res.metrics.opsPerSec.toStringAsFixed(0)} ops/s '
      '(${res.metrics.meanNs.toStringAsFixed(1)} ns/op)',
    );
  }
}
