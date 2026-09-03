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

  /// Median Absolute Deviation (MAD) in nanoseconds.
  final double madNs = 0.0,

  /// Robust coefficient of variation ((1.4826 * madNs) / medianNs).
  final double robustCv = 0.0,

  /// Interquartile Range (Q3 - Q1) in nanoseconds.
  final double iqrNs = 0.0,

  /// Whether the distribution satisfies robust steady-state stability
  /// criteria (robustCv <= maxCvThreshold), resilient to transient GC spikes.
  final bool isRobustStable = true,

  /// 95th percentile latency in nanoseconds.
  required final double p95Ns,

  /// 99th percentile latency in nanoseconds.
  required final double p99Ns,

  /// Operations executed per second (1e9 / meanNs).
  required final double opsPerSec,

  /// Whether the warmup phase reached steady-state convergence before
  /// measurement began and measurement distribution is stable.
  required final bool isStable,
}) {
  /// Maximum acceptable Coefficient of Variation (CV) for a benchmark to be
  /// considered stable (default: 5%).
  static const double maxCvThreshold = 0.05;

  /// Computes distribution metrics from a list of per-operation latency samples
  /// measured in nanoseconds.
  factory fromSamples(
    List<double> samplesNs, {
    bool isStable = true,
    double maxCvThreshold = BenchmarkMetrics.maxCvThreshold,
  }) {
    if (samplesNs.isEmpty) {
      return BenchmarkMetrics(
        meanNs: 0.0,
        medianNs: 0.0,
        minNs: 0.0,
        maxNs: 0.0,
        stddevNs: 0.0,
        cv: 0.0,
        madNs: 0.0,
        robustCv: 0.0,
        iqrNs: 0.0,
        isRobustStable: isStable,
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

    final mad = computeMad(sorted);
    final robustCv = median > 0.0 ? (1.4826 * mad) / median : 0.0;

    final q1 = _percentile(sorted, 0.25);
    final q3 = _percentile(sorted, 0.75);
    final iqr = q3 - q1;

    final p95 = _percentile(sorted, 0.95);
    final p99 = _percentile(sorted, 0.99);

    final opsPerSec = mean > 0.0 ? (1e9 / mean) : 0.0;

    final robustStable =
        isStable && (robustCv <= maxCvThreshold || cv <= maxCvThreshold);
    final effectiveStable = isStable && (cv <= maxCvThreshold || robustStable);

    return BenchmarkMetrics(
      meanNs: mean,
      medianNs: median,
      minNs: min,
      maxNs: max,
      stddevNs: stddev,
      cv: cv,
      madNs: mad,
      robustCv: robustCv,
      iqrNs: iqr,
      isRobustStable: robustStable,
      p95Ns: p95,
      p99Ns: p99,
      opsPerSec: opsPerSec,
      isStable: effectiveStable,
    );
  }

  /// Calculates the Median Absolute Deviation (MAD) of a sequence.
  static double computeMad(List<double> values) {
    if (values.isEmpty) return 0.0;
    final med = computeMedian(values);
    final deviations = values.map((v) => (v - med).abs()).toList();
    return computeMedian(deviations);
  }

  /// Calculates the median of a sequence.
  static double computeMedian(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.of(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// Calculates the Interquartile Range (IQR = Q3 - Q1) of a sequence.
  static double computeIqr(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.of(values)..sort();
    final q1 = _percentile(sorted, 0.25);
    final q3 = _percentile(sorted, 0.75);
    return q3 - q1;
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
    'mad_ns': madNs,
    'robust_cv': robustCv,
    'iqr_ns': iqrNs,
    'is_robust_stable': isRobustStable,
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
      final isStable = (json['is_stable'] as bool?) ?? true;
      final isRobustStable = (json['is_robust_stable'] as bool?) ?? isStable;
      return BenchmarkMetrics(
        meanNs: mean.toDouble(),
        medianNs: median.toDouble(),
        minNs: min.toDouble(),
        maxNs: max.toDouble(),
        stddevNs: stddev.toDouble(),
        cv: cv.toDouble(),
        madNs: ((json['mad_ns'] ?? json['mad']) as num?)?.toDouble() ?? 0.0,
        robustCv: (json['robust_cv'] as num?)?.toDouble() ?? 0.0,
        iqrNs: ((json['iqr_ns'] ?? json['iqr']) as num?)?.toDouble() ?? 0.0,
        isRobustStable: isRobustStable,
        p95Ns: p95.toDouble(),
        p99Ns: p99.toDouble(),
        opsPerSec: opsPerSec.toDouble(),
        isStable: isStable,
      );
    }
    throw const FormatException('Invalid or incomplete BenchmarkMetrics JSON');
  }

  @override
  String toString() =>
      'BenchmarkMetrics(mean: ${meanNs.toStringAsFixed(1)} ns, '
      'median: ${medianNs.toStringAsFixed(1)} ns, '
      'min: ${minNs.toStringAsFixed(1)} ns, '
      'mad: ${madNs.toStringAsFixed(1)} ns, '
      'ops/s: ${opsPerSec.toStringAsFixed(0)}, '
      'stable: $isStable)';
}
