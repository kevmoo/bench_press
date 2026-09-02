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
/// Uses exact analytical closed forms for `df == 1` and `df == 2`, bracketed
/// bisection with the regularized incomplete beta CDF for `1 < df < 2`, and
/// Hill's Algorithm 396 (1970) continuous approximation for `df > 2`.
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

/// The constant parameter $g$ in the Lanczos approximation for $\ln \Gamma(z)$.
///
/// With $g = 7$ and 9 rational coefficients ([_lanczosCoefficients]), this
/// approximation yields precision of approximately 15 significant decimal
/// digits for $\text{Re}(z) > 0$.
const int _lanczosG = 7;

/// Lanczos approximation coefficients $p_0, \dots, p_8$ for $\ln \Gamma(z)$
/// with $g = 7$.
///
/// Computes the Gamma function approximation published by Cornelius Lanczos
/// (1964):
///
/// $$\Gamma(z + 1) = \sqrt{2\pi} (z + g + 1/2)^{z + 1/2} e^{-(z + g + 1/2)}$$
/// $$\times \left( p_0 + \sum_{i=1}^N \frac{p_i}{z + i} \right)$$
///
/// These coefficients provide double-precision accuracy across the entire
/// domain.
const List<double> _lanczosCoefficients = [
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

double _logGamma(double z) {
  if (z < 0.5) {
    return math.log(math.pi / math.sin(math.pi * z)) - _logGamma(1.0 - z);
  }
  final zMinus1 = z - 1.0;
  var x = _lanczosCoefficients[0];
  for (var i = 1; i < _lanczosG + 2; i++) {
    x += _lanczosCoefficients[i] / (zMinus1 + i);
  }
  final t = zMinus1 + _lanczosG + 0.5;
  return 0.5 * math.log(2.0 * math.pi) +
      (zMinus1 + 0.5) * math.log(t) -
      t +
      math.log(x);
}

double _clampTiny(double val) => val.abs() < 1e-30 ? 1e-30 : val;

double _regularizedIncompleteBeta(double x, double a, double b) {
  if (x <= 0.0) return 0.0;
  if (x >= 1.0) return 1.0;

  if (x > (a + 1.0) / (a + b + 2.0)) {
    return 1.0 - _regularizedIncompleteBeta(1.0 - x, b, a);
  }

  final logBeta = _logGamma(a) + _logGamma(b) - _logGamma(a + b);
  final front = math.exp(a * math.log(x) + b * math.log(1.0 - x) - logBeta) / a;

  const maxIterations = 200;
  const eps = 3e-14;

  final qab = a + b;
  final qap = a + 1.0;
  final qam = a - 1.0;

  var c = 1.0;
  var d = 1.0 / _clampTiny(1.0 - qab * x / qap);
  var h = d;

  for (var m = 1; m <= maxIterations; m++) {
    final m2 = 2 * m;
    final aaEven = m * (b - m) * x / ((qam + m2) * (a + m2));
    d = 1.0 / _clampTiny(1.0 + aaEven * d);
    c = _clampTiny(1.0 + aaEven / c);
    h *= d * c;

    final aaOdd = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
    d = 1.0 / _clampTiny(1.0 + aaOdd * d);
    c = _clampTiny(1.0 + aaOdd / c);
    final del = d * c;
    h *= del;

    if ((del - 1.0).abs() < eps) break;
  }

  return front * h;
}

/// Computes the cumulative distribution function (CDF) for Student's
/// $t$-distribution at [t] (`t >= 0`) with [df] degrees of freedom using the
/// regularized incomplete beta function evaluated via Lentz's continued
/// fraction algorithm.
double _studentTCdf(double t, double df) {
  if (t <= 0.0) return 0.5;
  final x = df / (df + t * t);
  return 1.0 - 0.5 * _regularizedIncompleteBeta(x, df / 2.0, 0.5);
}

/// Lower tail probability boundary for Peter J. Acklam's inverse normal CDF
/// algorithm.
///
/// For $p < \_acklamQLow$ or $p > \_acklamQHigh$, the rational approximation
/// in the tail using coefficients ([_acklamTailNumerator],
/// [_acklamTailDenominator]) is evaluated.
const double _acklamQLow = 0.02425;

/// Upper tail probability boundary for Peter J. Acklam's inverse normal CDF
/// algorithm.
const double _acklamQHigh = 1.0 - _acklamQLow;

/// Numerator coefficients $a_1, \dots, a_6$ for Peter J. Acklam's rational
/// approximation of the inverse normal CDF in the central region
/// ($\_acklamQLow \le p \le \_acklamQHigh$).
///
/// Evaluated with $q = p - 0.5$ and $r = q^2$ as:
///
/// $$\text{num}(r) = (((((a_0 r + a_1) r + a_2) r + a_3) r + a_4) r + a_5) q$$
const List<double> _acklamCentralNumerator = [
  -3.969683028665376e+01,
  2.209460984245205e+02,
  -2.759285104469687e+02,
  1.383577518672690e+02,
  -3.066479806614716e+01,
  2.506628277459239e+00,
];

/// Denominator coefficients $b_1, \dots, b_5$ for Peter J. Acklam's rational
/// approximation of the inverse normal CDF in the central region
/// ($\_acklamQLow \le p \le \_acklamQHigh$).
///
/// Evaluated with $q = p - 0.5$ and $r = q^2$ as:
///
/// $$\text{den}(r) = ((((b_0 r + b_1) r + b_2) r + b_3) r + b_4) r + 1.0$$
const List<double> _acklamCentralDenominator = [
  -5.447609879822406e+01,
  1.615858368580409e+02,
  -1.556989798598866e+02,
  6.680131188771972e+01,
  -1.328068155288572e+01,
];

/// Numerator coefficients $c_1, \dots, c_6$ for Peter J. Acklam's rational
/// approximation of the inverse normal CDF in the tail regions
/// ($p < \_acklamQLow$ or $p > \_acklamQHigh$).
///
/// Evaluated with $q = \sqrt{-2 \ln(p)}$ (lower tail) or
/// $q = \sqrt{-2 \ln(1 - p)}$ (upper tail) as:
///
/// $$\text{num}(q) = ((((c_0 q + c_1) q + c_2) q + c_3) q + c_4) q + c_5$$
const List<double> _acklamTailNumerator = [
  -7.784894002430293e-03,
  -3.223964580411365e-01,
  -2.400758277161838e+00,
  -2.549732539343734e+00,
  4.374664141464968e+00,
  2.938163982698783e+00,
];

/// Denominator coefficients $d_1, \dots, d_4$ for Peter J. Acklam's rational
/// approximation of the inverse normal CDF in the tail regions
/// ($p < \_acklamQLow$ or $p > \_acklamQHigh$).
///
/// Evaluated with $q = \sqrt{-2 \ln(p)}$ (lower tail) or
/// $q = \sqrt{-2 \ln(1 - p)}$ (upper tail) as:
///
/// $$\text{den}(q) = (((d_0 q + d_1) q + d_2) q + d_3) q + 1.0$$
const List<double> _acklamTailDenominator = [
  7.784695709041462e-03,
  3.224671290700398e-01,
  2.445134137142996e+00,
  3.754408661907416e+00,
];

/// Standard normal inverse CDF (Wichura / Acklam approximation).
double normalQuantile(double p) {
  if (p <= 0.0 || p >= 1.0) {
    throw ArgumentError.value(
      p,
      'p',
      'Normal quantile probability must be strictly in (0, 1)',
    );
  }

  if (p < _acklamQLow) {
    final q = math.sqrt(-2.0 * math.log(p));
    return _evalAcklamTail(q);
  }
  if (p <= _acklamQHigh) {
    final q = p - 0.5;
    final r = q * q;
    return (((((_acklamCentralNumerator[0] * r + _acklamCentralNumerator[1]) *
                                        r +
                                    _acklamCentralNumerator[2]) *
                                r +
                            _acklamCentralNumerator[3]) *
                        r +
                    _acklamCentralNumerator[4]) *
                r +
            _acklamCentralNumerator[5]) *
        q /
        (((((_acklamCentralDenominator[0] * r + _acklamCentralDenominator[1]) *
                                        r +
                                    _acklamCentralDenominator[2]) *
                                r +
                            _acklamCentralDenominator[3]) *
                        r +
                    _acklamCentralDenominator[4]) *
                r +
            1.0);
  }
  final q = math.sqrt(-2.0 * math.log(1.0 - p));
  return -_evalAcklamTail(q);
}

double _evalAcklamTail(double q) =>
    (((((_acklamTailNumerator[0] * q + _acklamTailNumerator[1]) * q +
                                _acklamTailNumerator[2]) *
                            q +
                        _acklamTailNumerator[3]) *
                    q +
                _acklamTailNumerator[4]) *
            q +
        _acklamTailNumerator[5]) /
    ((((_acklamTailDenominator[0] * q + _acklamTailDenominator[1]) * q +
                        _acklamTailDenominator[2]) *
                    q +
                _acklamTailDenominator[3]) *
            q +
        1.0);
