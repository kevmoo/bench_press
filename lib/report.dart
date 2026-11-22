/// Canonical benchmark telemetry schema, Markdown summary and delta reporting,
/// and Git baseline diffing (`benchstat` for Dart).
library;

export 'src/schedule/pairing.dart' show PairingInfo;
export 'src/stats/metrics.dart'
    show BenchmarkMetrics, ProcessVarianceComponents;
export 'src/telemetry/git_diff.dart'
    show GitBaselineDiffResult, GitBaselineExtractor, GitDiffReporter;
export 'src/telemetry/markdown_reporter.dart'
    show ComparisonScale, MarkdownReporter;
export 'src/telemetry/schema.dart'
    show
        BenchmarkCoordinates,
        BenchmarkEntry,
        BenchmarkSuiteResult,
        EnvironmentInfo,
        MetricUnit,
        currentTelemetrySchemaVersion,
        defaultTelemetryFileName;
export 'src/throughput.dart' show ByteThroughput, ElementThroughput, Throughput;
