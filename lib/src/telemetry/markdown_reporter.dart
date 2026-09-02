import 'dart:io';
import 'dart:math' as math;

import '../stats/fieller.dart';
import 'schema.dart';

/// Generates formatted, mdformat-compliant Markdown tables and performance
/// telemetry reports.
abstract final class MarkdownReporter() {
  /// Renders a full comprehensive Markdown report for a [BenchmarkSuiteResult].
  static String renderSuite(BenchmarkSuiteResult suite, {String? title}) {
    final buffer = StringBuffer();
    final heading = title ?? 'Benchmark Suite Results';
    buffer.writeln('# $heading');
    buffer.writeln();
    buffer.writeln('**Date**: ${suite.timestamp.toUtc().toIso8601String()}  ');
    buffer.writeln(
      '**Environment**: Dart ${suite.environment.dartVersion} '
      '(${suite.environment.os}/${suite.environment.arch})  ',
    );
    buffer.writeln('**Total Benchmarks**: ${suite.benchmarks.length}');
    buffer.writeln();

    final isLegacyGrouped =
        suite.benchmarks.isNotEmpty &&
        suite.benchmarks.any((b) => b.coordinates.containsKey('group')) &&
        suite.benchmarks.every(
          (b) =>
              b.coordinates.length == 1 && b.coordinates.containsKey('group'),
        );

    if (isLegacyGrouped) {
      final groupTables = renderAllGroupComparisonTables(suite);
      if (groupTables.isNotEmpty) {
        buffer.write(groupTables);
      }
      final summaryTitle = groupTables.isNotEmpty ? 'All Benchmarks' : null;
      buffer.writeln(renderSummaryTable(suite, title: summaryTitle));
      return buffer.toString().trimRight();
    }

    final workloads = _groupMatrixByWorkload(suite);
    for (final workload in workloads.entries) {
      buffer.writeln(
        renderMatrixComparisonTable(
          workloadName: workload.key,
          entries: workload.value,
        ),
      );
      buffer.writeln();
    }

    buffer.writeln(renderSummaryTable(suite, title: 'All Benchmarks'));
    return buffer.toString().trimRight();
  }

  static Map<String, List<BenchmarkEntry>> _groupMatrixByWorkload(
    BenchmarkSuiteResult suite,
  ) {
    final map = <String, List<BenchmarkEntry>>{};
    for (final b in suite.benchmarks) {
      map.putIfAbsent(b.name, () => []).add(b);
    }
    return map;
  }

  static String renderMatrixComparisonTable({
    required String workloadName,
    required List<BenchmarkEntry> entries,
    String? title,
  }) {
    if (entries.isEmpty) return '';

    final buffer = StringBuffer();
    final heading = title ?? 'Benchmark: `$workloadName`';
    buffer.writeln('### $heading\n');
    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');

    final axes = <String>{};
    for (final e in entries) {
      axes.addAll(e.coordinates.keys);
    }
    final axesList = axes.toList()..sort();

    final hasThroughput = entries.any((e) => e.throughput != null);

    final headerRow = <String>[];
    for (final axis in axesList) {
      final cap = axis.isEmpty
          ? 'Variant'
          : axis[0].toUpperCase() + axis.substring(1);
      headerRow.add(cap);
    }
    if (axesList.isEmpty) {
      headerRow.add('Implementation');
    }

    headerRow.add('Ops/sec');
    if (hasThroughput) headerRow.add('Throughput');
    headerRow.add('Mean Latency');

    final baseEntry = entries.firstWhere(
      (e) => e.isBaseline,
      orElse: () => entries.first,
    );
    final baselineLabel = _formatBaselineLabel(baseEntry, axesList);

    headerRow.addAll([
      'vs. Baseline (`$baselineLabel`)',
      'Speedup Ratio',
      '95% Confidence Interval',
      'Status',
    ]);

    buffer.writeln('| ${headerRow.join(' | ')} |');

    final sepRow = List.generate(
      axesList.isEmpty ? 1 : axesList.length,
      (_) => ':---',
    );
    if (hasThroughput) {
      sepRow.addAll([':---:', ':---:', ':---:']);
    } else {
      sepRow.addAll([':---:', ':---:']);
    }
    sepRow.addAll([':---:', ':---:', ':---:', ':---:']);
    buffer.writeln('| ${sepRow.join(' | ')} |');

    final curMeanNs = baseEntry.metrics.meanNs;
    for (final entry in entries) {
      buffer.writeln(
        _formatMatrixRow(entry, baseEntry, curMeanNs, hasThroughput, axesList),
      );
    }
    buffer.writeln('<!-- mdformat on -->');
    return buffer.toString().trimRight();
  }

