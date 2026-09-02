import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('AdaptiveWarmupDetector & MMD Statistics', () {
    _testSummaryMath();
    _testMmdCalculations();
    _testDetectorConvergence();
    _testDetectorFallback();
  });
}

void _testSummaryMath() {
  test('computeMean calculates exact arithmetic mean', () {
    check(AdaptiveWarmupDetector.computeMean([])).equals(0.0);
    check(AdaptiveWarmupDetector.computeMean([10.0, 20.0, 30.0])).equals(20.0);
    check(AdaptiveWarmupDetector.computeMean([1.0, 2.0, 3.0, 4.0])).equals(2.5);
  });

  test('computeMedian handles odd, even, and empty lists', () {
    check(AdaptiveWarmupDetector.computeMedian([])).equals(0.0);
    check(AdaptiveWarmupDetector.computeMedian([5.0, 1.0, 3.0])).equals(3.0);
    check(AdaptiveWarmupDetector.computeMedian([4.0, 1.0, 3.0, 2.0]))
        .equals(2.5);
    check(AdaptiveWarmupDetector.computeMedian([100.0])).equals(100.0);
  });

  test('computeMad calculates median absolute deviation', () {
    check(AdaptiveWarmupDetector.computeMad([])).equals(0.0);
    final samples = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
    check(AdaptiveWarmupDetector.computeMad(samples)).equals(2.0);
  });

  test('computeSem calculates standard error of the mean', () {
    check(AdaptiveWarmupDetector.computeSem([])).equals(0.0);
    check(AdaptiveWarmupDetector.computeSem([42.0])).equals(0.0);
    check(AdaptiveWarmupDetector.computeSem([10.0, 10.0, 10.0, 10.0]))
        .equals(0.0);

    final values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
    final sem = AdaptiveWarmupDetector.computeSem(values);
    check((sem - 0.7559).abs()).isLessThan(0.001);
  });
}

void _testMmdCalculations() {
  test('computeMmd returns near 0 for identical distributions', () {
    final a = [100.0, 101.0, 99.0, 100.5, 99.5, 100.0, 100.2, 99.8];
    final b = [100.1, 99.9, 100.4, 99.6, 100.0, 100.3, 99.7, 100.1];

    final mmd = AdaptiveWarmupDetector.computeMmd(a, b);
    check(mmd).isLessThan(0.05);
  });

  test('computeMmd returns significant value for shifted distributions', () {
    final a = [1000.0, 950.0, 900.0, 850.0, 800.0];
    final b = [100.0, 101.0, 99.0, 100.5, 99.5];

    final mmd = AdaptiveWarmupDetector.computeMmd(a, b);
    check(mmd).isGreaterThan(0.2);
  });
}

void _testDetectorConvergence() {
  test('AdaptiveWarmupDetector converges on decaying warm sequence', () {
    const config = BenchmarkConfig(
      minWarmupIterations: 10,
      maxWarmupIterations: 100,
    );

    final detector = AdaptiveWarmupDetector(config: config, windowSize: 5);

    for (var i = 0; i < 8; i++) {
      detector.addSample(1000.0 - i * 80.0);
    }

    for (var i = 0; i < 20; i++) {
      detector.addSample(100.0 + (i % 3) * 0.5);
      if (detector.isDone()) break;
    }

    final result = detector.finish();
    check(result.isStable).isTrue();
    check(result.convergedAtIteration).isLessThan(40);
    check(result.bestMmd).isLessOrEqual(0.25);
  });

  test('AdaptiveWarmupDetector triggers SEM steady-state check', () {
    const config = BenchmarkConfig(
      minWarmupIterations: 10,
      maxWarmupIterations: 50,
    );

    final detector = AdaptiveWarmupDetector(config: config, windowSize: 5);

    for (var i = 0; i < 15; i++) {
      detector.addSample(500.0 + (i.isEven ? 1.0 : -1.0));
    }

    final result = detector.finish();
    check(result.isStable).isTrue();
    check(result.convergedAtIteration).isLessOrEqual(15);
  });
}

void _testDetectorFallback() {
  test('AdaptiveWarmupDetector falls back with isStable: false '
      'on budget exhaustion', () {
    final warnings = <String>[];
    final config = BenchmarkConfig(
      minWarmupIterations: 10,
      maxWarmupIterations: 25,
      logger: warnings.add,
    );

    final detector = AdaptiveWarmupDetector(config: config, windowSize: 5);

    for (var i = 0; i < 25; i++) {
      detector.addSample(100.0 + i * 50.0);
    }

    check(detector.isDone()).isTrue();
    final result = detector.finish();

    check(result.isStable).isFalse();
    check(result.totalWarmupIterations).equals(25);
    check(warnings.length).isGreaterThan(0);
    check(warnings.first).contains('Proceeding with isStable: false');
  });
}
