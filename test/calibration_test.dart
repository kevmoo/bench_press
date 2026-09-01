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

    test('bypasses zero-elapsed ticks when forceRun is true', () {
      final zeroStopwatch = _ZeroStopwatch();

      const configFalse = BenchmarkConfig(forceRun: false);
      check(
        () => BenchmarkCalibrator.calibrateSync(
          () {},
          configFalse,
          stopwatch: zeroStopwatch,
        ),
      ).throws<CalibrationException>();

      const configTrue = BenchmarkConfig(forceRun: true);
      final batch = BenchmarkCalibrator.calibrateSync(
        () {},
        configTrue,
        stopwatch: zeroStopwatch,
      );

      check(batch.iterations).equals(1000000);
      check(batch.estimatedOpDurationMicroseconds).equals(0.0);
    });
  });
}

final class _ZeroStopwatch() implements Stopwatch {
  @override
  Duration get elapsed => Duration.zero;
  @override
  int get elapsedMicroseconds => 0;
  @override
  int get elapsedMilliseconds => 0;
  @override
  int get elapsedTicks => 0;
  @override
  int get frequency => 1000000;
  @override
  bool get isRunning => false;
  @override
  void reset() {}
  @override
  void start() {}
  @override
  void stop() {}
}
