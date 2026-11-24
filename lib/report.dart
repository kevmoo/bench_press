/// Canonical benchmark telemetry schema and Markdown summary/delta reporting.
library;

export 'src/runner.dart' show BenchmarkResult;
export 'src/schedule/pairing.dart' show PairingInfo;
export 'src/stats/metrics.dart'
    show BenchmarkMetrics, ProcessVarianceComponents;
export 'src/telemetry/markdown_reporter.dart'
    show ComparisonScale, MarkdownReporter;
export 'src/telemetry/schema.dart'
    show BenchmarkEntry, BenchmarkSuiteResult, EnvironmentInfo;
export 'src/throughput.dart' show ByteThroughput, ElementThroughput, Throughput;
