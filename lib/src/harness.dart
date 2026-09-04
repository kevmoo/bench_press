import 'dart:async';

import 'blackhole.dart';
import 'config.dart';
import 'runner.dart';
import 'throughput.dart';

/// Base class for synchronous benchmarks.
abstract class Benchmark(
  final String name, {
  final BenchmarkConfig config = const BenchmarkConfig(),
  final String? group,
  final bool isBaseline = false,
}) {
  /// Declared throughput processed per [run] invocation (bytes or element
  /// count).
  Throughput? get throughput => null;

  /// Executed once before any warmup or measurement iterations begin.
  void setup() {}

  /// The unit of work to be benchmarked.
  void run();

  /// Executed once when warmup has concluded and measurement trials begin.
  void warmupComplete() {}

  /// Executed once after all measurement trials complete.
  void teardown() {}

  /// Executes this benchmark through the full lifecycle [BenchmarkRunner].
  BenchmarkResult report() => BenchmarkRunner.run(this);

  /// Convenience factory forwarding to [BenchmarkGroup.compare].
  static BenchmarkGroup compare({
    required String name,
    required (String, dynamic Function()) baseline,
    required Map<String, dynamic Function()> candidates,
    void Function()? setup,
    void Function()? teardown,
    Throughput? throughput,
    BenchmarkConfig config = const BenchmarkConfig(),
  }) => BenchmarkGroup.compare(
    name: name,
    baseline: baseline,
    candidates: candidates,
    setup: setup,
    teardown: teardown,
    throughput: throughput,
    config: config,
  );
}

/// Base class for asynchronous benchmarks.
abstract class AsyncBenchmark(
  final String name, {
  final BenchmarkConfig config = const BenchmarkConfig(),
  final String? group,
  final bool isBaseline = false,
}) {
  /// Declared throughput processed per [run] invocation (bytes or element
  /// count).
  Throughput? get throughput => null;

  /// Executed once before any warmup or measurement iterations begin.
  Future<void> setup() async {}

  /// The asynchronous unit of work to be benchmarked.
  Future<void> run();

  /// Executed once when warmup has concluded and measurement trials begin.
  Future<void> warmupComplete() async {}

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
  final String? group,
  final bool isBaseline = false,
  final Throughput? throughput,
}) {
  /// Executes the variant action, awaiting asynchronous [Future] returns safely
  /// without dynamic casting errors.
  Future<void> executeAsync() async {
    final result = action();
    if (result is Future) {
      Blackhole.consume(await result);
    } else {
      Blackhole.consume(result);
    }
  }

  /// Executes the variant synchronously.
  void executeSync() {
    Blackhole.consume(action());
  }

  /// Executes this variant through the full lifecycle [BenchmarkRunner].
  Future<BenchmarkResult> report({
    BenchmarkConfig config = const BenchmarkConfig(),
  }) => BenchmarkRunner.runVariant(this, config: config);
}

/// A named collection of competing implementation variants evaluated together
/// in the same process and thermal envelope.
final class BenchmarkGroup(
  final String name,
  List<BenchmarkVariant> rawVariants, {
  final BenchmarkConfig config = const BenchmarkConfig(),
}) {
  /// The list of implementation variants belonging to this group.
  final List<BenchmarkVariant> variants = List.unmodifiable(
    rawVariants.map(
      (v) => BenchmarkVariant(
        v.name,
        v.action,
        setup: v.setup,
        teardown: v.teardown,
        group: v.group ?? name,
        isBaseline: v.isBaseline,
        throughput: v.throughput,
      ),
    ),
  );

  /// Declarative matrix comparison builder.
  static BenchmarkGroup compare({
    required String name,
    required (String, dynamic Function()) baseline,
    required Map<String, dynamic Function()> candidates,
    void Function()? setup,
    void Function()? teardown,
    Throughput? throughput,
    BenchmarkConfig config = const BenchmarkConfig(),
  }) {
    final list = <BenchmarkVariant>[
      BenchmarkVariant(
        baseline.$1,
        baseline.$2,
        setup: setup,
        teardown: teardown,
        group: name,
        isBaseline: true,
        throughput: throughput,
      ),
      for (final entry in candidates.entries)
        BenchmarkVariant(
          entry.key,
          entry.value,
          setup: setup,
          teardown: teardown,
          group: name,
          isBaseline: false,
          throughput: throughput,
        ),
    ];
    return BenchmarkGroup(name, list, config: config);
  }

  /// Executes all variants in this group sequentially.
  Future<List<BenchmarkResult>> report({BenchmarkConfig? config}) async {
    final effectiveConfig = config ?? this.config;
    final results = <BenchmarkResult>[];
    for (final variant in variants) {
      results.add(
        await BenchmarkRunner.runVariant(variant, config: effectiveConfig),
      );
    }
    return results;
  }
}
