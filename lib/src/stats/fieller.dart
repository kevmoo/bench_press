import 'dart:math' as math;

import 'warmup.dart';

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
    if (sampleA.length < 2 || sampleB.length < 2) {
      return FiellerInterval(
        ratio: double.nan,
        lowerBound: double.nan,
        upperBound: double.nan,
        g: double.infinity,
        isValid: false,
        confidenceLevel: confidenceLevel,
      );
    }

    final nA = sampleA.length;
    final nB = sampleB.length;

    final meanA = AdaptiveWarmupDetector.computeMean(sampleA);
    final meanB = AdaptiveWarmupDetector.computeMean(sampleB);

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
///
/// Uses exact analytical closed forms for `df == 1` and `df == 2`, and Hill's
/// Algorithm 396 (1970) continuous approximation for all `df > 2`, achieving
/// accuracy `< 1e-3` relative error across all integer and fractional degrees
/// of freedom.
double studentTQuantile(double p, double df) {
  if (p <= 0.5 || p >= 1.0) {
    throw ArgumentError.value(
      p,
      'p',
      'Quantile probability must be between 0.5 and 1.0 for upper tail',
    );
  }
  final effectiveDf = df < 1.0 ? 1.0 : df;

  if (effectiveDf == 1.0) {
    return math.tan(math.pi * (p - 0.5));
  }
  if (effectiveDf == 2.0) {
    final alpha = 2.0 * (1.0 - p);
    return math.sqrt(2.0 / (alpha * (2.0 - alpha)) - 2.0);
  }
  if (effectiveDf < 2.0) {
    return _studentTQuantileSmallDf(p, effectiveDf);
  }

  return _studentTQuantileHill(p, effectiveDf);
}

double _studentTQuantileSmallDf(double p, double df) {
  var low = studentTQuantile(p, 2.0);
  var high = studentTQuantile(p, 1.0);
  for (var i = 0; i < 45; i++) {
    final mid = (low + high) / 2.0;
    if (_studentTCdf(mid, df) < p) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2.0;
}

double _studentTQuantileHill(double p, double n) {
  final twoTailP = 2.0 * (1.0 - p);
  final a = 1.0 / (n - 0.5);
  final b = 48.0 / (a * a);
  var c = ((20700.0 * a / b - 98.0) * a - 16.0) * a + 96.36;
  final d =
      ((94.5 / (b + c) - 3.0) / b + 1.0) * math.sqrt(a * math.pi / 2.0) * n;
  var x = d * twoTailP;
  var y = math.pow(x, 2.0 / n).toDouble();

  if (y > 0.05 + a) {
    x = normalQuantile(p);
    y = x * x;
    if (n < 5.0) {
      c += 0.3 * (n - 4.5) * (x + 0.6);
    }
    c = (((0.05 * d * x - 5.0) * x - 7.0) * x - 2.0) * x + b + c;
    y =
        (((((0.4 * y + 6.3) * y + 36.0) * y + 94.5) / c - y - 3.0) / b + 1.0) *
        x;
    y = a * y * y;
    y = y > 0.002 ? math.exp(y) - 1.0 : 0.5 * y * y + y;
  } else {
    y =
        ((1.0 / (((n + 6.0) / (n * y) - 0.089 * d - 0.822) * (n + 2.0) * 3.0) +
                        0.5 / (n + 4.0)) *
                    y -
                1.0) *
            (n + 1.0) /
            (n + 2.0) +
        1.0 / y;
  }

  return math.sqrt(n * y);
}

double _logGamma(double z) {
  const g = 7;
  const p = [
    0.99999999999980993,
    676.5203681218851,
    -1259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7,
  ];
  if (z < 0.5) {
    return math.log(math.pi / math.sin(math.pi * z)) - _logGamma(1.0 - z);
  }
  final zMinus1 = z - 1.0;
  var x = p[0];
  for (var i = 1; i < g + 2; i++) {
    x += p[i] / (zMinus1 + i);
  }
  final t = zMinus1 + g + 0.5;
  return 0.5 * math.log(2.0 * math.pi) +
      (zMinus1 + 0.5) * math.log(t) -
      t +
      math.log(x);
}

double _studentTPdf(double t, double df) {
  final coef =
      math.exp(_logGamma((df + 1.0) / 2.0) - _logGamma(df / 2.0)) /
      math.sqrt(df * math.pi);
  return coef * math.pow(1.0 + (t * t) / df, -(df + 1.0) / 2.0);
}

double _studentTCdf(double t, double df) {
  const n = 200;
  final dt = t / n;
  var s = _studentTPdf(0.0, df) + _studentTPdf(t, df);
  for (var i = 1; i < n; i++) {
    s += (i.isOdd ? 4.0 : 2.0) * _studentTPdf(i * dt, df);
  }
  return 0.5 + s * dt / 3.0;
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
