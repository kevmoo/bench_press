/// Configuration options governing benchmark execution, warmup, and sampling.
final class const BenchmarkConfig({
  /// The number of measurement trials to record after warmup completes.
  final int trials = 15,

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

  /// If `true`, bypasses the 10 µs calibration lower-bound abort.
  final bool forceRun = false,

  /// Optional logger callback to intercept benchmark diagnostics and warnings.
  final void Function(String message)? logger,
});
