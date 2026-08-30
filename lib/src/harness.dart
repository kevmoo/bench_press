import 'dart:async';

import 'config.dart';

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
}
