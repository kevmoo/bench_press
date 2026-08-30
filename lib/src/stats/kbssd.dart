import 'dart:math' as math;

import '../config.dart';

/// Result metadata produced by the KBSSD warmup detector.
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

/// Kallithea-Borg Self-Stopping Detection (KBSSD) steady-state warmup detector.
///
/// Employs a sliding window Maximum Mean Discrepancy (MMD) with a Gaussian RBF
/// kernel and median bandwidth heuristic, combined with Median Absolute
/// Deviation (MAD) dynamic thresholding, a practical Standard Error of the Mean
/// (SEM) steady-state check (`1.96 * SEM <= 0.03 * Mean`), and a bounded
/// patience budget fallback.
final class KbssdWarmupDetector({
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

  /// Appends a new latency sample (in nanoseconds) and evaluates convergence.
  void addSample(double latencyNs) {
    _samples.add(latencyNs);
    _evaluate();
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

    final mad = computeMad(windowB);
    final medianB = computeMedian(windowB);
    final relMad = medianB > 0.0 ? (mad / medianB) : mad;
    final threshold = math.min(0.05, math.max(0.01, 2.0 * relMad));

    final meanB = computeMean(windowB);
    final semB = computeSem(windowB);
    final isSemStable = meanB > 0.0 && (1.96 * semB <= 0.03 * meanB);

    final isMmdConverged = mmd <= threshold;
    final isSemConverged = mmd <= 0.10 && isSemStable;

    if (isMmdConverged || isSemConverged) {
      _isConverged = true;
      _convergedIteration = n;
    }
  }

  /// Concludes the warmup phase and returns the structured [WarmupResult].
  WarmupResult finish({double elapsedSeconds = 0.0}) {
    if (!_isConverged && _samples.length >= config.maxWarmupIterations) {
      final bestStr = _bestMmd.isFinite ? _bestMmd.toStringAsFixed(4) : 'N/A';
      config.logger?.call(
        'Warning: Benchmark failed to reach steady-state warmup convergence '
        'within ${config.maxWarmupIterations} iterations (best MMD: '
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