  static String _formatBaselineLabel(BenchmarkEntry entry, List<String> axes) {
    if (axes.isEmpty) return entry.name;
    final vals = axes.map((a) => entry.coordinates[a] ?? '-').toList();
    return vals.join(', ');
  }

  static String _formatMatrixRow(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double baseMeanNs,
    bool hasThroughput,
    List<String> axes,
  ) {
    final curMeanNs = entry.metrics.meanNs;
    final speedup = (curMeanNs > 0.0 && baseMeanNs > 0.0)
        ? (baseMeanNs / curMeanNs)
        : 1.0;

    final cols = <String>[
      ..._formatDimensionCols(entry, baselineEntry, axes),
      _formatOps(entry.metrics.opsPerSec),
      if (hasThroughput) entry.throughput?.formatRate(curMeanNs) ?? '-',
      _formatLatency(curMeanNs),
      ..._formatComparisonCols(entry, baselineEntry, speedup),
    ];

    return '| ${cols.join(' | ')} |';
  }

  static List<String> _formatDimensionCols(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    List<String> axes,
  ) {
    final isBase = identical(entry, baselineEntry);
    final suffix = isBase ? ' (Baseline)' : '';
    if (axes.isEmpty) {
      return ['`${entry.name}`$suffix'];
    }
    return [
      for (final axis in axes) '`${entry.coordinates[axis] ?? '-'}`$suffix',
    ];
  }

  static List<String> _formatComparisonCols(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double speedup,
  ) {
    if (identical(entry, baselineEntry)) {
      return ['1.00x (ref)', '1.00x', '[1.00x – 1.00x]', 'Ref'];
    }

    final diffStr = speedup >= 1.0
        ? '**${speedup.toStringAsFixed(2)}x faster**'
        : '**${(1.0 / speedup).toStringAsFixed(2)}x slower**';
    final ratioStr = '${speedup.toStringAsFixed(2)}x';
    final ciStr = _formatMatrixFiellerCi(baselineEntry, entry, speedup);
    final statusLabel = _classifyMovement(speedup, isDelta: false).$1;

    return [diffStr, ratioStr, ciStr, statusLabel];
  }

  static String _formatMatrixFiellerCi(
    BenchmarkEntry baselineEntry,
    BenchmarkEntry entry,
    double speedup,
  ) {
    final ci = _formatFiellerCi(baselineEntry, entry);
    if (speedup >= 1.05 || speedup <= 0.95) {
      return '**$ci**';
    }
    return ci;
  }

