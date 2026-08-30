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
  });
}
