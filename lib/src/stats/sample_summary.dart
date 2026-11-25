import 'dart:math' as math;

/// Unit-agnostic descriptive summary statistics for any numeric sample vector.
final class const SampleSummary._({
  /// Number of samples in the series.
  required final int count,

  /// Arithmetic mean of the samples.
  required final double mean,

  /// Median (50th percentile) of the samples.
  required final double median,

  /// Minimum observed value.
  required final double min,

  /// Maximum observed value.
  required final double max,

  /// Sample standard deviation (`n - 1` denominator; `0.0` when `count <= 1`).
  required final double stddev,

  /// Coefficient of variation (`stddev / |mean|`; `0.0` when `mean == 0`).
  required final double cv,

  /// Median Absolute Deviation (`median(|x_i - median|)`).
  required final double mad,

  /// Normal-consistent robust coefficient of variation
  /// (`(1.4826 * mad) / |median|`; `0.0` when `median == 0`).
  required final double robustCv,

  /// Interquartile Range (`Q3 - Q1`).
  required final double iqr,

  /// 95th percentile (linear interpolation).
  required final double p95,

  /// 99th percentile (linear interpolation).
  required final double p99,
}) {
  /// Computes descriptive summary statistics from [samples].
  factory fromSamples(List<num> samples) {
    if (samples.isEmpty) {
      return const SampleSummary._(
        count: 0,
        mean: 0.0,
        median: 0.0,
        min: 0.0,
        max: 0.0,
        stddev: 0.0,
        cv: 0.0,
        mad: 0.0,
        robustCv: 0.0,
        iqr: 0.0,
        p95: 0.0,
        p99: 0.0,
      );
    }

    final sorted = <double>[for (final s in samples) s.toDouble()]..sort();
    final n = sorted.length;
    final mean = meanOfDoubles(sorted);
    final median = medianOfSorted(sorted);
    final min = sorted.first;
    final max = sorted.last;
    final variance = sampleVarianceOfDoubles(sorted, mean);
    final stddev = math.sqrt(variance);
    final absMean = mean.abs();
    final cv = absMean > 0.0 ? stddev / absMean : 0.0;

    final mad = _madFromSorted(sorted, median);
    final absMedian = median.abs();
    final robustCv = absMedian > 0.0 ? (1.4826 * mad) / absMedian : 0.0;

    final q1 = _percentileOfSorted(sorted, 0.25);
    final q3 = _percentileOfSorted(sorted, 0.75);
    final p95 = _percentileOfSorted(sorted, 0.95);
    final p99 = _percentileOfSorted(sorted, 0.99);

    return SampleSummary._(
      count: n,
      mean: mean,
      median: median,
      min: min,
      max: max,
      stddev: stddev,
      cv: cv,
      mad: mad,
      robustCv: robustCv,
      iqr: q3 - q1,
      p95: p95,
      p99: p99,
    );
  }

  @override
  String toString() =>
      'SampleSummary(n: $count, mean: ${mean.toStringAsFixed(3)}, '
      'median: ${median.toStringAsFixed(3)}, '
      'stddev: ${stddev.toStringAsFixed(3)})';
}

/// Computes the arithmetic mean of a non-empty list of doubles, or `0.0` if
/// empty.
double meanOfDoubles(List<double> values) {
  if (values.isEmpty) return 0.0;
  var sum = 0.0;
  for (final v in values) {
    sum += v;
  }
  return sum / values.length;
}

/// Computes the unbiased sample variance (`n - 1` denominator) of [values]
/// given precomputed [mean], or `0.0` when `values.length <= 1`.
double sampleVarianceOfDoubles(List<double> values, double mean) {
  if (values.length <= 1) return 0.0;
  var sumSq = 0.0;
  for (final v in values) {
    final diff = v - mean;
    sumSq += diff * diff;
  }
  return sumSq / (values.length - 1);
}

/// Computes the median of an already-sorted non-empty list.
double medianOfSorted(List<double> sorted) {
  if (sorted.isEmpty) return 0.0;
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2.0;
}

double _madFromSorted(List<double> sorted, double median) {
  if (sorted.isEmpty) return 0.0;
  final deviations = <double>[for (final v in sorted) (v - median).abs()]
    ..sort();
  return medianOfSorted(deviations);
}

double _percentileOfSorted(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0.0;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length - 1) * p;
  final lowIndex = rank.floor();
  final fraction = rank - lowIndex;
  if (lowIndex >= sorted.length - 1) return sorted.last;
  return sorted[lowIndex] +
      fraction * (sorted[lowIndex + 1] - sorted[lowIndex]);
}
