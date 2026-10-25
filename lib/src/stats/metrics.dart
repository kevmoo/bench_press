import 'dart:math' as math;

/// One-way variance decomposition across `P` independent OS processes.
///
/// Uses a first-difference within-process estimator (`msWithin`) so slow
/// thermal or clock drift inside a process does not inflate within-process
/// noise and mask between-process variance.
final class const ProcessVarianceComponents({
  /// Number of independent OS processes (`P >= 2`).
  required final int processes,

  /// Arithmetic mean of trials per process (`k`).
  required final double meanTrialsPerProcess,

  /// Between-process mean square (`MS_between` in ns^2).
  required final double msBetween,

  /// Drift-immune first-difference within-process mean square
  /// (`MS_within` in ns^2).
  required final double msWithin,

  /// Estimated between-process variance
  /// (`max(0, (msBetween - msWithin) / k)` in ns^2).
  required final double varBetween,

  /// Estimated within-process variance (`msWithin` in ns^2).
  required final double varWithin,

  /// Fraction of total variance attributable to process-to-process noise
  /// (`varBetween / (varBetween + varWithin)` in `0.0 .. 1.0`, rendered as
  /// `Between-Process Share` in Markdown summary tables).
  ///
  /// Values near `0.0` indicate that nearly all variance comes from
  /// within-process trial jitter; values `>= 0.50` indicate that OS
  /// process-launch shifts (ASLR, page placement, cache alignment) dominate and
  /// require more `--processes` rather than more `--trials` per process.
  required final double betweenProcessShare,
}) {
  /// Computes variance components from per-process trial vectors
  /// [processSamplesNs].
  ///
  /// Returns `null` when fewer than 2 non-empty processes are provided or when
  /// within-process degrees of freedom are zero (`diffCount == 0`, i.e. every
  /// process has only 1 trial).
  static ProcessVarianceComponents? compute(
    List<List<double>> processSamplesNs,
  ) {
    final nonEmpty = [
      for (final p in processSamplesNs)
        if (p.isNotEmpty) p,
    ];
    final pCount = nonEmpty.length;
    if (pCount < 2) return null;

    var totalTrials = 0;
    var totalTrialSq = 0.0;
    var weightedSum = 0.0;
    final processMeans = <double>[];
    var diffSqSum = 0.0;
    var diffCount = 0;

    for (final trials in nonEmpty) {
      final n = trials.length;
      totalTrials += n;
      totalTrialSq += n * n;
      final pMean = BenchmarkMetrics._meanOf(trials);
      processMeans.add(pMean);
      weightedSum += n * pMean;
      for (var t = 0; t < n - 1; t++) {
        final d = trials[t + 1] - trials[t];
        diffSqSum += d * d;
        diffCount++;
      }
    }
    if (diffCount == 0) return null;

    final kMean = totalTrials / pCount;
    final k0 = (totalTrials - (totalTrialSq / totalTrials)) / (pCount - 1);
    final weightedGrandMean = weightedSum / totalTrials;
    var betweenSqSum = 0.0;
    for (var i = 0; i < pCount; i++) {
      final diff = processMeans[i] - weightedGrandMean;
      betweenSqSum += nonEmpty[i].length * diff * diff;
    }

    final msBetween = betweenSqSum / (pCount - 1);
    final msWithin = 0.5 * (diffSqSum / diffCount);
    final varWithin = msWithin;
    final varBetween = k0 > 0.0
        ? math.max(0.0, (msBetween - msWithin) / k0)
        : 0.0;
    final totalVar = varBetween + varWithin;
    final share = totalVar > 0.0 ? (varBetween / totalVar) : 0.0;

    return ProcessVarianceComponents(
      processes: pCount,
      meanTrialsPerProcess: kMean,
      msBetween: msBetween,
      msWithin: msWithin,
      varBetween: varBetween,
      varWithin: varWithin,
      betweenProcessShare: share,
    );
  }

  /// Converts the variance components to a JSON-compatible map.
  Map<String, Object?> toJson() => {
    'processes': processes,
    'mean_trials_per_process': meanTrialsPerProcess,
    'ms_between': msBetween,
    'ms_within': msWithin,
    'var_between': varBetween,
    'var_within': varWithin,
    'between_process_share': betweenProcessShare,
  };

  /// Constructs a [ProcessVarianceComponents] instance from a JSON map.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'processes': final int processes,
      'mean_trials_per_process': final num meanTrials,
      'ms_between': final num msBetween,
      'ms_within': final num msWithin,
      'var_between': final num varBetween,
      'var_within': final num varWithin,
      'between_process_share': final num share,
    }) {
      return ProcessVarianceComponents(
        processes: processes,
        meanTrialsPerProcess: meanTrials.toDouble(),
        msBetween: msBetween.toDouble(),
        msWithin: msWithin.toDouble(),
        varBetween: varBetween.toDouble(),
        varWithin: varWithin.toDouble(),
        betweenProcessShare: share.toDouble(),
      );
    }
    throw const FormatException(
      'Invalid or incomplete ProcessVarianceComponents JSON',
    );
  }

  @override
  String toString() =>
      'ProcessVarianceComponents(processes: $processes, '
      'varBetween: ${varBetween.toStringAsFixed(3)}, '
      'varWithin: ${varWithin.toStringAsFixed(3)}, '
      'betweenShare: ${(betweenProcessShare * 100).toStringAsFixed(1)}%)';
}

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

  /// Optional one-way variance decomposition across `P >= 2` independent OS
  /// processes.
  final ProcessVarianceComponents? varianceComponents,
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
    ProcessVarianceComponents? varianceComponents,
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
        varianceComponents: varianceComponents,
      );
    }

    final sorted = List<double>.of(samplesNs)..sort();
    final n = sorted.length;

    final mean = _meanOf(sorted);
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

    final robustStable = isStable && (robustCv <= maxCvThreshold);
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
      varianceComponents: varianceComponents,
    );
  }

  /// Computes distribution summary metrics and one-way variance components from
  /// multi-process trial samples [processSamplesNs].
  ///
  /// When [processSamplesNs] contains a single process (`P = 1`), delegates
  /// directly to [BenchmarkMetrics.fromSamples] on that process's trials. When
  /// `P > 1`, reduces each non-empty process `p` to its arithmetic mean and
  /// computes summary metrics across the `P` process means so that [meanNs] is
  /// the grand mean and [stddevNs] / [cv] reflect between-process dispersion,
  /// while populating [varianceComponents] via
  /// [ProcessVarianceComponents.compute].
  factory fromProcesses(
    List<List<double>> processSamplesNs, {
    bool isStable = true,
    double maxCvThreshold = BenchmarkMetrics.maxCvThreshold,
  }) {
    final nonEmpty = [
      for (final p in processSamplesNs)
        if (p.isNotEmpty) p,
    ];
    if (nonEmpty.isEmpty) {
      return BenchmarkMetrics.fromSamples(
        const <double>[],
        isStable: isStable,
        maxCvThreshold: maxCvThreshold,
      );
    }
    if (nonEmpty.length == 1) {
      return BenchmarkMetrics.fromSamples(
        nonEmpty.single,
        isStable: isStable,
        maxCvThreshold: maxCvThreshold,
      );
    }
    final processMeans = <double>[for (final p in nonEmpty) _meanOf(p)];
    final components = ProcessVarianceComponents.compute(nonEmpty);
    return BenchmarkMetrics.fromSamples(
      processMeans,
      isStable: isStable,
      maxCvThreshold: maxCvThreshold,
      varianceComponents: components,
    );
  }

  static double _meanOf(List<double> values) {
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
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
    if (varianceComponents != null)
      'variance_components': varianceComponents!.toJson(),
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
      final rawVarComp = json['variance_components'];
      final varianceComponents = switch (rawVarComp) {
        null => null,
        final Map<String, Object?> m => ProcessVarianceComponents.fromJson(m),
        final other => throw FormatException(
          'Invalid "variance_components" in BenchmarkMetrics: '
          'expected Map, got ${other.runtimeType}',
        ),
      };
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
        varianceComponents: varianceComponents,
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
