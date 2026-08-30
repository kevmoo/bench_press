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

    final groupTables = renderAllGroupComparisonTables(suite);
    if (groupTables.isNotEmpty) {
      buffer.write(groupTables);
    }

    final summaryTitle = groupTables.isNotEmpty ? 'All Benchmarks' : null;
    buffer.writeln(renderSummaryTable(suite, title: summaryTitle));
    return buffer.toString().trimRight();
  }

  /// Renders all group comparison tables present in [suite].
  static String renderAllGroupComparisonTables(BenchmarkSuiteResult suite) {
    final buffer = StringBuffer();
    final map = <(String, String), List<BenchmarkEntry>>{};
    for (final entry in suite.benchmarks) {
      final group = entry.group;
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
    final buffer = StringBuffer();
    final heading = title ?? 'Group: $groupName (`$target`)';
    buffer.writeln('### $heading');
    buffer.writeln();

    final baselineEntry = _resolveBaseline(entries);
    final baselineName = baselineEntry.name;
    final maxSpeedup = _findMaxSpeedup(entries, baselineEntry);
    final hasThroughput = entries.any((e) => e.throughput != null);

    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
    if (hasThroughput) {
      buffer.writeln(
        '| Implementation | Ops/sec | Throughput | Mean Latency | vs. Baseline (`$baselineName`) | '
        'Speedup Ratio | 95% Confidence Interval | Status |',
      );
      buffer.writeln(
        '| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |',
      );
    } else {
      buffer.writeln(
        '| Implementation | Ops/sec | Mean Latency | vs. Baseline (`$baselineName`) | '
        'Speedup Ratio | 95% Confidence Interval | Status |',
      );
      buffer.writeln(
        '| :--- | :---: | :---: | :---: | :---: | :---: | :---: |',
      );
    }

    for (final entry in entries) {
      buffer.writeln(
        _formatGroupRow(
          entry: entry,
          baselineEntry: baselineEntry,
          maxSpeedup: maxSpeedup,
          hasThroughput: hasThroughput,
        ),
      );
    }

    buffer.writeln('<!-- mdformat on -->');
    return buffer.toString().trimRight();
  }

  static BenchmarkEntry _resolveBaseline(List<BenchmarkEntry> entries) {
    for (final e in entries) {
      if (e.isBaseline) return e;
    }
    return entries.first;
  }

  static double _findMaxSpeedup(
    List<BenchmarkEntry> entries,
    BenchmarkEntry baseline,
  ) {
    var max = 1.0;
    final baseMean = baseline.metrics.meanNs;
    if (baseMean <= 0) return max;
    for (final e in entries) {
      if (e == baseline) continue;
      final mean = e.metrics.meanNs;
      if (mean > 0) {
        final ratio = baseMean / mean;
        if (ratio > max) max = ratio;
      }
    }
    return max;
  }

  static String _formatGroupRow({
    required BenchmarkEntry entry,
    required BenchmarkEntry baselineEntry,
    required double maxSpeedup,
    required bool hasThroughput,
  }) {
    final isBaseline = (entry == baselineEntry);
    final implCol = isBaseline
        ? '`${entry.name}` (Baseline)'
        : '`${entry.name}`';
    final opsCol = _formatOps(entry.metrics.opsPerSec);
    final meanCol = _formatLatency(entry.metrics.meanNs);
    final tpCol = entry.throughput?.formatRate(entry.metrics.meanNs) ?? '-';

    if (isBaseline) {
      return hasThroughput
          ? '| $implCol | $opsCol | $tpCol | $meanCol | 1.00x (ref) | 1.00x | '
                '[1.00x – 1.00x] | Ref |'
          : '| $implCol | $opsCol | $meanCol | 1.00x (ref) | 1.00x | '
                '[1.00x – 1.00x] | Ref |';
    }

    final baseMean = baselineEntry.metrics.meanNs;
    final curMean = entry.metrics.meanNs;
    final speedup = (baseMean > 0.0 && curMean > 0.0)
        ? (baseMean / curMean)
        : 1.0;

    final vsBaselineCol = _formatVsBaseline(
      speedup: speedup,
      baseMean: baseMean,
      curMean: curMean,
    );
    final ratioCol = '${speedup.toStringAsFixed(2)}x';
    final ciCol = _formatGroupFiellerCi(baselineEntry, entry, speedup >= 1.05);
    final statusCol = _classifyGroupStatus(speedup, maxSpeedup);

    if (hasThroughput) {
      return '| $implCol | $opsCol | $tpCol | $meanCol | $vsBaselineCol | '
          '$ratioCol | $ciCol | $statusCol |';
    }
    return '| $implCol | $opsCol | $meanCol | $vsBaselineCol | $ratioCol | '
        '$ciCol | $statusCol |';
  }

  static String _formatVsBaseline({
    required double speedup,
    required double baseMean,
    required double curMean,
  }) {
    if (speedup >= 1.05) {
      return '**${speedup.toStringAsFixed(2)}x faster**';
    } else if (speedup <= 0.95) {
      final slowdown = (baseMean > 0.0 && curMean > 0.0)
          ? (curMean / baseMean)
          : 1.0;
      return '**${slowdown.toStringAsFixed(2)}x slower**';
    }
    return '${speedup.toStringAsFixed(2)}x (neutral)';
  }

  static String _classifyGroupStatus(double speedup, double maxSpeedup) {
    if ((speedup - maxSpeedup).abs() < 1e-4 && speedup >= 1.05) {
      return '🚀 🥇 Peak';
    } else if (speedup >= 1.05) {
      return '🚀 🟢 Fast';
    } else if (speedup <= 0.95) {
      return '⚠️ 🔴 Slow';
    }
    return '➖ ⚪ Similar';
  }

  static String _formatGroupFiellerCi(
    BenchmarkEntry base,
    BenchmarkEntry cur,
    bool isFast,
  ) {
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
    return isFast ? '**[$low x – $high x]**' : '[$low x – $high x]';
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
    var fasterCount = 0;
    var slowerCount = 0;
    var neutralCount = 0;
    var speedupProduct = 1.0;

    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
    buffer.writeln(
      '| Benchmark | Target | $baselineLabel | $currentLabel | '
      'Absolute Delta | Delta (%) | Speedup | 95% CI (Fieller) | Status |',
    );
    buffer.writeln(
      '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |',
    );

    for (final (base, cur) in matched) {
      final (rowStr, speedup, trend) = _formatDeltaRow(base, cur);
      buffer.writeln(rowStr);
      speedupProduct *= speedup;
      if (trend > 0) fasterCount++;
      if (trend < 0) slowerCount++;
      if (trend == 0) neutralCount++;
    }

    buffer.writeln('<!-- mdformat on -->');
    buffer.writeln();

    final geomean = math.pow(speedupProduct, 1.0 / matched.length).toDouble();
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
    BenchmarkEntry cur,
  ) {
    final baseMean = base.metrics.meanNs;
    final curMean = cur.metrics.meanNs;
    final diffNs = curMean - baseMean;
    final deltaPct = baseMean > 0.0 ? (diffNs / baseMean) * 100.0 : 0.0;
    final speedup = (curMean > 0.0 && baseMean > 0.0)
        ? (baseMean / curMean)
        : 1.0;

    final (statusStr, trend) = _classifyMovement(speedup);
    final baseStr = _formatLatency(baseMean);
    final curStr = _formatLatency(curMean);
    final diffStr = _formatDelta(diffNs);
    final pctStr = _formatPercent(deltaPct);
    final speedupStr = '${speedup.toStringAsFixed(2)}x';
    final ciStr = _formatFiellerCi(base, cur);

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

  static (String, int) _classifyMovement(double speedup) => switch (speedup) {
    >= 1.05 => ('🚀 Faster', 1),
    <= 0.95 => ('⚠️ Regression', -1),
    _ => ('➖ Neutral', 0),
  };

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

  static String _formatOps(double ops) {
    if (ops <= 0.0) return '0 ops/s';
    final rounded = ops.round();
    final str = rounded.toString();
    final chars = str.split('').reversed.toList();
    final buffer = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(chars[i]);
    }
    return '${buffer.toString().split('').reversed.join()} ops/s';
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
