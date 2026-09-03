/// Configuration options governing benchmark execution, warmup, and sampling.
final class const BenchmarkConfig({
  /// The number of measurement trials to record after warmup completes.
  final int trials = 15,

  /// The maximum number of measurement trials permitted when adaptive trial
  /// scaling is active.
  ///
  /// If null or <= [trials], exactly [trials] are executed without scaling.
  final int? maxTrials,

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
});
