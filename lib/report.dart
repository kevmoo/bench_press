/// Canonical benchmark telemetry schema, Markdown summary and delta reporting,
/// Git baseline diffing, and Golem output adapters (`benchstat` for Dart).
library;

export 'src/schedule/pairing.dart' show PairingInfo;
export 'src/stats/metrics.dart'
    show BenchmarkMetrics, ProcessVarianceComponents;
export 'src/telemetry/git_diff.dart'
    show GitBaselineDiffResult, GitBaselineExtractor, GitDiffReporter;
export 'src/telemetry/golem_exporter.dart'
    show GolemByteMetric, GolemExporter, GolemTimeMetric;
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
