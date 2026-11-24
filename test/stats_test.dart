import 'dart:math' as math;

import 'package:bench_press/src/stats/difference.dart'
    show InternalDifferenceInterval;
import 'package:bench_press/src/stats/fieller.dart' show studentTQuantile;
import 'package:bench_press/stats.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('BenchmarkMetrics Distribution Statistics', () {
    test('handles empty sample lists gracefully', () {
      final metrics = BenchmarkMetrics.fromSamples([]);
      check(metrics.meanNs).equals(0.0);
      check(metrics.medianNs).equals(0.0);
      check(metrics.minNs).equals(0.0);
      check(metrics.maxNs).equals(0.0);
      check(metrics.stddevNs).equals(0.0);
      check(metrics.cv).equals(0.0);
      check(metrics.p95Ns).equals(0.0);
      check(metrics.p99Ns).equals(0.0);
      check(metrics.opsPerSec).equals(0.0);
      check(metrics.isStable).isTrue;
    });

    test('computes correct statistics for single sample', () {
      final metrics = BenchmarkMetrics.fromSamples([500.0], isStable: false);
      check(metrics.meanNs).equals(500.0);
      check(metrics.medianNs).equals(500.0);
      check(metrics.minNs).equals(500.0);
      check(metrics.maxNs).equals(500.0);
      check(metrics.stddevNs).equals(0.0);
      check(metrics.cv).equals(0.0);
      check(metrics.p95Ns).equals(500.0);
      check(metrics.p99Ns).equals(500.0);
      check(metrics.opsPerSec).equals(2000000.0);
      check(metrics.isStable).isFalse;
    });

    test('computes accurate metrics on known distribution', () {
      // 10 samples: [100, 102, 98, 105, 95, 101, 99, 100, 104, 96]
      final samples = [
        100.0,
        102.0,
        98.0,
        105.0,
        95.0,
        101.0,
        99.0,
        100.0,
        104.0,
        96.0,
      ];
      final metrics = BenchmarkMetrics.fromSamples(samples, isStable: true);

      check(metrics.meanNs).equals(100.0);
      check(metrics.minNs).equals(95.0);
      check(metrics.maxNs).equals(105.0);
      check(metrics.medianNs).equals(100.0);

      // Variance = sum( (x - 100)^2 ) / 9
      // = (0+4+4+25+25+1+1+0+16+16)/9 = 92/9 = 10.222... stddev = 3.1972...
      check((metrics.stddevNs - 3.1972).abs()).isLessThan(0.001);
      check((metrics.cv - 0.03197).abs()).isLessThan(0.0001);

      // Ops/sec for 100ns = 1e9 / 100 = 10,000,000 ops/s
      check(metrics.opsPerSec).equals(10000000.0);
      check(metrics.isStable).isTrue;

      // Percentiles: sorted is [95, 96, 98, 99, 100, 100, 101, 102, 104, 105]
      // p95 rank = 9 * 0.95 = 8.55
      // -> sorted[8] + 0.55 * (sorted[9] - sorted[8]) = 104 + 0.55 * 1 = 104.55
      check((metrics.p95Ns - 104.55).abs()).isLessThan(0.01);
      // p99 rank = 9 * 0.99 = 8.91 -> 104 + 0.91 * 1 = 104.91
      check((metrics.p99Ns - 104.91).abs()).isLessThan(0.01);
    });

    test('toJson serializes with canonical schema keys', () {
      final metrics = BenchmarkMetrics.fromSamples([412.5], isStable: true);
      final json = metrics.toJson();

      check(json['mean_ns']).equals(412.5);
      check(json['median_ns']).equals(412.5);
      check(json['min_ns']).equals(412.5);
      check(json['max_ns']).equals(412.5);
      check(json['stddev_ns']).equals(0.0);
      check(json['cv']).equals(0.0);
      check(json['mad_ns']).equals(0.0);
      check(json['robust_cv']).equals(0.0);
      check(json['iqr_ns']).equals(0.0);
      check(json['is_robust_stable']).equals(true);
      check(json['p95_ns']).equals(412.5);
      check(json['p99_ns']).equals(412.5);
      check(json['ops_per_sec']).equals(1e9 / 412.5);
      check(json['is_stable']).equals(true);

      final deserialized = BenchmarkMetrics.fromJson(json);
      check(deserialized.madNs).equals(0.0);
      check(deserialized.robustCv).equals(0.0);
      check(deserialized.iqrNs).equals(0.0);
      check(deserialized.isRobustStable).isTrue;
      check(deserialized.isStable).isTrue;
    });

    test(
      'computes accurate robust dispersion metrics (MAD, robust CV, IQR)',
      () {
        final samples = [
          100.0,
          102.0,
          98.0,
          105.0,
          95.0,
          101.0,
          99.0,
          100.0,
          104.0,
          96.0,
        ];
        final metrics = BenchmarkMetrics.fromSamples(samples, isStable: true);

        check(metrics.madNs).equals(2.0);
        check((metrics.robustCv - 0.02965).abs()).isLessThan(0.0001);
        check((metrics.iqrNs - 3.5).abs()).isLessThan(0.01);
        check(metrics.isRobustStable).isTrue;
        check(metrics.isStable).isTrue;
      },
    );

    test(
      'demonstrates robust stability on GC-like bimodal spike distribution',
      () {
        // 13 normal trials at 100ns, 2 major GC pause spikes at 500ns
        final gcSamples = [...List<double>.filled(13, 100.0), 500.0, 500.0];
        final metrics = BenchmarkMetrics.fromSamples(gcSamples, isStable: true);

        // Standard CV is severely inflated by the bimodal GC spikes
        check(metrics.cv).isGreaterThan(0.5);

        // Robust metrics reflect steady-state consistency
        check(metrics.medianNs).equals(100.0);
        check(metrics.madNs).equals(0.0);
        check(metrics.robustCv).equals(0.0);
        check(metrics.iqrNs).equals(0.0);
        check(metrics.isRobustStable).isTrue;
        check(metrics.isStable).isTrue;
      },
    );

    test('correctly labels high noise or drift as unstable', () {
      final noisySamples = [
        50.0,
        150.0,
        75.0,
        125.0,
        60.0,
        140.0,
        80.0,
        120.0,
        90.0,
        110.0,
      ];
      final metrics = BenchmarkMetrics.fromSamples(
        noisySamples,
        isStable: true,
      );

      check(metrics.robustCv).isGreaterThan(0.05);
      check(metrics.isRobustStable).isFalse;
      check(metrics.isStable).isFalse;
    });

    test('propagates warmup instability to robust stability', () {
      final metrics = BenchmarkMetrics.fromSamples([
        100.0,
        100.0,
        100.0,
      ], isStable: false);
      check(metrics.isRobustStable).isFalse;
      check(metrics.isStable).isFalse;
    });

    test('computes static computeMad and computeIqr helpers', () {
      check(BenchmarkMetrics.computeMad([])).equals(0.0);
      check(BenchmarkMetrics.computeMad([1.0, 2.0, 3.0, 4.0, 5.0])).equals(1.0);
      check(BenchmarkMetrics.computeIqr([])).equals(0.0);
      check(BenchmarkMetrics.computeIqr([1.0, 2.0, 3.0, 4.0, 5.0])).equals(2.0);
    });

    test(
      'ProcessVarianceComponents.compute uses drift-immune first differences '
      'and BenchmarkMetrics.fromProcesses attaches varianceComponents',
      () {
        check(ProcessVarianceComponents.compute([])).isNull;
        check(
          ProcessVarianceComponents.compute([
            [100.0, 101.0],
          ]),
        ).isNull;
        // 1 trial per process -> 0 within-process degrees of freedom -> null.
        check(
          ProcessVarianceComponents.compute([
            [100.0],
            [110.0],
          ]),
        ).isNull;

        // msBetween < msWithin clamps varBetween and betweenProcessShare to 0.
        final clamped = ProcessVarianceComponents.compute([
          [90.0, 110.0, 90.0, 110.0],
          [90.0, 110.0, 90.0, 110.0],
        ])!;
        check(clamped.msBetween).equals(0.0);
        check(clamped.msWithin).equals(200.0);
        check(clamped.varBetween).equals(0.0);
        check(clamped.betweenProcessShare).equals(0.0);

        // Unbalanced trial counts (N_1 = 2 at mean 100, N_2 = 6 at mean 200):
        // weighted grand mean = (200 + 1200) / 8 = 175.0,
        // SS_between = 2 * (-75)^2 + 6 * (25)^2 = 11250 + 3750 = 15000,
        // k0 = (8 - (4 + 36) / 8) / 1 = 3.0.
        final unbalanced = ProcessVarianceComponents.compute([
          [99.0, 101.0],
          [199.0, 201.0, 199.0, 201.0, 199.0, 201.0],
        ])!;
        check((unbalanced.msBetween - 15000.0).abs()).isLessThan(1e-9);
        check((unbalanced.msWithin - 2.0).abs()).isLessThan(1e-9);
        check((unbalanced.varBetween - ((15000.0 - 2.0) / 3.0)).abs())
            .isLessThan(1e-9);

        // 3 processes with distinct process offsets (+0, +10, +20 ns) and
        // tiny step-to-step differences (alternating ±1 ns => diff = ±2 ns,
        // so msWithin = 0.5 * 4 = 2.0).
        final processTrials = [
          [99.5, 100.5, 99.5, 100.5],
          [109.5, 110.5, 109.5, 110.5],
          [119.5, 120.5, 119.5, 120.5],
        ];
        final metrics = BenchmarkMetrics.fromProcesses(processTrials);
        check((metrics.meanNs - 110.0).abs()).isLessThan(1e-9);
        check((metrics.stddevNs - 10.0).abs()).isLessThan(1e-9);

        final vc = metrics.varianceComponents;
        check(vc).isNotNull();
        check(vc!.processes).equals(3);
        check(vc.meanTrialsPerProcess).equals(4.0);
        check((vc.msWithin - 0.5).abs()).isLessThan(1e-9);
        check((vc.msBetween - 400.0).abs()).isLessThan(1e-9);
        check((vc.varBetween - 99.875).abs()).isLessThan(1e-9);
        check(vc.betweenProcessShare).isGreaterThan(0.99);
        check(vc.toString()).contains('ProcessVarianceComponents(processes: 3');

        final roundTrip = BenchmarkMetrics.fromJson(metrics.toJson());
        check(roundTrip.varianceComponents).isNotNull();
        check(roundTrip.varianceComponents!.processes).equals(3);
        check(
          (roundTrip.varianceComponents!.betweenProcessShare -
                  vc.betweenProcessShare)
              .abs(),
        ).isLessThan(1e-9);

        check(BenchmarkMetrics.fromProcesses([]).meanNs).equals(0.0);
        check(
          BenchmarkMetrics.fromProcesses([
            [50.0, 50.0],
          ]).varianceComponents,
        ).isNull;
      },
    );
  });

  group('Toolkit stats.dart', () {
    test('SampleSummary handles empty, single, and signed sample series', () {
      final empty = SampleSummary.fromSamples(const []);
      check(empty.count).equals(0);
      check(empty.mean).equals(0.0);
      check(empty.cv).equals(0.0);

      final single = SampleSummary.fromSamples(const [42]);
      check(single.count).equals(1);
      check(single.mean).equals(42.0);
      check(single.stddev).equals(0.0);

      // Signed series verifies cv and robustCv normalize by |mean|/|median|.
      final signed = SampleSummary.fromSamples(const [-110, -100, -90]);
      check(signed.count).equals(3);
      check(signed.mean).equals(-100.0);
      check(signed.median).equals(-100.0);
      check(signed.stddev).equals(10.0);
      check(signed.cv).isCloseTo(0.10, 1e-12);
      check(signed.mad).equals(10.0);
      check(signed.robustCv).isCloseTo(0.14826, 1e-12);
    });

    test('DifferenceInterval cancels shared drift in paired mode', () {
      // Shared per-round drift [0, +50, +100, +150] plus +250 ms overhead with
      // small ±2 ms jitter: unpaired variance is huge; paired variance is tiny.
      final baseline = [200.0, 250.0, 300.0, 350.0];
      final candidate = [448.0, 502.0, 552.0, 598.0];

      final unpaired = DifferenceInterval.compute(
        baseline: baseline,
        candidate: candidate,
      );
      final paired = DifferenceInterval.compute(
        baseline: baseline,
        candidate: candidate,
        paired: true,
      );

      check(paired.isValid).isTrue;
      check(paired.paired).isTrue;
      check(paired.meanDiff).isCloseTo(250.0, 1e-9);
      // Sample medians are 275.0 and 527.0 (527 - 275 = 252.0), whereas the
      // median of pairwise differences [248, 252, 252, 248] is 250.0.
      check(paired.medianDiff).isCloseTo(252.0, 1e-9);
      check(paired.pairedMedianDiff!).isCloseTo(250.0, 1e-9);
      check(paired.degreesOfFreedom).equals(3.0);
      // Pairwise diffs: [248, 252, 252, 248] -> sample variance = 16/3,
      // SE = sqrt(16/3) / 2 = 2 / sqrt(3).
      check(paired.standardError).isCloseTo(2.0 / math.sqrt(3.0), 1e-9);
      check(paired.halfWidth).isLessThan(unpaired.halfWidth / 10.0);
      check(paired.isSignificant).isTrue;
      check(paired.percentDiff!).isCloseTo((250.0 / 275.0) * 100.0, 1e-9);
    });

    test('DifferenceInterval uses Welch-Satterthwaite for unequal n', () {
      // Heteroscedastic: zero-variance control (n=3) vs noisy candidate (n=5).
      // Exact Welch-Satterthwaite df must equal nB - 1 = 4.0.
      final baseline = [100.0, 100.0, 100.0];
      final candidate = [88.0, 89.0, 90.0, 91.0, 92.0];

      final diff = DifferenceInterval.compute(
        baseline: baseline,
        candidate: candidate,
        paired: true, // unequal length -> automatically falls back to unpaired
      );

      check(diff.isValid).isTrue;
      check(diff.paired).isFalse;
      check(diff.meanDiff).isCloseTo(-10.0, 1e-9);
      check(diff.degreesOfFreedom).isCloseTo(4.0, 1e-9);
      check(diff.upperBound).isLessThan(0.0);
      check(diff.isSignificant).isTrue;
    });

    test('DifferenceInterval handles edge cases and TOST equivalence', () {
      // n < 2 -> invalid
      final tooFew = DifferenceInterval.compute(
        baseline: const [100.0],
        candidate: const [110.0, 112.0],
      );
      check(tooFew.isValid).isFalse;
      check(tooFew.lowerBound.isNaN).isTrue;
      check(tooFew.isEquivalentWithin(50.0)).isFalse;

      // Zero variance on both arms -> exact zero-width valid interval
      final constant = DifferenceInterval.compute(
        baseline: const [100.0, 100.0, 100.0],
        candidate: const [101.0, 101.0, 101.0],
      );
      check(constant.isValid).isTrue;
      check(constant.halfWidth).equals(0.0);
      check(constant.isEquivalentWithin(2.0)).isTrue;
      check(constant.isEquivalentWithin(0.5)).isFalse;

      // TOST equivalence at 90% CI vs 95% CI boundary
      final nearZero = DifferenceInterval.compute(
        baseline: const [100.0, 101.0, 99.0, 100.0, 100.5, 99.5],
        candidate: const [100.5, 101.5, 99.5, 100.5, 101.0, 100.0],
        paired: true,
      );
      // Constant +0.5 shift -> zero diff variance -> exact +0.5
      check(nearZero.isEquivalentWithin(1.0)).isTrue;
      check(nearZero.isEquivalentWithin(0.25)).isFalse;

      check(
        () => DifferenceInterval.compute(
          baseline: const [1, 2],
          candidate: const [1, 2],
          confidenceLevel: 1.0,
        ),
      ).throws<ArgumentError>();
    });

    test('studentTQuantile precision', () {
      // Newton-polished studentTQuantile matches exact R qt() to < 1e-12
      check(studentTQuantile(0.975, 3.0)).isCloseTo(3.182446305283763, 1e-12);
      check(studentTQuantile(0.975, 4.0)).isCloseTo(2.7764451051977987, 1e-12);
      check(studentTQuantile(0.975, double.infinity)).isCloseTo(1.95996, 1e-4);
    });
  });
}
