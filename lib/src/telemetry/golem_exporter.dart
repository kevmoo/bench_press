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
  ///
  /// When [suite] contains duplicate benchmark names across multiple groups or
  /// coordinates, only colliding names are disambiguated with sanitized
  /// group/coordinate prefixes so unique single-group names remain untouched.
  static String formatLines(
    BenchmarkSuiteResult suite, {
    GolemTimeMetric timeMetric = GolemTimeMetric.auto,
    GolemByteMetric byteMetric = GolemByteMetric.memoryUse,
    String namePrefix = '',
  }) {
    final names = _buildEntryNames(suite.benchmarks);
    final buffer = StringBuffer();
    for (var i = 0; i < suite.benchmarks.length; i++) {
      if (i > 0) buffer.writeln();
      buffer.write(
        _formatEntryLine(
          suite.benchmarks[i],
          resolvedName: '$namePrefix${names[i]}',
          timeMetric: timeMetric,
          byteMetric: byteMetric,
        ),
      );
    }
    return buffer.toString();
  }

  static String _formatEntryLine(
    BenchmarkEntry entry, {
    required String resolvedName,
    required GolemTimeMetric timeMetric,
    required GolemByteMetric byteMetric,
  }) {
    final mean = entry.metrics.meanNs;
    if (entry.unit == MetricUnit.bytes) {
      return '$resolvedName(${byteMetric.golemTag}): ${mean.round()}';
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
      return '$resolvedName(RunTime): ${_formatScore(us)} us.';
    }
    if (mean >= 1e6) {
      final ms = mean / 1e6;
      return '$resolvedName(RunTimeRaw): ${_formatScore(ms)} ms.';
    }
    final us = mean / 1000.0;
    return '$resolvedName(RunTimeRaw): ${_formatScore(us)} us.';
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
  }) {
    final names = _buildEntryNames(suite.benchmarks);
    return [
      for (var i = 0; i < suite.benchmarks.length; i++)
        _entryToLuciMap(
          suite.benchmarks[i],
          resolvedName: names[i],
          target: target,
          cpu: cpu,
          machineType: machineType,
          byteMetric: byteMetric,
        ),
    ];
  }

  static Map<String, Object?> _entryToLuciMap(
    BenchmarkEntry entry, {
    required String resolvedName,
    required String? target,
    required String? cpu,
    required String? machineType,
    required GolemByteMetric byteMetric,
  }) {
    final isRunTime =
        entry.calibratedBatchIterations != null &&
        entry.calibratedBatchIterations! > 1;
    return {
      'cpu': ?cpu,
      'machineType': ?machineType,
      'target': ?target,
      'benchmark': resolvedName,
      'metric': entry.unit == MetricUnit.bytes
          ? byteMetric.golemTag
          : (isRunTime ? 'RunTime' : 'RunTimeRaw'),
      'score': entry.unit == MetricUnit.bytes
          ? entry.metrics.meanNs.round()
          : entry.metrics.meanNs / 1000.0,
    };
  }

  static List<String> _buildEntryNames(List<BenchmarkEntry> entries) {
    final seen = <String>{};
    final duplicates = <String>{};
    for (final e in entries) {
      if (!seen.add(e.name)) duplicates.add(e.name);
    }
    if (duplicates.isEmpty) return [for (final e in entries) e.name];

    final candidates = [
      for (final e in entries)
        duplicates.contains(e.name) ? _disambiguateByCoords(e) : e.name,
    ];
    return _disambiguateTargetCollisions(entries, candidates);
  }

  static String _disambiguateByCoords(BenchmarkEntry entry) {
    if (entry.coordinates.isEmpty) return entry.name;
    final parts = <String>[];
    final group = entry.coordinates.group;
    if (group != null && group.isNotEmpty) {
      parts.add(_sanitizeGolemToken(group));
    }
    final otherKeys =
        entry.coordinates.keys
            .where((k) => k != BenchmarkCoordinates.groupKey)
            .toList()
          ..sort();
    for (final key in otherKeys) {
      parts.add(_sanitizeGolemToken('${key}_${entry.coordinates[key]}'));
    }
    return parts.isEmpty ? entry.name : '${parts.join('_')}_${entry.name}';
  }

  static List<String> _disambiguateTargetCollisions(
    List<BenchmarkEntry> entries,
    List<String> candidates,
  ) {
    final seen = <String>{};
    final colliding = <String>{};
    for (final c in candidates) {
      if (!seen.add(c)) colliding.add(c);
    }
    if (colliding.isEmpty) return candidates;
    return [
      for (var i = 0; i < candidates.length; i++)
        colliding.contains(candidates[i])
            ? '${candidates[i]}_${_sanitizeGolemToken(entries[i].target)}'
            : candidates[i],
    ];
  }

  static final _nonGolemIdChars = RegExp('[^A-Za-z0-9_.-]+');
  static final _trimUnderscores = RegExp(r'^_+|_+$');

  static String _sanitizeGolemToken(String raw) =>
      raw.replaceAll(_nonGolemIdChars, '_').replaceAll(_trimUnderscores, '');
}
