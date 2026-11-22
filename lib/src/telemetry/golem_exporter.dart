import 'schema.dart';

/// Time metric tag convention emitted by [GolemExporter.formatLines].
enum GolemTimeMetric() {
  /// Emits `RunTime` (`us.`) when `calibratedBatchIterations != null && > 1`,
  /// otherwise `RunTimeRaw` (`ms.` when `>= 1 ms`, else `us.`).
  auto,

  /// Always emits `<name>(RunTime): <us> us.` (microbenchmark convention).
  runTime,

  /// Always emits `<name>(RunTimeRaw): <val> <unit>.` (single-shot / episode
  /// convention).
  runTimeRaw,
}

/// Byte metric tag convention emitted for [MetricUnit.bytes] entries.
enum GolemByteMetric(
  /// Canonical Golem metric name (`'MemoryUse'` or `'CodeSize'`).
  final String golemTag,
) {
  /// Peak RSS / heap consumption (`MemoryUse`).
  memoryUse('MemoryUse'),

  /// Compiled snapshot / artifact size (`CodeSize`).
  codeSize('CodeSize'),
}

/// Formats [BenchmarkSuiteResult] telemetry into Dart SDK Golem runner output
/// lines or LUCI Cloud Storage uploader JSON records.
abstract final class GolemExporter() {
  /// Renders canonical Golem stdout lines
  /// (`<Name>(<Metric>): <value>[ <unit>.]`) across all entries in [suite].
  static String formatLines(
    BenchmarkSuiteResult suite, {
    GolemTimeMetric timeMetric = GolemTimeMetric.auto,
    GolemByteMetric byteMetric = GolemByteMetric.memoryUse,
    String namePrefix = '',
  }) {
    final buffer = StringBuffer();
    for (var i = 0; i < suite.benchmarks.length; i++) {
      if (i > 0) buffer.writeln();
      buffer.write(
        _formatEntryLine(
          suite.benchmarks[i],
          timeMetric: timeMetric,
          byteMetric: byteMetric,
          namePrefix: namePrefix,
        ),
      );
    }
    return buffer.toString();
  }

  static String _formatEntryLine(
    BenchmarkEntry entry, {
    required GolemTimeMetric timeMetric,
    required GolemByteMetric byteMetric,
    required String namePrefix,
  }) {
    final fullName = '$namePrefix${entry.name}';
    final mean = entry.metrics.meanNs;
    if (entry.unit == MetricUnit.bytes) {
      return '$fullName(${byteMetric.golemTag}): ${mean.round()}';
    }

    final useRunTime = switch (timeMetric) {
      GolemTimeMetric.runTime => true,
      GolemTimeMetric.runTimeRaw => false,
      GolemTimeMetric.auto =>
        entry.calibratedBatchIterations != null &&
            entry.calibratedBatchIterations! > 1,
    };
    if (useRunTime) {
      final us = mean / 1000.0;
      return '$fullName(RunTime): ${_formatScore(us)} us.';
    }
    if (mean >= 1e6) {
      final ms = mean / 1e6;
      return '$fullName(RunTimeRaw): ${_formatScore(ms)} ms.';
    }
    final us = mean / 1000.0;
    return '$fullName(RunTimeRaw): ${_formatScore(us)} us.';
  }

  static String _formatScore(double v) {
    if (!v.isFinite || v == 0.0) return '0';
    final stripped = v.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
    if (stripped == '0' || stripped == '-0') return v.toString();
    return stripped;
  }

  /// Converts [suite] into the LUCI/Swarming GCS benchmark uploader JSON array
  /// schema (`[{"benchmark", "metric", "score", ...}]`).
  ///
  /// Time scores are emitted in microseconds (`RunTime` or `RunTimeRaw`), and
  /// byte scores are emitted as integer byte counts (`MemoryUse` or
  /// `CodeSize`).
  static List<Map<String, Object?>> toLuciJson(
    BenchmarkSuiteResult suite, {
    String? target,
    String? cpu,
    String? machineType,
    GolemByteMetric byteMetric = GolemByteMetric.memoryUse,
  }) => [
    for (final entry in suite.benchmarks)
      {
        'cpu': ?cpu,
        'machineType': ?machineType,
        'target': ?target,
        'benchmark': entry.name,
        'metric': entry.unit == MetricUnit.bytes
            ? byteMetric.golemTag
            : ((entry.calibratedBatchIterations != null &&
                      entry.calibratedBatchIterations! > 1)
                  ? 'RunTime'
                  : 'RunTimeRaw'),
        'score': entry.unit == MetricUnit.bytes
            ? entry.metrics.meanNs.round()
            : entry.metrics.meanNs / 1000.0,
      },
  ];
}
