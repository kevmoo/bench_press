import 'dart:async';
import 'dart:collection';

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

  /// Convenience factory forwarding to [BenchmarkGroup.matrix].
  static BenchmarkMatrix<T> matrix<T>({
    required Iterable<T> cases,
    required String Function(T caseItem) name,
    required (String, dynamic Function(T caseItem)) baseline,
    required Map<String, dynamic Function(T caseItem)> candidates,
    Throughput? Function(T caseItem)? throughput,
    void Function(T caseItem)? setup,
    void Function(T caseItem)? teardown,
    BenchmarkConfig config = const BenchmarkConfig(),
  }) => BenchmarkGroup.matrix<T>(
    cases: cases,
    name: name,
    baseline: baseline,
    candidates: candidates,
    throughput: throughput,
    setup: setup,
    teardown: teardown,
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

  /// Parameterized matrix group builder to benchmark competing implementations
  /// across multiple cases or datasets without repetitive boilerplate.
  static BenchmarkMatrix<T> matrix<T>({
    required Iterable<T> cases,
    required String Function(T caseItem) name,
    required (String, dynamic Function(T caseItem)) baseline,
    required Map<String, dynamic Function(T caseItem)> candidates,
    Throughput? Function(T caseItem)? throughput,
    void Function(T caseItem)? setup,
    void Function(T caseItem)? teardown,
    BenchmarkConfig config = const BenchmarkConfig(),
  }) {
    final caseList = List<T>.unmodifiable(cases);
    final groups = <BenchmarkGroup>[
      for (final caseItem in caseList)
        BenchmarkGroup.compare(
          name: name(caseItem),
          baseline: (baseline.$1, () => baseline.$2(caseItem)),
          candidates: {
            for (final entry in candidates.entries)
              entry.key: () => entry.value(caseItem),
          },
          setup: setup != null ? () => setup(caseItem) : null,
          teardown: teardown != null ? () => teardown(caseItem) : null,
          throughput: throughput?.call(caseItem),
          config: config,
        ),
    ];
    return BenchmarkMatrix<T>(groups, cases: caseList, config: config);
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

/// A parameterized matrix of benchmark groups across datasets or input cases.
final class BenchmarkMatrix<T>(
  List<BenchmarkGroup> rawGroups, {
  required Iterable<T> cases,

  /// Default configuration applied across groups in this matrix.
  final BenchmarkConfig config = const BenchmarkConfig(),
}) extends UnmodifiableListView<BenchmarkGroup> {
  /// The input cases evaluated in this matrix.
  final List<T> cases = List.unmodifiable(cases);

  this : super(List.unmodifiable(rawGroups));

  /// The generated benchmark groups in this matrix.
  List<BenchmarkGroup> get groups => this;

  /// Executes all benchmark groups in this matrix sequentially.
  Future<List<BenchmarkResult>> report({BenchmarkConfig? config}) async {
    final effectiveConfig = config ?? this.config;
    final results = <BenchmarkResult>[];
    for (final group in this) {
      results.addAll(await group.report(config: effectiveConfig));
    }
    return results;
  }

  @override
  String toString() =>
      'BenchmarkMatrix<$T>(cases: ${cases.length}, groups: $length)';
}
