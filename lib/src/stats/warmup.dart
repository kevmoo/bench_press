import 'dart:math' as math;

import '../config.dart';

/// Result metadata produced by the warmup detector.
final class const WarmupResult({
  /// Whether steady-state convergence was attained before budget exhaustion.
  required final bool isStable,

  /// The total number of warmup iterations executed.
  required final int totalWarmupIterations,

  /// The iteration index at which convergence occurred (or the historically
  /// lowest MMD iteration if fallback was triggered).
  required final int convergedAtIteration,

  /// The lowest Maximum Mean Discrepancy (MMD) metric observed across sliding
  /// windows.
  required final double bestMmd,

  /// Total elapsed seconds spent in the warmup phase.
  required final double elapsedSeconds,
}) {
  @override
  String toString() =>
      'WarmupResult(isStable: $isStable, '
      'iters: $totalWarmupIterations, '
      'convergedAt: $convergedAtIteration, '
      'bestMmd: ${bestMmd.toStringAsFixed(4)})';
}

/// Adaptive Steady-State Warmup Detection
/// (RBF Kernel MMD + SEM Relative Error).
///
/// Employs a sliding window Maximum Mean Discrepancy (MMD) with a Gaussian RBF
/// kernel and median bandwidth heuristic, combined with a Standard Error of the
/// Mean (SEM) steady-state relative error check
/// (`1.96 * SEM <= config.maxSemRelativeError * Mean`), and a bounded patience
/// budget fallback.
final class AdaptiveWarmupDetector({
  final BenchmarkConfig config = const BenchmarkConfig(),
  final int windowSize = 10,
}) {
  final List<double> _samples = [];

  double _bestMmd = double.infinity;
  int _bestIteration = 0;
  bool _isConverged = false;
  int _convergedIteration = 0;

  /// The samples observed so far.
  List<double> get samples => List.unmodifiable(_samples);

  /// Whether the warmup detector has reached steady-state convergence.
  bool get isConverged => _isConverged;

  /// Appends a new latency sample (in nanoseconds) and evaluates convergence at
  /// half-window strides (windowSize ~/ 2).
  void addSample(double latencyNs) {
    _samples.add(latencyNs);
    final n = _samples.length;
    if (n >= config.minWarmupIterations &&
        (n - config.minWarmupIterations) % math.max(1, windowSize ~/ 2) == 0) {
      _evaluate();
    }
  }

  /// Evaluates whether the warmup phase should conclude due to convergence or
  /// budget exhaustion.
  bool isDone({double elapsedSeconds = 0.0}) {
    if (_isConverged) return true;
    if (_samples.length >= config.maxWarmupIterations) return true;
    if (elapsedSeconds > 0 &&
        elapsedSeconds >= config.maxWarmupDurationSeconds) {
      return true;
    }
    return false;
  }

  void _evaluate() {
    final n = _samples.length;
    if (n < 2 * windowSize) return;
    if (n < config.minWarmupIterations) return;

    final windowA = _samples.sublist(n - 2 * windowSize, n - windowSize);
    final windowB = _samples.sublist(n - windowSize, n);

    final mmd = computeMmd(windowA, windowB);
    if (mmd < _bestMmd) {
      _bestMmd = mmd;
      _bestIteration = n;
    }

    final meanB = computeMean(windowB);
    final semB = computeSem(windowB);
    final isSemStable =
        meanB > 0.0 && (1.96 * semB <= config.maxSemRelativeError * meanB);
    final isStationary = mmd <= 0.25;

    if (isSemStable && isStationary) {
      _isConverged = true;
      _convergedIteration = n;
      return;
    }

    // If standard SEM failed, distinguish between systemic drift (e.g. ongoing
    // JIT compilation) and transient bimodal outliers (e.g. GC pauses).
    final medianB = computeMedian(windowB);
    final robustSemB = computeRobustSem(windowB);
    final isRobustSemStable =
        medianB > 0.0 &&
        (1.96 * robustSemB <= config.maxSemRelativeError * medianB);

    if (isRobustSemStable &&
        !hasSystemicDrift(
          windowA,
          windowB,
          maxRelativeDrift: config.maxSemRelativeError,
        )) {
      final medA = computeMedian(windowA);
      final madA = computeMad(windowA);
      final madB = computeMad(windowB);
      final inliersA = _filterOutliers(windowA, medA, madA);
      final inliersB = _filterOutliers(windowB, medianB, madB);
      final cleanMmd = computeMmd(inliersA, inliersB);

      if (cleanMmd <= 0.25) {
        _isConverged = true;
        _convergedIteration = n;
      }
    }
  }

  /// Concludes the warmup phase and returns the structured [WarmupResult].
  WarmupResult finish({double elapsedSeconds = 0.0}) {
    if (!_isConverged) {
      final bestStr = _bestMmd.isFinite ? _bestMmd.toStringAsFixed(4) : 'N/A';
      config.logger?.call(
        'Warning: Benchmark failed to reach steady-state warmup convergence '
        'after ${_samples.length} iterations (best MMD: '
        '$bestStr at iteration $_bestIteration). Proceeding with '
        'isStable: false.',
      );
    }

    return WarmupResult(
      isStable: _isConverged,
      totalWarmupIterations: _samples.length,
      convergedAtIteration: _isConverged ? _convergedIteration : _bestIteration,
      bestMmd: _bestMmd.isFinite ? _bestMmd : 0.0,
      elapsedSeconds: elapsedSeconds,
    );
  }

  /// Calculates the arithmetic mean of a sequence.
  static double computeMean(List<double> values) {
    if (values.isEmpty) return 0.0;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
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

  /// Calculates the Median Absolute Deviation (MAD) of a sequence.
  static double computeMad(List<double> values) {
    if (values.isEmpty) return 0.0;
    final med = computeMedian(values);
    final deviations = values.map((v) => (v - med).abs()).toList();
    return computeMedian(deviations);
  }

  /// Calculates the Standard Error of the Mean (SEM) of a sequence.
  static double computeSem(List<double> values) {
    if (values.length <= 1) return 0.0;
    final mean = computeMean(values);
    var sumSq = 0.0;
    for (final v in values) {
      final diff = v - mean;
      sumSq += diff * diff;
    }
    final variance = sumSq / (values.length - 1);
    return math.sqrt(variance / values.length);
  }

  /// Calculates the robust Standard Error of the Mean (SEM) using the
  /// normalized Median Absolute Deviation: `1.4826 * MAD / sqrt(N)`.
  static double computeRobustSem(List<double> values) {
    if (values.length <= 1) return 0.0;
    final mad = computeMad(values);
    return (1.4826 * mad) / math.sqrt(values.length);
  }

  /// Identifies whether the sequence exhibits systemic drift (e.g. ongoing
  /// JIT warmup/compilation) versus steady-state execution with transient
  /// bimodal outliers (e.g. GC pauses).
  static bool hasSystemicDrift(
    List<double> windowA,
    List<double> windowB, {
    double maxRelativeDrift = 0.03,
  }) {
    if (windowA.isEmpty || windowB.isEmpty) return false;

    final medA = computeMedian(windowA);
    final medB = computeMedian(windowB);
    final madA = computeMad(windowA);
    final madB = computeMad(windowB);

    final inliersA = _filterOutliers(windowA, medA, madA);
    final inliersB = _filterOutliers(windowB, medB, madB);

    final cleanMedA = computeMedian(inliersA.isNotEmpty ? inliersA : windowA);
    final cleanMedB = computeMedian(inliersB.isNotEmpty ? inliersB : windowB);

    if (cleanMedB <= 0.0) return false;

    // Relative drift between the steady-state medians of the two windows:
    final interWindowDrift = (cleanMedB - cleanMedA).abs() / cleanMedB;
    if (interWindowDrift > maxRelativeDrift) {
      return true;
    }

    // Intra-window drift within window B:
    final cleanB = inliersB.isNotEmpty ? inliersB : windowB;
    if (cleanB.length >= 4) {
      final mid = cleanB.length ~/ 2;
      final firstHalfMed = computeMedian(cleanB.sublist(0, mid));
      final secondHalfMed = computeMedian(cleanB.sublist(mid));
      if (secondHalfMed > 0.0) {
        final intraDrift = (secondHalfMed - firstHalfMed).abs() / secondHalfMed;
        if (intraDrift > maxRelativeDrift * 1.5) {
          return true;
        }
      }
    }

    return false;
  }

  static List<double> _filterOutliers(
    List<double> values,
    double median,
    double mad,
  ) {
    if (values.length <= 2) return values;
    final nmad = 1.4826 * mad;
    final threshold = math.max(3.0 * nmad, 0.10 * median.abs());
    final inliers = values
        .where((v) => (v - median).abs() <= threshold)
        .toList();
    if (inliers.length >= (values.length * 0.6).ceil()) {
      return inliers;
    }
    return values;
  }

  /// Calculates the unbiased Maximum Mean Discrepancy (MMD) between two sample
  /// windows using a Gaussian RBF kernel with median pairwise bandwidth
  /// heuristic.
  static double computeMmd(List<double> a, List<double> b) {
    final m = a.length;
    final n = b.length;
    if (m < 2 || n < 2) return 0.0;

    final twoSigmaSq = _computeTwoSigmaSq(a, b);
    final sumAA = _kernelSelfSum(a, twoSigmaSq);
    final sumBB = _kernelSelfSum(b, twoSigmaSq);
    final sumAB = _kernelCrossSum(a, b, twoSigmaSq);

    final mmdSq =
        (sumAA / (m * (m - 1))) +
        (sumBB / (n * (n - 1))) -
        (2.0 * sumAB / (m * n));

    return math.sqrt(math.max(0.0, mmdSq));
  }

  static double _computeTwoSigmaSq(List<double> a, List<double> b) {
    final combined = [...a, ...b];
    final diffs = <double>[];
    for (var i = 0; i < combined.length; i++) {
      for (var j = i + 1; j < combined.length; j++) {
        diffs.add((combined[i] - combined[j]).abs());
      }
    }
    var sigma = computeMedian(diffs);
    if (sigma <= 1e-9) {
      sigma = computeMean(diffs);
    }
    if (sigma <= 1e-9) {
      sigma = 1.0;
    }
    return 2.0 * sigma * sigma;
  }

  static double _kernelSelfSum(List<double> values, double twoSigmaSq) {
    var sum = 0.0;
    final len = values.length;
    for (var i = 0; i < len; i++) {
      for (var j = 0; j < len; j++) {
        if (i != j) {
          final diff = values[i] - values[j];
          sum += math.exp(-(diff * diff) / twoSigmaSq);
        }
      }
    }
    return sum;
  }

  static double _kernelCrossSum(
    List<double> a,
    List<double> b,
    double twoSigmaSq,
  ) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        final diff = a[i] - b[j];
        sum += math.exp(-(diff * diff) / twoSigmaSq);
      }
    }
    return sum;
  }
}
