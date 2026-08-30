import 'dart:math' as math;

import 'kbssd.dart';

/// Represents Fieller's confidence interval for a ratio of two independent
/// means ($\mu_A / \mu_B$).
final class const FiellerInterval({
  /// Point estimate ratio of means ($\bar{x}_A / \bar{x}_B$).
  required final double ratio,

  /// Lower bound of the confidence interval.
  required final double lowerBound,

  /// Upper bound of the confidence interval.
  required final double upperBound,

  /// Fieller's $g$ parameter ($t^2 \cdot V_B / \bar{x}_B^2$).
  ///
  /// For a valid bounded interval, $g < 1.0$ is required.
  required final double g,

  /// Whether the confidence interval is finite and valid ($g < 1.0$ and
  /// non-degenerate denominator).
  required final bool isValid,

  /// The nominal confidence level (default: 0.95).
  final double confidenceLevel = 0.95,
}) {
  /// Computes Fieller's confidence interval for the ratio of means of two
  /// independent sample distributions [sampleA] and [sampleB].
  factory compute({
    required List<double> sampleA,
    required List<double> sampleB,
    double confidenceLevel = 0.95,
  }) {
    if (sampleA.isEmpty || sampleB.isEmpty) {
      return FiellerInterval(
        ratio: 0.0,
        lowerBound: double.nan,
        upperBound: double.nan,
        g: double.infinity,
        isValid: false,
        confidenceLevel: confidenceLevel,
      );
    }

    final nA = sampleA.length;
    final nB = sampleB.length;

    final meanA = KbssdWarmupDetector.computeMean(sampleA);
    final meanB = KbssdWarmupDetector.computeMean(sampleB);

    if (meanB == 0.0) {
      return FiellerInterval(
        ratio: double.infinity,
        lowerBound: double.negativeInfinity,
        upperBound: double.infinity,
        g: double.infinity,
        isValid: false,
        confidenceLevel: confidenceLevel,
      );
    }

    final ratio = meanA / meanB;

    final varA = _sampleVariance(sampleA, meanA);
    final varB = _sampleVariance(sampleB, meanB);

    final vA = varA / nA;
    final vB = varB / nB;

    if (vA == 0.0 && vB == 0.0) {
      return FiellerInterval(
        ratio: ratio,
        lowerBound: ratio,
        upperBound: ratio,
        g: 0.0,
        isValid: true,
        confidenceLevel: confidenceLevel,
      );
    }

    // Welch-Satterthwaite approximation for degrees of freedom
    final num = (vA + vB) * (vA + vB);
    final denomA = (nA > 1 && vA > 0.0) ? (vA * vA) / (nA - 1) : 0.0;
    final denomB = (nB > 1 && vB > 0.0) ? (vB * vB) / (nB - 1) : 0.0;
    final df = (denomA + denomB > 0.0)
        ? (num / (denomA + denomB)).clamp(1.0, 10000.0)
        : (nA + nB - 2.0).clamp(1.0, 10000.0);

    final p = 1.0 - (1.0 - confidenceLevel) / 2.0;
    final t = studentTQuantile(p, df);

    final g = (t * t * vB) / (meanB * meanB);

    if (g >= 1.0 || g.isNaN || g.isInfinite) {
      return FiellerInterval(
        ratio: ratio,
        lowerBound: double.negativeInfinity,
        upperBound: double.infinity,
        g: g,
        isValid: false,
        confidenceLevel: confidenceLevel,
      );
    }

    final disc = vA * (1.0 - g) + (ratio * ratio * vB);
    if (disc < 0.0) {
      return FiellerInterval(
        ratio: ratio,
        lowerBound: ratio,
        upperBound: ratio,
        g: g,
        isValid: false,
        confidenceLevel: confidenceLevel,
      );
    }

    final margin = (t / meanB.abs()) * math.sqrt(disc);
    final oneMinusG = 1.0 - g;
    final lower = (ratio - margin) / oneMinusG;
    final upper = (ratio + margin) / oneMinusG;

    return FiellerInterval(
      ratio: ratio,
      lowerBound: lower,
      upperBound: upper,
      g: g,
      isValid: true,
      confidenceLevel: confidenceLevel,
    );
  }

  static double _sampleVariance(List<double> samples, double mean) {
    if (samples.length <= 1) return 0.0;
    var sumSq = 0.0;
    for (final s in samples) {
      final diff = s - mean;
      sumSq += diff * diff;
    }
    return sumSq / (samples.length - 1);
  }

  /// Converts to JSON map.
  Map<String, Object?> toJson() => {
    'ratio': ratio,
    'lower_bound': lowerBound,
    'upper_bound': upperBound,
    'g': g,
    'is_valid': isValid,
    'confidence_level': confidenceLevel,
  };

  @override
  String toString() =>
      'FiellerInterval(ratio: ${ratio.toStringAsFixed(3)}, '
      'CI_${(confidenceLevel * 100).round()}%: '
      '[${lowerBound.toStringAsFixed(3)}, ${upperBound.toStringAsFixed(3)}], '
      'g: ${g.toStringAsFixed(4)}, '
      'valid: $isValid)';
}

