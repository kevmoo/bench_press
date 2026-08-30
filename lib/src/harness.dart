import 'dart:async';

import 'config.dart';
import 'runner.dart';

/// Base class for synchronous benchmarks.
abstract class Benchmark(
  final String name, {
  final BenchmarkConfig config = const BenchmarkConfig(),
}) {
  /// Executed once before any warmup or measurement iterations begin.
  void setup() {}

  /// The unit of work to be benchmarked.
  void run();

  /// Executed once after all measurement trials complete.
  void teardown() {}

  /// Executes this benchmark through the full lifecycle [BenchmarkRunner].
  BenchmarkResult report() => BenchmarkRunner.run(this);
}

/// Base class for asynchronous benchmarks.
abstract class AsyncBenchmark(
  final String name, {
  final BenchmarkConfig config = const BenchmarkConfig(),
}) {
  /// Executed once before any warmup or measurement iterations begin.
  Future<void> setup() async {}

  /// The asynchronous unit of work to be benchmarked.
  Future<void> run();

  /// Executed once after all measurement trials complete.
  Future<void> teardown() async {}

  /// Executes this benchmark through the full lifecycle [BenchmarkRunner].
  Future<BenchmarkResult> report() => BenchmarkRunner.runAsync(this);
}

/// Compositional multi-algorithm comparison variant.
final class BenchmarkVariant(
  final String name,
  final dynamic Function() action, {
  final void Function()? setup,
  final void Function()? teardown,
}) {
  /// Executes the variant action, awaiting asynchronous [Future] returns safely
  /// without dynamic casting errors.
  Future<void> executeAsync() async {
    final result = action();
    if (result is Future) {
      await result;
    }
  }

  /// Executes the variant synchronously.
  void executeSync() {
    action();
  }

  /// Executes this variant through the full lifecycle [BenchmarkRunner].
  Future<BenchmarkResult> report({
    BenchmarkConfig config = const BenchmarkConfig(),
  }) => BenchmarkRunner.runVariant(this, config: config);
}
