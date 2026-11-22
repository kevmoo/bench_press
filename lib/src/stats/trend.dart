import 'dart:math' as math;

import 'fieller.dart';
import 'sample_summary.dart';

/// Ordinary least-squares linear trend fitted to a sequential sample series
/// (`index = 0 .. count - 1`) for monotonic session drift detection.
final class const LinearTrend({
  /// Number of observations in the fitted series (`>= 3`).
  required final int count,

  /// Arithmetic mean of the observations.
  required final double mean,

  /// Estimated linear change per step (index increment).
  required final double slope,

  /// Two-sided confidence interval half-width for [slope].
  required final double slopeHalfWidth,

  /// Residual degrees of freedom (`count - 2`).
  required final double degreesOfFreedom,

  /// Nominal two-sided confidence level (default: `0.95`).
  final double confidenceLevel = 0.95,
}) {
  /// Fits an OLS straight line to [values] against `0 .. values.length - 1`.
  ///
  /// Throws [ArgumentError] if `values.length < 3` or [confidenceLevel] is
  /// outside `(0, 1)`.
  factory compute(List<num> values, {double confidenceLevel = 0.95}) {
    if (values.length < 3) {
      throw ArgumentError.value(
        values.length,
        'values',
        'LinearTrend requires at least 3 samples.',
      );
    }
    if (confidenceLevel <= 0.0 ||
        confidenceLevel >= 1.0 ||
        confidenceLevel.isNaN) {
      throw ArgumentError.value(
        confidenceLevel,
        'confidenceLevel',
        'Confidence level must be strictly in (0, 1).',
      );
    }

    final y = <double>[for (final v in values) v.toDouble()];
    final n = y.length;
    final xMean = (n - 1) / 2.0;
    final yMean = meanOfDoubles(y);

    var sxx = 0.0;
    var sxy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = i - xMean;
      sxx += dx * dx;
      sxy += dx * (y[i] - yMean);
    }

    final slope = sxy / sxx;
    var sse = 0.0;
    for (var i = 0; i < n; i++) {
      final residual = y[i] - (yMean + slope * (i - xMean));
      sse += residual * residual;
    }

    final df = (n - 2).toDouble();
    final residualVar = math.max(0.0, sse / df);
    final slopeSe = math.sqrt(residualVar / sxx);
    final p = 1.0 - (1.0 - confidenceLevel) / 2.0;
    final halfWidth = slopeSe == 0.0 ? 0.0 : studentTQuantile(p, df) * slopeSe;

    return LinearTrend(
      count: n,
      mean: yMean,
      slope: slope,
      slopeHalfWidth: halfWidth,
      degreesOfFreedom: df,
      confidenceLevel: confidenceLevel,
    );
  }

  /// Estimated total percentage drift across the series from first to last
  /// sample (`slope * (count - 1) * 100 / mean`), or `null` when `mean == 0`.
  double? get percentChangeOverSeries =>
      mean == 0.0 ? null : slope * (count - 1) * 100.0 / mean;

  /// Confidence interval half-width for [percentChangeOverSeries], or `null`
  /// when `mean == 0`.
  double? get percentHalfWidthOverSeries =>
      mean == 0.0 ? null : (slopeHalfWidth * (count - 1) * 100.0 / mean).abs();

  /// Whether the confidence interval for [slope] strictly excludes zero.
  bool get isSignificant => slopeHalfWidth < slope.abs();

  /// Converts this trend result to a JSON-compatible map.
  Map<String, Object?> toJson() => {
    'count': count,
    'mean': mean,
    'slope': slope,
    'slope_half_width': slopeHalfWidth,
    'degrees_of_freedom': degreesOfFreedom,
    'confidence_level': confidenceLevel,
  };

  /// Reconstructs a [LinearTrend] from a JSON map.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'count': final int count,
      'mean': final num mean,
      'slope': final num slope,
      'slope_half_width': final num halfWidth,
      'degrees_of_freedom': final num df,
    }) {
      final conf = (json['confidence_level'] as num?)?.toDouble() ?? 0.95;
      return LinearTrend(
        count: count,
        mean: mean.toDouble(),
        slope: slope.toDouble(),
        slopeHalfWidth: halfWidth.toDouble(),
        degreesOfFreedom: df.toDouble(),
        confidenceLevel: conf,
      );
    }
    throw const FormatException('Invalid or incomplete LinearTrend JSON');
  }

  @override
  String toString() =>
      'LinearTrend(n: $count, slope: ${slope.toStringAsFixed(4)} ± '
      '${slopeHalfWidth.toStringAsFixed(4)}, significant: $isSignificant)';
}

/// Computes the per-comparison confidence level `1 - familyAlpha / comparisons`
/// under the Bonferroni correction so the family-wise false-positive rate
/// across [comparisons] metrics is at most [familyAlpha] (`0.05` by default).
double bonferroniConfidenceLevel(int comparisons, {double familyAlpha = 0.05}) {
  if (familyAlpha <= 0.0 || familyAlpha >= 1.0 || familyAlpha.isNaN) {
    throw ArgumentError.value(
      familyAlpha,
      'familyAlpha',
      'Family-wise alpha must be strictly in (0, 1).',
    );
  }
  if (comparisons <= 1) return 1.0 - familyAlpha;
  return 1.0 - (familyAlpha / comparisons);
}
