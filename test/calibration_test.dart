import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('BenchmarkCalibrator', () {
    test(
      'calibrates batch size for micro-operation to reach target duration',
      () {
        const config = BenchmarkConfig(
          targetBatchDuration: Duration(milliseconds: 10),
          forceRun: true,
        );

        final batch = BenchmarkCalibrator.calibrateSync(() {
          var a = 0;
          for (var i = 0; i < 500; i++) {
            a += i;
          }
          Blackhole.consumeInt(a);
        }, config);

        check(batch.iterations).isGreaterThan(1);
        check(batch.estimatedOpDurationMicroseconds).isGreaterThan(0.0);
      },
    );

    test('calibrates sub-10 µs operation cleanly without forceRun', () {
      const config = BenchmarkConfig(forceRun: false);

      final batch = BenchmarkCalibrator.calibrateSync(() {
        // Extremely fast operation (< 1 µs)
        Blackhole.consume(1);
      }, config);

      check(batch.iterations).isGreaterThan(1);
      check(batch.estimatedOpDurationMicroseconds).isGreaterThan(0.0);
    });

    test('allows sub-10 µs operation when forceRun is true', () {
      const config = BenchmarkConfig(forceRun: true);

      final batch = BenchmarkCalibrator.calibrateSync(() {
        Blackhole.consume(1);
      }, config);

      check(batch.iterations).isGreaterThan(1);
    });
  });
}
