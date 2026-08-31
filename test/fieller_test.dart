import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group("Fieller's Confidence Interval", () {
    test('normalQuantile calculates standard normal inverse CDF', () {
      check((normalQuantile(0.5) - 0.0).abs()).isLessThan(1e-6);
      check((normalQuantile(0.975) - 1.95996).abs()).isLessThan(1e-4);
      check((normalQuantile(0.95) - 1.64485).abs()).isLessThan(1e-4);
      check((normalQuantile(0.99) - 2.32635).abs()).isLessThan(1e-4);
    });

    test('studentTQuantile returns accurate critical values', () {
      // For p = 0.975 (95% CI two-tailed):
      check(studentTQuantile(0.975, 1.0)).equals(12.7062);
      check(studentTQuantile(0.975, 2.0)).equals(4.3027);
      check(studentTQuantile(0.975, 10.0)).equals(2.2281);
      check(studentTQuantile(0.975, 30.0)).equals(2.0423);
      check((studentTQuantile(0.975, 1000.0) - 1.96).abs()).isLessThan(0.01);
    });

    test('calculates exact ratio for zero-variance distributions', () {
      final sampleA = [50.0, 50.0, 50.0];
      final sampleB = [100.0, 100.0, 100.0];

      final fieller = FiellerInterval.compute(
        sampleA: sampleA,
        sampleB: sampleB,
      );

      check(fieller.ratio).equals(0.5);
      check(fieller.lowerBound).equals(0.5);
      check(fieller.upperBound).equals(0.5);
      check(fieller.g).equals(0.0);
      check(fieller.isValid).isTrue();
    });

    test('computes valid bounded 95% CI for realistic benchmark speedups', () {
      // Baseline sample B (mean ~100ns, stddev ~3)
      final sampleB = [98.0, 102.0, 99.0, 101.0, 100.0, 97.0, 103.0, 100.0];
      // Optimized sample A (mean ~50ns, stddev ~2) -> 2x speedup or 0.5 ratio
      final sampleA = [49.0, 51.0, 50.0, 48.0, 52.0, 50.0, 49.5, 50.5];

      final fieller = FiellerInterval.compute(
        sampleA: sampleA,
        sampleB: sampleB,
      );

      check(fieller.isValid).isTrue();
      check(fieller.g).isLessThan(0.05);
      check((fieller.ratio - 0.5).abs()).isLessThan(0.01);
      check(fieller.lowerBound).isLessThan(fieller.ratio);
      check(fieller.upperBound).isGreaterThan(fieller.ratio);
      check(fieller.lowerBound).isGreaterThan(0.4);
      check(fieller.upperBound).isLessThan(0.6);
    });

    test('marks interval invalid (g >= 1.0) when denominator variance is too '
        'high', () {
      // Sample B with mean near 0 or massive noise
      final sampleB = [1.0, -1.0, 2.0, -2.0, 0.5, -0.5];
      final sampleA = [10.0, 11.0, 9.0, 10.5, 9.5];

      final fieller = FiellerInterval.compute(
        sampleA: sampleA,
        sampleB: sampleB,
      );

      check(fieller.isValid).isFalse();
      check(fieller.lowerBound.isInfinite || fieller.lowerBound.isNaN).isTrue();
      check(fieller.upperBound.isInfinite || fieller.upperBound.isNaN).isTrue();
    });

    test('handles empty or zero-mean samples safely', () {
      final emptyA = FiellerInterval.compute(
        sampleA: [],
        sampleB: [100.0, 100.0],
      );
      check(emptyA.isValid).isFalse();

      final zeroB = FiellerInterval.compute(
        sampleA: [50.0, 50.0],
        sampleB: [0.0, 0.0],
      );
      check(zeroB.isValid).isFalse();
    });

    test('toJson serializes FiellerInterval properly', () {
      const fieller = FiellerInterval(
        ratio: 0.5,
        lowerBound: 0.48,
        upperBound: 0.52,
        g: 0.002,
        isValid: true,
      );
      final json = fieller.toJson();

      check(json['ratio']).equals(0.5);
      check(json['lower_bound']).equals(0.48);
      check(json['upper_bound']).equals(0.52);
      check(json['g']).equals(0.002);
      check(json['is_valid']).equals(true);
      check(json['confidence_level']).equals(0.95);
    });

    test('FiellerInterval toString returns formatted string', () {
      const fieller = FiellerInterval(
        ratio: 0.5,
        lowerBound: 0.45,
        upperBound: 0.55,
        g: 0.01,
        isValid: true,
      );

      check(fieller.toString()).contains('FiellerInterval(ratio: 0.500');
      check(fieller.toString()).contains('CI_95%: [0.450, 0.550]');
    });

    test(
      'normalQuantile and studentTQuantile throw on out-of-range inputs',
      () {
        check(() => normalQuantile(0.0)).throws<ArgumentError>();
        check(() => normalQuantile(1.0)).throws<ArgumentError>();
        check(() => normalQuantile(-0.5)).throws<ArgumentError>();
        check(() => normalQuantile(1.5)).throws<ArgumentError>();

        check(() => studentTQuantile(0.5, 10.0)).throws<ArgumentError>();
        check(() => studentTQuantile(1.0, 10.0)).throws<ArgumentError>();
      },
    );

    test('normalQuantile computes accurate extreme lower and upper tails', () {
      // Lower tail (p < 0.02425)
      final lowerZ = normalQuantile(0.001);
      check((lowerZ - (-3.09023)).abs()).isLessThan(1e-4);

      // Upper tail (p > 0.97575)
      final upperZ = normalQuantile(0.999);
      check((upperZ - 3.09023).abs()).isLessThan(1e-4);
    });

    test('studentTQuantile handles df < 1.0 gracefully', () {
      final t = studentTQuantile(0.975, 0.5);
      check((t - 12.7062).abs()).isLessThan(0.01);
    });
  });
}
