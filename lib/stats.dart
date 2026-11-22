/// Pure-Dart, unit-agnostic statistical summaries, multiplicative Fieller
/// ratio intervals, additive Welch/paired difference intervals, variance
/// decomposition, and linear drift diagnostics.
library;

export 'src/stats/difference.dart' show DifferenceInterval;
export 'src/stats/fieller.dart'
    show FiellerInterval, studentTQuantile, studentTTwoSidedPValue;
export 'src/stats/metrics.dart'
    show BenchmarkMetrics, ProcessVarianceComponents;
export 'src/stats/sample_summary.dart' show SampleSummary;
export 'src/stats/trend.dart' show LinearTrend, bonferroniConfidenceLevel;