/// Computes the critical value for Student's $t$-distribution given two-tailed
/// upper quantile [p] and degrees of freedom [df].
double studentTQuantile(double p, double df) {
  if (p <= 0.5 || p >= 1.0) {
    throw ArgumentError.value(
      p,
      'p',
      'Quantile probability must be between 0.5 and 1.0 for upper tail',
    );
  }
  if (df < 1.0) {
    df = 1.0;
  }

  // Exact lookup tables for standard 95% confidence (p = 0.975) on small df
  if ((p - 0.975).abs() < 1e-4) {
    final intDf = df.round();
    if ((df - intDf).abs() < 0.05) {
      final exactT = switch (intDf) {
        1 => 12.7062,
        2 => 4.3027,
        3 => 3.1824,
        4 => 2.7764,
        5 => 2.5706,
        6 => 2.4469,
        7 => 2.3646,
        8 => 2.3060,
        9 => 2.2622,
        10 => 2.2281,
        15 => 2.1314,
        20 => 2.0860,
        30 => 2.0423,
        60 => 2.0003,
        120 => 1.9799,
        _ => null,
      };
      if (exactT != null) return exactT;
    }
  }

  // Cornish-Fisher expansion from standard normal quantile z
  final z = normalQuantile(p);
  final z2 = z * z;
  final z3 = z2 * z;
  final z5 = z3 * z2;
  final z7 = z5 * z2;

  final term1 = (z3 + z) / (4.0 * df);
  final term2 = (5.0 * z5 + 16.0 * z3 + 3.0 * z) / (96.0 * df * df);
  final term3 =
      (3.0 * z7 + 19.0 * z5 + 17.0 * z3 - 15.0 * z) / (384.0 * df * df * df);

  return z + term1 + term2 + term3;
}

/// Standard normal inverse CDF (Wichura / Acklam approximation).
double normalQuantile(double p) {
  if (p <= 0.0 || p >= 1.0) {
    throw ArgumentError.value(
      p,
      'p',
      'Normal quantile probability must be strictly in (0, 1)',
    );
  }

  final a = [
    -3.969683028665376e+01,
    2.209460984245205e+02,
    -2.759285104469687e+02,
    1.383577518672690e+02,
    -3.066479806614716e+01,
    2.506628277459239e+00,
  ];
  final b = [
    -5.447609879822406e+01,
    1.615858368580409e+02,
    -1.556989798598866e+02,
    6.680131188771972e+01,
    -1.328068155288572e+01,
  ];
  final c = [
    -7.784894002430293e-03,
    -3.223964580411365e-01,
    -2.400758277161838e+00,
    -2.549732539343734e+00,
    4.374664141464968e+00,
    2.938163982698783e+00,
  ];
  final d = [
    7.784695709041462e-03,
    3.224671290700398e-01,
    2.445134137142996e+00,
    3.754408661907416e+00,
  ];

  const qLow = 0.02425;
  const qHigh = 1.0 - qLow;

  if (p < qLow) {
    final q = math.sqrt(-2.0 * math.log(p));
    return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q +
            c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
  }
  if (p <= qHigh) {
    final q = p - 0.5;
    final r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r +
            a[5]) *
        q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0);
  }
  final q = math.sqrt(-2.0 * math.log(1.0 - p));
  return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q +
          c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
}