  static String renderAllGroupComparisonTables(BenchmarkSuiteResult suite) {
    final buffer = StringBuffer();
    final map = <(String, String), List<BenchmarkEntry>>{};
    for (final entry in suite.benchmarks) {
      final group = entry.coordinates['group'];
      if (group != null && group.isNotEmpty) {
        map.putIfAbsent((group, entry.target), () => []).add(entry);
      }
    }

    final keys = map.keys.toList()
      ..sort((a, b) {
        final g = a.$1.compareTo(b.$1);
        if (g != 0) return g;
        return a.$2.compareTo(b.$2);
      });

    for (final key in keys) {
      final entries = map[key]!;
      buffer.writeln(
        renderGroupComparisonTable(
          groupName: key.$1,
          target: key.$2,
          entries: entries,
        ),
      );
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Renders a Model 1 direct variant comparison table for a specific group.
  static String renderGroupComparisonTable({
    required String groupName,
    required String target,
    required List<BenchmarkEntry> entries,
    String? title,
  }) {
    if (entries.isEmpty) return '';
    final strippedEntries = entries.map((e) {
      final newCoords = Map<String, String>.from(e.coordinates);
      newCoords.remove('group');
      return e.copyWith(coordinates: newCoords);
    }).toList();
    final legacyHeading = 'Group: $groupName (`$target`)';
    return renderMatrixComparisonTable(
      workloadName: groupName,
      entries: strippedEntries,
      title: title ?? legacyHeading,
    );
  }

  /// Renders a single-run summary table for all benchmarks in [suite].
  static String renderSummaryTable(
    BenchmarkSuiteResult suite, {
    String? title,
  }) {
    final buffer = StringBuffer();
    if (title != null) {
      buffer.writeln('### $title');
      buffer.writeln();
    }

    final hasThroughput = suite.benchmarks.any((b) => b.throughput != null);

    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
    if (hasThroughput) {
      buffer.writeln(
        '| Benchmark | Target | Ops/sec | Throughput | Mean Latency | '
        'Median | Min | StdDev | Stability |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | '
        ':---: |',
      );
    } else {
      buffer.writeln(
        '| Benchmark | Target | Ops/sec | Mean Latency | Median | Min | '
        'StdDev | Stability |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |',
      );
    }

    for (final b in suite.benchmarks) {
      final m = b.metrics;
      final opsStr = _formatOps(m.opsPerSec);
      final tpStr = b.throughput?.formatRate(m.meanNs) ?? '-';
      final meanStr = _formatLatency(m.meanNs);
      final medianStr = _formatLatency(m.medianNs);
      final minStr = _formatLatency(m.minNs);
      final cvPct = (m.cv * 100).toStringAsFixed(1);
      final stdDevStr = '±${_formatLatency(m.stddevNs)} ($cvPct%)';
      final statusStr = m.isStable ? '✅ Stable' : '⚠️ Unstable';

      if (hasThroughput) {
        buffer.writeln(
          '| ${b.name} | `${b.target}` | $opsStr | $tpStr | $meanStr | '
          '$medianStr | $minStr | $stdDevStr | $statusStr |',
        );
      } else {
        buffer.writeln(
          '| ${b.name} | `${b.target}` | $opsStr | $meanStr | $medianStr | '
          '$minStr | $stdDevStr | $statusStr |',
        );
      }
    }

    buffer.writeln('<!-- mdformat on -->');
    return buffer.toString();
  }

  /// Renders an isolated Before-vs-After delta comparison table comparing
  /// [baseline] to [current].
  static String renderDeltaTable({
    required BenchmarkSuiteResult baseline,
    required BenchmarkSuiteResult current,
    String? title,
    String baselineLabel = 'Baseline',
    String currentLabel = 'Current',
  }) {
    final buffer = StringBuffer();
    final heading = title ?? 'Before vs. After Delta Comparison';
    buffer.writeln('### $heading');
    buffer.writeln();

    final matched = _findMatchedEntries(baseline, current);
    if (matched.isEmpty) {
      buffer.writeln(
        '_No matching benchmarks found between baseline and current results._',
      );
      return buffer.toString();
    }

    buffer.write(
      _renderDeltaRows(
        matched,
        baselineLabel: baselineLabel,
        currentLabel: currentLabel,
      ),
    );

    return buffer.toString();
  }

  static List<(BenchmarkEntry, BenchmarkEntry)> _findMatchedEntries(
    BenchmarkSuiteResult baseline,
    BenchmarkSuiteResult current,
  ) {
    final matched = <(BenchmarkEntry, BenchmarkEntry)>[];
    for (final cur in current.benchmarks) {
      final base = baseline.findEntry(cur.name, cur.target);
      if (base != null) {
        matched.add((base, cur));
      }
    }
    return matched;
  }

  static String _renderDeltaRows(
    List<(BenchmarkEntry, BenchmarkEntry)> matched, {
    required String baselineLabel,
    required String currentLabel,
  }) {
    final buffer = StringBuffer();
    final hasThroughput = matched.any(
      (pair) => pair.$1.throughput != null || pair.$2.throughput != null,
    );
    var fasterCount = 0;
    var slowerCount = 0;
    var neutralCount = 0;
    var logSum = 0.0;

    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
    if (hasThroughput) {
      buffer.writeln(
        '| Benchmark | Target | Throughput | $baselineLabel | $currentLabel | '
        'Absolute Delta | Delta (%) | Speedup | 95% CI (Fieller) | Status |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | '
        ':---: | :---: |',
      );
    } else {
      buffer.writeln(
        '| Benchmark | Target | $baselineLabel | $currentLabel | '
        'Absolute Delta | Delta (%) | Speedup | 95% CI (Fieller) | Status |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | '
        ':---: |',
      );
    }

    for (final (base, cur) in matched) {
      final (rowStr, speedup, trend) = _formatDeltaRow(
        base,
        cur,
        hasThroughput: hasThroughput,
      );
      buffer.writeln(rowStr);
      logSum += math.log(speedup);
      if (trend > 0) fasterCount++;
      if (trend < 0) slowerCount++;
      if (trend == 0) neutralCount++;
    }

    buffer.writeln('<!-- mdformat on -->');
    buffer.writeln();

    final geomean = math.exp(logSum / matched.length);
    final geomeanStr = geomean.toStringAsFixed(2);
    buffer.writeln(
      '> **Summary**: Geometric Mean Speedup: **${geomeanStr}x** | '
      '🚀 **$fasterCount** Faster | ⚠️ **$slowerCount** Slower | '
      '➖ **$neutralCount** Neutral',
    );

    return buffer.toString();
  }

  static (String, double, int) _formatDeltaRow(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    bool hasThroughput = false,
  }) {
    final baseMean = base.metrics.meanNs;
    final curMean = cur.metrics.meanNs;
    final diffNs = curMean - baseMean;
    final deltaPct = baseMean > 0.0 ? (diffNs / baseMean) * 100.0 : 0.0;
    final speedup = (curMean > 0.0 && baseMean > 0.0)
        ? (baseMean / curMean)
        : 1.0;

    final (statusStr, trend) = _classifyMovement(speedup, isDelta: true);
    final baseStr = _formatLatency(baseMean);
    final curStr = _formatLatency(curMean);
    final diffStr = _formatDelta(diffNs);
    final pctStr = _formatPercent(deltaPct);
    final speedupStr = '${speedup.toStringAsFixed(2)}x';
    final ciStr = _formatFiellerCi(base, cur);

    if (hasThroughput) {
      final tp = cur.throughput ?? base.throughput;
      final tpStr = tp?.formatRate(curMean) ?? '-';
      final row =
          '| ${cur.name} | `${cur.target}` | $tpStr | $baseStr | $curStr | '
          '$diffStr | $pctStr | $speedupStr | $ciStr | $statusStr |';
      return (row, speedup, trend);
    }

    final row =
        '| ${cur.name} | `${cur.target}` | $baseStr | $curStr | $diffStr | '
        '$pctStr | $speedupStr | $ciStr | $statusStr |';

    return (row, speedup, trend);
  }

  /// Renders a Markdown summary report directly from a stored JSON file.
  static String renderFromFile(File file, {String? title}) {
    final suite = BenchmarkSuiteResult.loadFromFile(file);
    return renderSuite(suite, title: title);
  }

  /// Renders a Markdown summary report directly from a stored JSON file path.
  static String renderFromPath(String path, {String? title}) =>
      renderFromFile(File(path), title: title);

  /// Renders an isolated delta comparison table comparing two stored JSON
  /// files.
  static String renderDeltaFromFiles({
    required File baselineFile,
    required File currentFile,
    String? title,
    String baselineLabel = 'Baseline',
    String currentLabel = 'Current',
  }) {
    final baseline = BenchmarkSuiteResult.loadFromFile(baselineFile);
    final current = BenchmarkSuiteResult.loadFromFile(currentFile);
    return renderDeltaTable(
      baseline: baseline,
      current: current,
      title: title,
      baselineLabel: baselineLabel,
      currentLabel: currentLabel,
    );
  }

  static (String, int) _classifyMovement(
    double speedup, {
    bool isDelta = false,
  }) {
    if (speedup >= 1.05) return (isDelta ? '🚀 Faster' : '🚀 🥇 Peak', 1);
    if (speedup <= 0.95) return (isDelta ? '⚠️ Regression' : '⚠️ 🔴 Slow', -1);
    return ('➖ ⚪ Neutral', 0);
  }

  static String _formatLatency(double ns) => switch (ns) {
    < 1000.0 => '${ns.toStringAsFixed(1)} ns',
    < 1000000.0 => '${(ns / 1000.0).toStringAsFixed(2)} µs',
    < 1000000000.0 => '${(ns / 1000000.0).toStringAsFixed(2)} ms',
    _ => '${(ns / 1000000000.0).toStringAsFixed(2)} s',
  };

  static String _formatDelta(double diffNs) {
    if (diffNs.abs() < 1e-9) return '0.0 ns';
    final sign = diffNs > 0 ? '+' : '-';
    return '$sign${_formatLatency(diffNs.abs())}';
  }

  static String _formatPercent(double pct) {
    if (pct.abs() < 1e-9) return '0.0%';
    final sign = pct > 0 ? '+' : '';
    return '$sign${pct.toStringAsFixed(1)}%';
  }

  static final _thousandsRegExp = RegExp(r'(\d)(?=(\d{3})+(?!\d))');

  static String _formatOps(double ops) {
    if (ops <= 0.0) return '0 ops/s';
    if (ops < 10.0) return '${ops.toStringAsFixed(2)} ops/s';
    final formatted = ops.round().toString().replaceAllMapped(
      _thousandsRegExp,
      (m) => '${m[1]},',
    );
    return '$formatted ops/s';
  }

  static String _formatFiellerCi(BenchmarkEntry base, BenchmarkEntry cur) {
    if (base.rawTrialsNs.length < 2 || cur.rawTrialsNs.length < 2) {
      return '[N/A]';
    }
    final interval = FiellerInterval.compute(
      sampleA: base.rawTrialsNs,
      sampleB: cur.rawTrialsNs,
    );
    if (!interval.isValid ||
        interval.lowerBound.isNaN ||
        interval.upperBound.isNaN) {
      return '[N/A]';
    }
    final low = interval.lowerBound.toStringAsFixed(2);
    final high = interval.upperBound.toStringAsFixed(2);
    return '[$low x, $high x]';
  }
}
