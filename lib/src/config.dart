/// Configuration options governing benchmark execution, warmup, and sampling.
final class BenchmarkConfig {
  /// The number of measurement trials to record after warmup completes.
  final int trials;

  /// The minimum number of warmup iterations to execute before evaluating
  /// convergence.
  final int minWarmupIterations;

  /// The maximum number of warmup iterations permitted before falling back.
  final int maxWarmupIterations;

  /// Target duration for a single measurement batch (default: 100ms) to ensure
  /// timer quantization contributes < 0.1% error.
  final Duration targetBatchDuration;

  /// Maximum seconds allocated to the warmup phase before budget exhaustion.
  final double maxWarmupDurationSeconds;

  /// If `true`, bypasses the 10 µs calibration lower-bound abort.
  final bool forceRun;

  /// Optional logger callback to intercept benchmark diagnostics and warnings.
  final void Function(String message)? logger;

  const BenchmarkConfig({
    this.trials = 15,
    this.minWarmupIterations = 10,
    this.maxWarmupIterations = 200,
    this.targetBatchDuration = const Duration(milliseconds: 100),
    this.maxWarmupDurationSeconds = 5.0,
    this.forceRun = false,
    this.logger,
  });
}
