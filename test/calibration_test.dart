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
          Blackhole.consume(a);
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

      final loggedMessages = <String>[];
      final configTrue = BenchmarkConfig(
        forceRun: true,
        logger: loggedMessages.add,
      );
      final batch = BenchmarkCalibrator.calibrateSync(
        () {},
        configTrue,
        stopwatch: zeroStopwatch,
      );

      check(batch.iterations).equals(1000000);
      check(batch.estimatedOpDurationMicroseconds).equals(0.0);
      check(loggedMessages).any((it) => it.contains('elapsedUs == 0'));
    });
    test('post-warmup calibration carries forward startingIterations', () {
      var actionCalls = 0;
      final mockStopwatch = _MockStopwatch(microsPerMeasurement: 6000);

      final batch = BenchmarkCalibrator.calibrateSync(
        () {
          actionCalls++;
        },
        const BenchmarkConfig(),
        startingIterations: 42,
        stopwatch: mockStopwatch,
      );

      // Ensures the calibration starts at 42 instead of 1. Because the elapsed time
      // > 5ms (6000µs), it terminates on the first probe batch.
      check(actionCalls).equals(42);
      // target 100,000 us / (6000/42) -> 700 iterations
      check(batch.iterations).equals(700);
    });
  });
}

final class _ZeroStopwatch implements Stopwatch {
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

final class _MockStopwatch implements Stopwatch {
  final int microsPerMeasurement;
  int _elapsedMicroseconds = 0;
  bool _isRunning = false;

  _MockStopwatch({this.microsPerMeasurement = 6000});

  @override
  Duration get elapsed => Duration(microseconds: _elapsedMicroseconds);
  @override
  int get elapsedMicroseconds => _elapsedMicroseconds;
  @override
  int get elapsedMilliseconds => _elapsedMicroseconds ~/ 1000;
  @override
  int get elapsedTicks => _elapsedMicroseconds;
  @override
  int get frequency => 1000000;
  @override
  bool get isRunning => _isRunning;
  @override
  void reset() {
    _elapsedMicroseconds = 0;
  }

  @override
  void start() {
    _isRunning = true;
  }

  @override
  void stop() {
    _isRunning = false;
    _elapsedMicroseconds = microsPerMeasurement;
  }
}
