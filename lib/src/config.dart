/// Configuration options governing benchmark execution, warmup, and sampling.
final class const BenchmarkConfig({
  /// The number of measurement trials to record after warmup completes
  /// (default: [defaultTrials], i.e. 4 visits of 4 trials across `ABBA BAAB`
  /// groups).
  final int trials = defaultTrials,

  /// The maximum number of measurement trials permitted when adaptive trial
  /// scaling is active.
  ///
  /// If null or <= [trials], exactly [trials] are executed without scaling.
  final int? maxTrials,

  /// Opt-in early stopping target as a relative fraction of the mean (e.g.
  /// 0.01 for 1%; default: 0.0, disabled).
  ///
  /// Once at least 8 trials are recorded, collection stops as soon as the 95%
  /// confidence interval half-width (`1.96 × SEM`) is within this fraction of
  /// the mean. Interleaved variants stop together, at the end of a visit, once
  /// every variant meets the target. Once met, it also ends scaling toward
  /// [maxTrials].
  final double stopAtCi = 0.0,

  /// The minimum number of warmup iterations to execute before evaluating
  /// convergence.
  final int minWarmupIterations = 10,

  /// The maximum number of warmup iterations permitted before falling back.
  final int maxWarmupIterations = 200,

  /// Target duration for a single measurement batch (default: 100ms) to ensure
  /// timer quantization contributes < 0.1% error.
  final Duration targetBatchDuration = const Duration(milliseconds: 100),

  /// Maximum seconds allocated to the warmup phase before budget exhaustion.
  final double maxWarmupDurationSeconds = 5.0,

  /// Maximum relative error of the Standard Error of the Mean (SEM) permitted
  /// for steady-state warmup convergence (default: 0.03, i.e., 3%).
  final double maxSemRelativeError = 0.03,

  /// If true, bypasses the zero-elapsed-ticks calibration abort (timer
  /// quantization).
  final bool forceRun = false,

  /// Optional logger callback to intercept benchmark diagnostics and warnings.
  final void Function(String message)? logger,
}) {
  /// Default number of measurement trials per benchmark (16 = 4 visits of 4
  /// trials across `ABBA BAAB` groups).
  static const int defaultTrials = 16;
}
