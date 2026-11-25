import 'dart:math' as math;

import 'fieller.dart';
import 'sample_summary.dart';

/// Additive Student/Welch $t$ confidence interval for `candidate - baseline`.
///
/// When [paired] is `true` and `baseline.length == candidate.length`, computes
/// the paired $t$-interval over per-round differences
/// `d_i = candidate[i] - baseline[i]` with `df = n - 1`, cancelling shared
/// per-round host drift. Otherwise uses the heteroscedastic Welch-Satterthwaite
/// two-sample $t$-interval.
final class const DifferenceInterval._({
  /// Arithmetic mean of the baseline series.
  required final double baselineMean,

  /// Arithmetic mean of the candidate series.
  required final double candidateMean,

  /// Estimated additive change (`candidateMean - baselineMean`).
  required final double meanDiff,

  /// Difference of sample medians (`median(candidate) - median(baseline)`).
  required final double medianDiff,

  /// Median of pairwise differences `candidate[i] - baseline[i]` when [paired]
  /// is `true`, or `null` when unpaired.
  final double? pairedMedianDiff,

  /// Lower bound of the confidence interval for [meanDiff].
  required final double lowerBound,

  /// Upper bound of the confidence interval for [meanDiff].
  required final double upperBound,

  /// Half-width (`t * standardError`) of the confidence interval.
  required final double halfWidth,

  /// Standard error of [meanDiff].
  required final double standardError,

  /// Degrees of freedom (`n - 1` when paired, Welch-Satterthwaite when
  /// unpaired).
  required final double degreesOfFreedom,

  /// Sample standard deviation of pairwise differences when [paired] is `true`,
  /// or `null` when unpaired.
  final double? diffStddev,

  /// Whether the confidence interval is finite and valid (`n >= 2` per arm and
  /// finite inputs).
  required final bool isValid,

  /// Nominal two-sided confidence level (default: `0.95`).
  final double confidenceLevel = 0.95,

  /// Whether this interval was computed from paired per-round differences.
  final bool paired = false,
}) {
  /// Computes an additive confidence interval for `candidate - baseline`.
  factory compute({
    required List<num> baseline,
    required List<num> candidate,
    double confidenceLevel = 0.95,
    bool paired = false,
  }) {
    if (confidenceLevel <= 0.0 ||
        confidenceLevel >= 1.0 ||
        confidenceLevel.isNaN) {
      throw ArgumentError.value(
        confidenceLevel,
        'confidenceLevel',
        'Confidence level must be strictly in (0, 1).',
      );
    }

    final a = <double>[for (final v in baseline) v.toDouble()];
    final b = <double>[for (final v in candidate) v.toDouble()];
    final nA = a.length;
    final nB = b.length;
    final usePaired = paired && nA == nB;

    if (nA < 2 || nB < 2 || !_allFinite(a) || !_allFinite(b)) {
      return _invalidInterval(a, b, confidenceLevel, usePaired);
    }

    final baseSummary = SampleSummary.fromSamples(a);
    final candSummary = SampleSummary.fromSamples(b);
    final medDiff = candSummary.median - baseSummary.median;

    final (:meanDiff, :se, :df, :diffSd, :pairedMed) = usePaired
        ? _computePairedStats(a, b)
        : _computeUnpairedStats(a, b, baseSummary.mean, candSummary.mean);

    if (se == 0.0) {
      return DifferenceInterval._(
        baselineMean: baseSummary.mean,
        candidateMean: candSummary.mean,
        meanDiff: meanDiff,
        medianDiff: medDiff,
        pairedMedianDiff: pairedMed,
        lowerBound: meanDiff,
        upperBound: meanDiff,
        halfWidth: 0.0,
        standardError: 0.0,
        degreesOfFreedom: df,
        diffStddev: diffSd,
        isValid: true,
        confidenceLevel: confidenceLevel,
        paired: usePaired,
      );
    }

    final p = 1.0 - (1.0 - confidenceLevel) / 2.0;
    final t = studentTQuantile(p, df);
    final hw = t * se;

    return DifferenceInterval._(
      baselineMean: baseSummary.mean,
      candidateMean: candSummary.mean,
      meanDiff: meanDiff,
      medianDiff: medDiff,
      pairedMedianDiff: pairedMed,
      lowerBound: meanDiff - hw,
      upperBound: meanDiff + hw,
      halfWidth: hw,
      standardError: se,
      degreesOfFreedom: df,
      diffStddev: diffSd,
      isValid: hw.isFinite,
      confidenceLevel: confidenceLevel,
      paired: usePaired,
    );
  }

  static bool _allFinite(List<double> values) {
    for (final v in values) {
      if (!v.isFinite) return false;
    }
    return true;
  }

  static DifferenceInterval _invalidInterval(
    List<double> a,
    List<double> b,
    double confidenceLevel,
    bool usePaired,
  ) {
    final hasValidMeans =
        a.isNotEmpty && b.isNotEmpty && _allFinite(a) && _allFinite(b);
    final baseSummary = hasValidMeans ? SampleSummary.fromSamples(a) : null;
    final candSummary = hasValidMeans ? SampleSummary.fromSamples(b) : null;
    final baseMean = baseSummary?.mean ?? double.nan;
    final candMean = candSummary?.mean ?? double.nan;
    return DifferenceInterval._(
      baselineMean: baseMean,
      candidateMean: candMean,
      meanDiff: hasValidMeans ? candMean - baseMean : double.nan,
      medianDiff: hasValidMeans
          ? candSummary!.median - baseSummary!.median
          : double.nan,
      lowerBound: double.nan,
      upperBound: double.nan,
      halfWidth: double.nan,
      standardError: double.nan,
      degreesOfFreedom: double.nan,
      isValid: false,
      confidenceLevel: confidenceLevel,
      paired: usePaired,
    );
  }

  static ({
    double meanDiff,
    double se,
    double df,
    double? diffSd,
    double? pairedMed,
  })
  _computePairedStats(List<double> a, List<double> b) {
    final n = a.length;
    final diffs = <double>[for (var i = 0; i < n; i++) b[i] - a[i]];
    final meanDiff = meanOfDoubles(diffs);
    final diffVar = sampleVarianceOfDoubles(diffs, meanDiff);
    final diffSd = math.sqrt(diffVar);
    final sortedDiffs = List<double>.of(diffs)..sort();
    return (
      meanDiff: meanDiff,
      se: diffSd / math.sqrt(n),
      df: (n - 1.0).clamp(1.0, 10000.0),
      diffSd: diffSd,
      pairedMed: medianOfSorted(sortedDiffs),
    );
  }

  static ({
    double meanDiff,
    double se,
    double df,
    double? diffSd,
    double? pairedMed,
  })
  _computeUnpairedStats(
    List<double> a,
    List<double> b,
    double meanA,
    double meanB,
  ) {
    final vA = sampleVarianceOfDoubles(a, meanA) / a.length;
    final vB = sampleVarianceOfDoubles(b, meanB) / b.length;
    final df = computeComparisonDegreesOfFreedom(
      nA: a.length,
      nB: b.length,
      vA: vA,
      vB: vB,
      usePaired: false,
    );
    return (
      meanDiff: meanB - meanA,
      se: math.sqrt(vA + vB),
      df: df,
      diffSd: null,
      pairedMed: null,
    );
  }

  /// [meanDiff] expressed as a percentage of [baselineMean], or `null` if
  /// [baselineMean] is zero or non-finite.
  double? get percentDiff =>
      baselineMean == 0.0 || !baselineMean.isFinite || !meanDiff.isFinite
      ? null
      : (meanDiff * 100.0) / baselineMean;

  /// [halfWidth] expressed as a percentage of `|baselineMean|`, or `null` if
  /// [baselineMean] is zero or non-finite.
  double? get percentHalfWidth =>
      baselineMean == 0.0 || !baselineMean.isFinite || !halfWidth.isFinite
      ? null
      : (halfWidth * 100.0) / baselineMean.abs();

  /// Whether a valid confidence interval strictly excludes `0.0`.
  bool get isSignificant => isValid && (lowerBound > 0.0 || upperBound < 0.0);

  @override
  String toString() =>
      'DifferenceInterval(diff: ${meanDiff.toStringAsFixed(3)}, '
      'CI_${(confidenceLevel * 100).round()}%: '
      '[${lowerBound.toStringAsFixed(3)}, ${upperBound.toStringAsFixed(3)}], '
      'paired: $paired, valid: $isValid)';
}

/// Internal [DifferenceInterval] helpers kept out of the public `api.txt`
/// surface.
extension InternalDifferenceInterval on DifferenceInterval {
  /// Schuirmann's Two One-Sided Tests (TOST) equivalence test at one-sided
  /// significance [alpha] (`0.05` by default, corresponding to the `90%` CI):
  /// returns `true` iff the `1 - 2 * alpha` interval lies completely within
  /// `[-margin, +margin]`.
  bool isEquivalentWithin(double margin, {double alpha = 0.05}) {
    if (margin < 0.0 || !margin.isFinite) {
      throw ArgumentError.value(
        margin,
        'margin',
        'Equivalence margin must be finite and >= 0.',
      );
    }
    if (alpha <= 0.0 || alpha >= 0.5 || alpha.isNaN) {
      throw ArgumentError.value(
        alpha,
        'alpha',
        'One-sided TOST alpha must be strictly in (0, 0.5).',
      );
    }
    if (!isValid) return false;
    if (standardError == 0.0) return meanDiff.abs() <= margin;
    final t = studentTQuantile(1.0 - alpha, degreesOfFreedom);
    final hw = t * standardError;
    return (meanDiff - hw) >= -margin && (meanDiff + hw) <= margin;
  }
}
