import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

final class _CountingBenchmark extends Benchmark {
  int count = 0;

  _CountingBenchmark(super.name);

  @override
  void run() {
    count++;
    Blackhole.consumeInt(count);
  }
}

final class _CountingAsyncBenchmark extends AsyncBenchmark {
  int count = 0;

  _CountingAsyncBenchmark(super.name);

  @override
  Future<void> run() async {
    count++;
    Blackhole.consumeInt(count);
  }
}

void main() {
  group('BatchRunner', () {
    test(
      'runSync executes requested iterations and measures perOpNanoseconds',
      () {
        final bench = _CountingBenchmark('batch_sync');
        final measurement = BatchRunner.runSync(bench, 100);

        check(bench.count).equals(100);
        check(measurement.iterations).equals(100);
        check(measurement.perOpNanoseconds).isGreaterThan(0.0);
      },
    );

    test(
      'runAsync executes requested iterations and measures perOpNanoseconds',
      () async {
        final bench = _CountingAsyncBenchmark('batch_async');
        final measurement = await BatchRunner.runAsync(bench, 20);

        check(bench.count).equals(20);
        check(measurement.iterations).equals(20);
        check(measurement.perOpNanoseconds).isGreaterThan(0.0);
      },
    );

    test('runVariantSync executes variant actions and measures latency', () {
      var count = 0;
      final variant = BenchmarkVariant('var_sync', () {
        count++;
        Blackhole.consumeInt(count);
      });

      final measurement = BatchRunner.runVariantSync(variant, 50);

      check(count).equals(50);
      check(measurement.iterations).equals(50);
      check(measurement.perOpNanoseconds).isGreaterThan(0.0);
    });
  });
}
