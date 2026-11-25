/// Pure-Dart, unit-agnostic statistical summaries, multiplicative Fieller
/// ratio intervals, additive Welch/paired difference intervals, and variance
/// decomposition.
library;

export 'src/stats/difference.dart' show DifferenceInterval;
export 'src/stats/fieller.dart' show FiellerInterval;
export 'src/stats/metrics.dart'
    show BenchmarkMetrics, ProcessVarianceComponents;
export 'src/stats/sample_summary.dart' show SampleSummary;
