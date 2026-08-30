import 'dart:math' as math;

/// Statistical summary metrics computed from a set of measurement trials.
final class const BenchmarkMetrics({
  /// Arithmetic mean of per-operation latency in nanoseconds.
  required final double meanNs,

  /// Median per-operation latency in nanoseconds (50th percentile).
  required final double medianNs,

  /// Minimum observed latency in nanoseconds.
  ///
  /// Represents the best estimator of true hardware execution speed in the
  /// presence of external scheduling jitter or GC pauses.
  required final double minNs,

  /// Maximum observed latency in nanoseconds.
  required final double maxNs,

  /// Sample standard deviation of per-operation latency in nanoseconds.
  required final double stddevNs,

  /// Coefficient of variation (stddev / mean).
  required final double cv,

  /// 95th percentile latency in nanoseconds.
  required final double p95Ns,

  /// 99th percentile latency in nanoseconds.
  required final double p99Ns,

  /// Operations executed per second (1e9 / meanNs).
  required final double opsPerSec,

  /// Whether the warmup phase reached steady-state convergence before
  /// measurement began.
  required final bool isStable,
}) {
  /// Computes distribution metrics from a list of per-operation latency samples
  /// measured in nanoseconds.
  factory fromSamples(List<double> samplesNs, {bool isStable = true}) {
    if (samplesNs.isEmpty) {
      return BenchmarkMetrics(
        meanNs: 0.0,
        medianNs: 0.0,
        minNs: 0.0,
        maxNs: 0.0,
        stddevNs: 0.0,
        cv: 0.0,
        p95Ns: 0.0,
        p99Ns: 0.0,
        opsPerSec: 0.0,
        isStable: isStable,
      );
    }

    final sorted = List<double>.of(samplesNs)..sort();
    final n = sorted.length;

    var sum = 0.0;
    for (final s in sorted) {
      sum += s;
    }
    final mean = sum / n;

    final median = n.isOdd
        ? sorted[n ~/ 2]
        : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;

    final min = sorted.first;
    final max = sorted.last;

    var sumSqDiff = 0.0;
    for (final s in sorted) {
      final diff = s - mean;
      sumSqDiff += diff * diff;
    }
    final stddev = n > 1 ? math.sqrt(sumSqDiff / (n - 1)) : 0.0;
    final cv = mean > 0.0 ? stddev / mean : 0.0;

    final p95 = _percentile(sorted, 0.95);
    final p99 = _percentile(sorted, 0.99);

    final opsPerSec = mean > 0.0 ? (1e9 / mean) : 0.0;

    return BenchmarkMetrics(
      meanNs: mean,
      medianNs: median,
      minNs: min,
      maxNs: max,
      stddevNs: stddev,
      cv: cv,
      p95Ns: p95,
      p99Ns: p99,
      opsPerSec: opsPerSec,
      isStable: isStable,
    );
  }

  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0.0;
    if (sorted.length == 1) return sorted.first;
    final rank = (sorted.length - 1) * p;
    final lowIndex = rank.floor();
    final fraction = rank - lowIndex;
    if (lowIndex >= sorted.length - 1) return sorted.last;
    return sorted[lowIndex] +
        fraction * (sorted[lowIndex + 1] - sorted[lowIndex]);
  }

  /// Converts the metrics object to a JSON-compatible map conforming to the
  /// canonical bench_press telemetry schema.
  Map<String, Object?> toJson() => {
    'mean_ns': meanNs,
    'median_ns': medianNs,
    'min_ns': minNs,
    'max_ns': maxNs,
    'stddev_ns': stddevNs,
    'cv': cv,
    'p95_ns': p95Ns,
    'p99_ns': p99Ns,
    'ops_per_sec': opsPerSec,
    'is_stable': isStable,
  };

  /// Constructs a [BenchmarkMetrics] instance from a JSON-compatible map.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'mean_ns': final num mean,
      'median_ns': final num median,
      'min_ns': final num min,
      'max_ns': final num max,
      'stddev_ns': final num stddev,
      'cv': final num cv,
      'p95_ns': final num p95,
      'p99_ns': final num p99,
      'ops_per_sec': final num opsPerSec,
    }) {
      return BenchmarkMetrics(
        meanNs: mean.toDouble(),
        medianNs: median.toDouble(),
        minNs: min.toDouble(),
        maxNs: max.toDouble(),
        stddevNs: stddev.toDouble(),
        cv: cv.toDouble(),
        p95Ns: p95.toDouble(),
        p99Ns: p99.toDouble(),
        opsPerSec: opsPerSec.toDouble(),
        isStable: (json['is_stable'] as bool?) ?? true,
      );
    }
    throw const FormatException('Invalid or incomplete BenchmarkMetrics JSON');
  }

  @override
  String toString() =>
      'BenchmarkMetrics(mean: ${meanNs.toStringAsFixed(1)} ns, '
      'median: ${medianNs.toStringAsFixed(1)} ns, '
      'min: ${minNs.toStringAsFixed(1)} ns, '
      'ops/s: ${opsPerSec.toStringAsFixed(0)}, '
      'stable: $isStable)';
}
