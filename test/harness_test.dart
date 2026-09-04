import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

final class _SampleBenchmark(super.name) extends Benchmark {
  int setupCount = 0;
  int runCount = 0;
  int teardownCount = 0;

  @override
  void setup() => setupCount++;

  @override
  void run() => runCount++;

  @override
  void teardown() => teardownCount++;
}

final class _SampleAsyncBenchmark(super.name) extends AsyncBenchmark {
  int setupCount = 0;
  int runCount = 0;
  int teardownCount = 0;

  @override
  Future<void> setup() async => setupCount++;

  @override
  Future<void> run() async {
    runCount++;
  }

  @override
  Future<void> teardown() async => teardownCount++;
}

void main() {
  group('Benchmark Harness APIs', () {
    test('Benchmark lifecycle methods execute properly', () {
      final bench = _SampleBenchmark('sync_sample');
      check(bench.name).equals('sync_sample');

      bench.setup();
      bench.run();
      bench.teardown();

      check(bench.setupCount).equals(1);
      check(bench.runCount).equals(1);
      check(bench.teardownCount).equals(1);
    });

    test('AsyncBenchmark lifecycle methods execute properly', () async {
      final bench = _SampleAsyncBenchmark('async_sample');
      check(bench.name).equals('async_sample');

      await bench.setup();
      await bench.run();
      await bench.teardown();

      check(bench.setupCount).equals(1);
      check(bench.runCount).equals(1);
      check(bench.teardownCount).equals(1);
    });

    test(
      'BenchmarkVariant handles sync and typed async returns safely',
      () async {
        var syncCalls = 0;
        final syncVariant = BenchmarkVariant('sync_var', () {
          syncCalls++;
          return 42;
        });
        syncVariant.executeSync();
        check(syncCalls).equals(1);

        var asyncCalls = 0;
        final asyncVariant = BenchmarkVariant('async_var', () async {
          asyncCalls++;
          return 'typed_result';
        });
        await asyncVariant.executeAsync();
        check(asyncCalls).equals(1);
      },
    );

    test('BenchmarkGroup binds group name and preserves isBaseline', () {
      final group = BenchmarkGroup('String Group', [
        BenchmarkVariant('concat', () {}, isBaseline: true),
        BenchmarkVariant('buffer', () {}),
      ]);

      check(group.name).equals('String Group');
      check(group.variants.length).equals(2);
      check(group.variants[0].group).equals('String Group');
      check(group.variants[0].isBaseline).isTrue();
      check(group.variants[1].group).equals('String Group');
      check(group.variants[1].isBaseline).isFalse();
    });

    test('BenchmarkGroup.compare constructs matrix correctly', () {
      final group = BenchmarkGroup.compare(
        name: 'Matrix Comparison',
        baseline: ('base_impl', () => 1),
        candidates: {'candidate_a': () => 2, 'candidate_b': () => 3},
      );

      check(group.name).equals('Matrix Comparison');
      check(group.variants.length).equals(3);
      check(group.variants[0].name).equals('base_impl');
      check(group.variants[0].isBaseline).isTrue();
      check(group.variants[0].group).equals('Matrix Comparison');

      check(group.variants[1].name).equals('candidate_a');
      check(group.variants[1].isBaseline).isFalse();

      check(group.variants[2].name).equals('candidate_b');
      check(group.variants[2].isBaseline).isFalse();
    });

    test('Benchmark.compare forwards to BenchmarkGroup.compare', () {
      final group = Benchmark.compare(
        name: 'Forwarding Matrix',
        baseline: ('std', () => 10),
        candidates: {'fast': () => 20},
      );

      check(group.name).equals('Forwarding Matrix');
      check(group.variants.length).equals(2);
      check(group.variants.first.isBaseline).isTrue();
    });

    test('Benchmark.matrix forwards to BenchmarkGroup.matrix', () {
      final matrix = Benchmark.matrix<int>(
        cases: [1, 2],
        name: (c) => 'Case $c',
        baseline: ('base', (c) => c),
        candidates: {'cand': (c) => c * 2},
      );

      check(matrix.length).equals(2);
      check(matrix.cases).deepEquals([1, 2]);
      check(matrix.first.name).equals('Case 1');
      check(matrix.last.name).equals('Case 2');
    });

    test('BenchmarkGroup.report executes all variants', () async {
      var countA = 0;
      var countB = 0;
      final group = BenchmarkGroup('Exec Group', [
        BenchmarkVariant('varA', () => countA++, isBaseline: true),
        BenchmarkVariant('varB', () => countB++),
      ]);

      final results = await group.report(
        config: const BenchmarkConfig(
          trials: 2,
          minWarmupIterations: 2,
          maxWarmupIterations: 5,
          targetBatchDuration: Duration(milliseconds: 1),
          forceRun: true,
        ),
      );

      check(results.length).equals(2);
      check(results[0].name).equals('varA');
      check(results[0].group).equals('Exec Group');
      check(results[0].isBaseline).isTrue();

      check(results[1].name).equals('varB');
      check(results[1].group).equals('Exec Group');
      check(results[1].isBaseline).isFalse();
      check(countA).isGreaterThan(0);
      check(countB).isGreaterThan(0);
    });
  });
}
