import 'package:bench_press/bench_press.dart';
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
      check(metrics.isStable).isTrue();
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
      check(metrics.isStable).isFalse();
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
      check(metrics.isStable).isTrue();

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
      check(deserialized.mad).equals(0.0);
      check(deserialized.robustCv).equals(0.0);
      check(deserialized.iqrNs).equals(0.0);
      check(deserialized.iqr).equals(0.0);
      check(deserialized.isRobustStable).isTrue();
      check(deserialized.isStable).isTrue();
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
        check(metrics.mad).equals(2.0);
        check((metrics.robustCv - 0.02965).abs()).isLessThan(0.0001);
        check((metrics.iqrNs - 3.5).abs()).isLessThan(0.01);
        check((metrics.iqr - 3.5).abs()).isLessThan(0.01);
        check(metrics.isRobustStable).isTrue();
        check(metrics.isStable).isTrue();
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
        check(metrics.mad).equals(0.0);
        check(metrics.robustCv).equals(0.0);
        check(metrics.iqrNs).equals(0.0);
        check(metrics.isRobustStable).isTrue();
        check(metrics.isStable).isTrue();
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
      check(metrics.isRobustStable).isFalse();
      check(metrics.isStable).isFalse();
    });

    test('propagates warmup instability to robust stability', () {
      final metrics = BenchmarkMetrics.fromSamples([
        100.0,
        100.0,
        100.0,
      ], isStable: false);
      check(metrics.isRobustStable).isFalse();
      check(metrics.isStable).isFalse();
    });

    test('computes static computeMad and computeIqr helpers', () {
      check(BenchmarkMetrics.computeMad([])).equals(0.0);
      check(BenchmarkMetrics.computeMad([1.0, 2.0, 3.0, 4.0, 5.0])).equals(1.0);
      check(BenchmarkMetrics.computeIqr([])).equals(0.0);
      check(BenchmarkMetrics.computeIqr([1.0, 2.0, 3.0, 4.0, 5.0])).equals(2.0);
    });
  });
}
