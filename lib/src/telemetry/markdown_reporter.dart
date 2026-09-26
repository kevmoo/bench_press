import 'dart:io';
import 'dart:math' as math;

import '../stats/fieller.dart';
import 'plausibility.dart';
import 'schema.dart';

/// Generates formatted Markdown tables and performance telemetry reports.
abstract final class MarkdownReporter() {
  /// Renders a full comprehensive Markdown report for a [BenchmarkSuiteResult].
  static String renderSuite(
    BenchmarkSuiteResult suite, {
    String? title,
    bool gate = true,
  }) {
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

    _writePlausibilityNotes(buffer, suite);
    _writeInvarianceNotes(buffer, suite);

    final isLegacyGrouped =
        suite.benchmarks.isNotEmpty &&
        suite.benchmarks.any((b) => b.coordinates.group != null) &&
        suite.benchmarks.every(
          (b) => b.coordinates.keys.every(
            (k) => k == BenchmarkCoordinates.groupKey,
          ),
        );

    if (isLegacyGrouped) {
      buffer.write(_renderLegacyGroupedSuite(suite, gate: gate));
      return buffer.toString().trimRight();
    }

    final workloads = _groupMatrixByWorkload(suite);
    final targetCounts = <String, int>{};
    for (final key in workloads.keys) {
      targetCounts[key.$1] = (targetCounts[key.$1] ?? 0) + 1;
    }
    for (final workload in workloads.entries) {
      final (workloadName, target, isGroup) = workload.key;
      final defaultTitle = isGroup
          ? 'Group: $workloadName (`$target`)'
          : ((targetCounts[workloadName] ?? 1) > 1
                ? 'Benchmark: `$workloadName` (`$target`)'
                : 'Benchmark: `$workloadName`');
      buffer.writeln(
        renderMatrixComparisonTable(
          workloadName: workloadName,
          entries: workload.value,
          title: defaultTitle,
          gate: gate,
        ),
      );
      buffer.writeln();
    }

    buffer.writeln(renderSummaryTable(suite, title: 'All Benchmarks'));
    return buffer.toString().trimRight();
  }

  static String _renderLegacyGroupedSuite(
    BenchmarkSuiteResult suite, {
    bool gate = true,
  }) {
    final buffer = StringBuffer();
    final suiteSummary = renderSuiteSummaryTable(suite, gate: gate);
    if (suiteSummary.isNotEmpty) {
      buffer.writeln(suiteSummary);
      buffer.writeln();
    }
    final groupTables = renderAllGroupComparisonTables(suite, gate: gate);
    if (groupTables.isNotEmpty) {
      buffer.write(groupTables);
    }
    final summaryTitle = groupTables.isNotEmpty ? 'All Benchmarks' : null;
    buffer.writeln(renderSummaryTable(suite, title: summaryTitle));
    return buffer.toString();
  }

  /// Renders a top-level Suite Summary table rolling up candidate performance
  /// across multiple `coordinates.group` comparison groups using geometric mean
  /// speedup.
  ///
  /// Returns an empty string when there are fewer than 2 distinct comparison
  /// groups with a baseline and at least one candidate participating across
  /// multiple groups.
  static String renderSuiteSummaryTable(
    BenchmarkSuiteResult suite, {
    String? title,
    bool gate = true,
  }) {
    final (distinctGroupCount, candidateSpeedups) =
        _collectCandidateGroupSpeedups(suite, gate: gate);
    if (distinctGroupCount < 2 || candidateSpeedups.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    final heading = title ?? 'Suite Summary';
    buffer.writeln('### $heading\n');
    buffer.writeln(
      '| Candidate | Target | Geometric Mean Speedup | Min Speedup | '
      'Max Speedup | Groups |',
    );
    buffer.writeln('| :--- | :--- | :---: | :---: | :---: | :---: |');

    final targets = <String>{for (final key in candidateSpeedups.keys) key.$2};
    for (final target in targets) {
      for (final key in candidateSpeedups.keys) {
        if (key.$2 == target) {
          buffer.writeln(
            _formatSuiteSummaryRow(key.$1, target, candidateSpeedups[key]!),
          );
        }
      }
    }
    return buffer.toString().trimRight();
  }

  static (int, Map<(String, String), List<double>>)
  _collectCandidateGroupSpeedups(
    BenchmarkSuiteResult suite, {
    bool gate = true,
  }) {
    final groups = <(String, String), List<BenchmarkEntry>>{};
    for (final entry in suite.benchmarks) {
      final group = entry.coordinates.group;
      if (group != null && group.isNotEmpty) {
        groups.putIfAbsent((group, entry.target), () => []).add(entry);
      }
    }

    final distinctGroups = <String>{};
    final candidateSpeedups = <(String, String), List<double>>{};
    for (final MapEntry(:key, :value) in groups.entries) {
      _recordGroupSpeedups(
        key.$1,
        value,
        distinctGroups,
        candidateSpeedups,
        gate: gate,
      );
    }
    candidateSpeedups.removeWhere((_, speedups) => speedups.length < 2);
    return (distinctGroups.length, candidateSpeedups);
  }

  static void _recordGroupSpeedups(
    String groupName,
    List<BenchmarkEntry> entries,
    Set<String> distinctGroups,
    Map<(String, String), List<double>> candidateSpeedups, {
    bool gate = true,
  }) {
    if (entries.length < 2) return;
    distinctGroups.add(groupName);

    final baseEntry = entries.firstWhere(
      (e) => e.isBaseline,
      orElse: () => entries.first,
    );
    final baseMeanNs = baseEntry.metrics.meanNs;

    for (final entry in entries) {
      if (identical(entry, baseEntry)) continue;
      if (gate && !_computeFiellerVerdict(baseEntry, entry).resolved) continue;
      final curMeanNs = entry.metrics.meanNs;
      final ratio =
          (curMeanNs.isFinite &&
              baseMeanNs.isFinite &&
              curMeanNs > 0.0 &&
              baseMeanNs > 0.0)
          ? (baseMeanNs / curMeanNs)
          : 1.0;
      final speedup = (ratio.isFinite && ratio > 0.0) ? ratio : 1.0;
      candidateSpeedups
          .putIfAbsent((entry.name, entry.target), () => [])
          .add(speedup);
    }
  }

  static String _formatSuiteSummaryRow(
    String candidate,
    String target,
    List<double> speedups,
  ) {
    final count = speedups.length;
    var logSum = 0.0;
    for (final s in speedups) {
      logSum += math.log(s);
    }
    final geomean = math.exp(logSum / count);
    final minSpeedup = speedups.reduce(math.min);
    final maxSpeedup = speedups.reduce(math.max);

    return '| `$candidate` | `$target` | **${geomean.toStringAsFixed(2)}x** | '
        '${minSpeedup.toStringAsFixed(2)}x | '
        '${maxSpeedup.toStringAsFixed(2)}x | $count |';
  }

  static Map<(String, String, bool), List<BenchmarkEntry>>
  _groupMatrixByWorkload(BenchmarkSuiteResult suite) {
    final map = <(String, String, bool), List<BenchmarkEntry>>{};
    for (final b in suite.benchmarks) {
      final group = b.coordinates.group;
      if (group != null && group.isNotEmpty) {
        final newCoords = Map<String, String>.from(b.coordinates)
          ..remove(BenchmarkCoordinates.groupKey);
        map
            .putIfAbsent((group, b.target, true), () => [])
            .add(b.copyWith(coordinates: newCoords));
      } else {
        map.putIfAbsent((b.name, b.target, false), () => []).add(b);
      }
    }
    return map;
  }

  static String renderMatrixComparisonTable({
    required String workloadName,
    required List<BenchmarkEntry> entries,
    String? title,
    bool gate = true,
  }) {
    if (entries.isEmpty) return '';

    final buffer = StringBuffer();
    final heading = title ?? 'Benchmark: `$workloadName`';
    buffer.writeln('### $heading\n');

    final axesList = _extractSortedAxes(entries);
    final hasThroughput = entries.any((e) => e.throughput != null);
    final baseEntry = entries.firstWhere(
      (e) => e.isBaseline,
      orElse: () => entries.first,
    );
    final orderedEntries = [
      baseEntry,
      ...entries.where((e) => !identical(e, baseEntry)),
    ];
    final includeNameCol =
        axesList.isEmpty ||
        orderedEntries.map((e) => e.name).toSet().length > 1;

    _writeMatrixHeader(
      buffer,
      axesList,
      hasThroughput,
      baseEntry,
      includeNameCol: includeNameCol,
    );

    final stats = _DeltaStats();
    final baseMeanNs = baseEntry.metrics.meanNs;
    for (final entry in orderedEntries) {
      buffer.writeln(
        _formatMatrixRow(
          entry,
          baseEntry,
          baseMeanNs,
          hasThroughput,
          axesList,
          gate,
          stats,
          includeNameCol: includeNameCol,
        ),
      );
    }
    _updateMatrixBatchDivergence(orderedEntries, stats);
    if (orderedEntries.length > 1) {
      _writeDeltaFooter(buffer, stats);
    } else {
      _writeAdvisoryNotes(buffer, stats);
    }
    return buffer.toString().trimRight();
  }

  static List<String> _extractSortedAxes(List<BenchmarkEntry> entries) {
    final axes = <String>{};
    for (final e in entries) {
      axes.addAll(e.coordinates.keys);
    }
    return axes.toList()..sort();
  }

  static void _writeMatrixHeader(
    StringBuffer buffer,
    List<String> axesList,
    bool hasThroughput,
    BenchmarkEntry baseEntry, {
    required bool includeNameCol,
  }) {
    final baselineLabel = _formatBaselineLabel(
      baseEntry,
      axesList,
      includeNameCol: includeNameCol,
    );
    final headerRow = <String>[
      if (includeNameCol) 'Implementation',
      for (final axis in axesList)
        axis.isEmpty ? 'Variant' : axis[0].toUpperCase() + axis.substring(1),
      'Batch',
      'Ops/sec',
      if (hasThroughput) 'Throughput',
      'Mean Latency',
      'vs. Baseline (`$baselineLabel`)',
      'Speedup Ratio',
      '95% Confidence Interval',
      'Status',
    ];
    buffer.writeln('| ${headerRow.join(' | ')} |');

    final dimCount = axesList.length + (includeNameCol ? 1 : 0);
    final metricCount = hasThroughput ? 8 : 7;
    final sepRow = <String>[
      for (var i = 0; i < dimCount; i++) ':---',
      for (var i = 0; i < metricCount; i++) ':---:',
    ];
    buffer.writeln('| ${sepRow.join(' | ')} |');
  }

  static void _updateMatrixBatchDivergence(
    List<BenchmarkEntry> entries,
    _DeltaStats stats,
  ) {
    var minB = 0;
    var maxB = 0;
    for (final e in entries) {
      final b = e.calibratedBatchIterations;
      if (b == null || b <= 0) continue;
      if (minB == 0 || b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    if (minB > 0 && maxB > minB) {
      stats.maxBatchDiv = maxB / minB;
      stats.divMinBatch = minB;
      stats.divMaxBatch = maxB;
    }
  }

  static String _formatBaselineLabel(
    BenchmarkEntry entry,
    List<String> axes, {
    required bool includeNameCol,
  }) {
    if (axes.isEmpty) return entry.name;
    final vals = axes.map((a) => entry.coordinates[a] ?? '-').toList();
    if (includeNameCol) {
      return '${entry.name}, ${vals.join(', ')}';
    }
    return vals.join(', ');
  }

  static String _formatMatrixRow(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double baseMeanNs,
    bool hasThroughput,
    List<String> axes,
    bool gate,
    _DeltaStats stats, {
    required bool includeNameCol,
  }) {
    final curMeanNs = entry.metrics.meanNs;
    final speedup = (curMeanNs > 0.0 && baseMeanNs > 0.0)
        ? (baseMeanNs / curMeanNs)
        : 1.0;

    final batchStr = entry.calibratedBatchIterations?.toString() ?? '-';

    final cols = <String>[
      ..._formatDimensionCols(
        entry,
        baselineEntry,
        axes,
        includeNameCol: includeNameCol,
      ),
      batchStr,
      _formatOps(entry.metrics.opsPerSec),
      if (hasThroughput) entry.throughput?.formatRate(curMeanNs) ?? '-',
      _formatLatency(curMeanNs),
      ..._formatComparisonCols(entry, baselineEntry, speedup, gate, stats),
    ];

    return '| ${cols.join(' | ')} |';
  }

  static List<String> _formatDimensionCols(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    List<String> axes, {
    required bool includeNameCol,
  }) {
    final isBase = identical(entry, baselineEntry);
    final suffix = isBase ? ' (Baseline)' : '';
    if (axes.isEmpty) {
      return ['`${entry.name}`$suffix'];
    }
    if (includeNameCol) {
      return [
        '`${entry.name}`$suffix',
        for (final axis in axes) '`${entry.coordinates[axis] ?? '-'}`',
      ];
    }
    return [
      for (final axis in axes) '`${entry.coordinates[axis] ?? '-'}`$suffix',
    ];
  }

  static List<String> _formatComparisonCols(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double speedup,
    bool gate,
    _DeltaStats stats,
  ) {
    if (identical(entry, baselineEntry)) {
      return ['1.00x (ref)', '1.00x', '[1.00x – 1.00x]', 'Ref'];
    }

    final verdict = _computeFiellerVerdict(baselineEntry, entry);
    final isUnresolved = gate && !verdict.resolved;
    final movement = _classifyMovement(speedup, isDelta: false);
    if (isUnresolved) {
      stats.unresolvedCount++;
      stats.reasons.addAll(verdict.reasons);
    } else {
      stats.logSum += math.log(speedup);
      stats.includedInGeoMean++;
      if (movement.$2 > 0) stats.fasterCount++;
      if (movement.$2 < 0) stats.slowerCount++;
      if (movement.$2 == 0) stats.neutralCount++;
    }

    final diffStr = isUnresolved
        ? 'unresolved'
        : (speedup >= 1.0
              ? '**${speedup.toStringAsFixed(2)}x faster**'
              : '**${(1.0 / speedup).toStringAsFixed(2)}x slower**');
    final ratioStr = isUnresolved
        ? 'unresolved'
        : '${speedup.toStringAsFixed(2)}x';
    final ciStr = _formatMatrixFiellerCi(speedup, verdict);
    final statusLabel = isUnresolved ? '❓ Unresolved' : movement.$1;

    return [diffStr, ratioStr, ciStr, statusLabel];
  }

  static String _formatMatrixFiellerCi(double speedup, _Verdict verdict) {
    final ci = verdict.matrixCiString;
    if (verdict.resolved && (speedup >= 1.05 || speedup <= 0.95)) {
      return '**$ci**';
    }
    return ci;
  }

  static String renderAllGroupComparisonTables(
    BenchmarkSuiteResult suite, {
    bool gate = true,
  }) {
    final buffer = StringBuffer();
    final map = <(String, String), List<BenchmarkEntry>>{};
    for (final entry in suite.benchmarks) {
      final group = entry.coordinates.group;
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
          gate: gate,
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
    bool gate = true,
  }) {
    if (entries.isEmpty) return '';
    final strippedEntries = entries.map((e) {
      final newCoords = Map<String, String>.from(e.coordinates);
      newCoords.remove(BenchmarkCoordinates.groupKey);
      return e.copyWith(coordinates: newCoords);
    }).toList();
    final legacyHeading = 'Group: $groupName (`$target`)';
    return renderMatrixComparisonTable(
      workloadName: groupName,
      entries: strippedEntries,
      title: title ?? legacyHeading,
      gate: gate,
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
    bool gate = true,
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
        gate: gate,
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
    bool gate = true,
  }) {
    final buffer = StringBuffer();
    final hasThroughput = matched.any(
      (p) => p.$1.throughput != null || p.$2.throughput != null,
    );

    var stats = _DeltaStats();

    _writeDeltaHeader(buffer, hasThroughput, baselineLabel, currentLabel);

    for (final (base, cur) in matched) {
      _processDeltaRow(buffer, base, cur, hasThroughput, gate, stats);
    }

    _writeDeltaFooter(buffer, stats);

    return buffer.toString();
  }

  static void _writeDeltaHeader(
    StringBuffer buffer,
    bool hasThroughput,
    String baselineLabel,
    String currentLabel,
  ) {
    if (hasThroughput) {
      buffer.writeln(
        '| Benchmark | Target | Batch | Throughput | $baselineLabel | '
        '$currentLabel | Absolute Delta | Delta (%) | Speedup | '
        '95% CI (Fieller) | Status |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | '
        ':---: | :---: | :---: |',
      );
    } else {
      buffer.writeln(
        '| Benchmark | Target | Batch | $baselineLabel | $currentLabel | '
        'Absolute Delta | Delta (%) | Speedup | 95% CI (Fieller) | Status |',
      );
      buffer.writeln(
        '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | '
        ':---: | :---: |',
      );
    }
  }

  static void _processDeltaRow(
    StringBuffer buffer,
    BenchmarkEntry base,
    BenchmarkEntry cur,
    bool hasThroughput,
    bool gate,
    _DeltaStats stats,
  ) {
    final (rowStr, speedup, trend, verdict) = _formatDeltaRow(
      base,
      cur,
      hasThroughput: hasThroughput,
      gate: gate,
    );
    buffer.writeln(rowStr);

    if (gate && !verdict.resolved) {
      stats.unresolvedCount++;
      stats.reasons.addAll(verdict.reasons);
    } else {
      stats.logSum += math.log(speedup);
      stats.includedInGeoMean++;
      if (trend > 0) stats.fasterCount++;
      if (trend < 0) stats.slowerCount++;
      if (trend == 0) stats.neutralCount++;
    }

    final bBase = base.calibratedBatchIterations;
    final bCur = cur.calibratedBatchIterations;
    if (bBase != null && bCur != null && bBase > 0 && bCur > 0) {
      final maxB = math.max(bBase, bCur);
      final minB = math.min(bBase, bCur);
      final div = maxB / minB;
      if (div > stats.maxBatchDiv) {
        stats.maxBatchDiv = div.toDouble();
        stats.divMinBatch = minB;
        stats.divMaxBatch = maxB;
      }
    }
  }

  /// Emits a banner for any declared byte throughput that exceeds memory
  /// bandwidth, which almost always means the benchmark never read its
  /// payload.
  static void _writePlausibilityNotes(
    StringBuffer buffer,
    BenchmarkSuiteResult suite,
  ) {
    final findings = ThroughputPlausibility.screenSuite(suite);
    if (findings.isEmpty) {
      return;
    }
    final ceiling =
        ThroughputPlausibility.maxPlausibleBytesPerSecond /
        (1024 * 1024 * 1024);
    final isOne = findings.length == 1;
    buffer.writeln(
      '> 🚩 **Implausible throughput** — '
      '${findings.length} benchmark${isOne ? '' : 's'} '
      'report${isOne ? 's' : ''} faster than '
      '${ceiling.toStringAsFixed(0)} GiB/s, above the memory bandwidth of '
      'any machine this could run on.',
    );
    for (final finding in findings) {
      buffer.writeln(
        '> - `${finding.benchmarkName}` (`${finding.target}`): '
        '**${finding.gibPerSecond.toStringAsFixed(2)} GiB/s** on a '
        '${_formatBytes(finding.bytes)} payload, '
        '${finding.overCeilingFactor.toStringAsFixed(1)}x over.',
      );
    }
    buffer.writeln(
      '> A benchmark whose sink stores the payload without reading it times '
      'loop overhead, not data movement, and reports the same latency for '
      'every size. Confirm the bytes are consumed before quoting these.',
    );
    buffer.writeln();
  }

  /// Emits a banner for any benchmark whose latency held steady while its
  /// declared payload grew, which catches the same defect at sizes small
  /// enough to stay under the bandwidth ceiling.
  static void _writeInvarianceNotes(
    StringBuffer buffer,
    BenchmarkSuiteResult suite,
  ) {
    final findings = ThroughputPlausibility.screenInvariance(suite);
    if (findings.isEmpty) {
      return;
    }
    final isOne = findings.length == 1;
    buffer.writeln(
      '> 🚩 **Latency does not track payload size** — '
      '${findings.length} benchmark${isOne ? '' : 's'} '
      'cost${isOne ? 's' : ''} the same across a wide spread in declared '
      'bytes.',
    );
    for (final finding in findings) {
      final label = finding.groupScoped
          ? 'group `${finding.benchmarkName}`'
          : '`${finding.benchmarkName}`';
      buffer.writeln(
        '> - $label (`${finding.target}`): '
        '${_formatBytes(finding.smallBytes)} at '
        '${_formatLatency(finding.smallLatencyNs)} vs '
        '${_formatBytes(finding.largeBytes)} at '
        '${_formatLatency(finding.largeLatencyNs)} — '
        '**${_formatRatio(finding.volumeRatio)}x** the data for '
        '**${finding.latencyRatio.toStringAsFixed(2)}x** the time'
        '${finding.groupScoped ? ', across the group\'s arms' : ''}.',
      );
    }
    buffer.writeln(
      '> Work proportional to the payload cannot be free. Confirm the bytes '
      'are read rather than passed along by reference.',
    );
    buffer.writeln();
  }

  static String _formatRatio(double ratio) =>
      ratio >= 100 ? ratio.toStringAsFixed(0) : ratio.toStringAsFixed(1);

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    return '$bytes B';
  }

  static void _writeAdvisoryNotes(StringBuffer buffer, _DeltaStats stats) {
    if (stats.maxBatchDiv > 2.0) {
      final divStr = stats.maxBatchDiv.toStringAsFixed(1);
      final rangeStr = '${stats.divMinBatch}–${stats.divMaxBatch}';
      buffer.writeln();
      buffer.writeln(
        '> ⚠️ Calibrated batch sizes differ by ${divStr}x across compared '
        'cells ($rangeStr).',
      );
      buffer.writeln(
        '> Latencies may reflect different GC regimes and are not directly '
        'comparable.',
      );
    }
    if (stats.reasons.isNotEmpty) {
      final joinedReasons = (stats.reasons.toList()..sort()).join(' and ');
      buffer.writeln();
      buffer.writeln(
        '> ❓ **Unresolved**: Speedup omitted due to $joinedReasons.',
      );
    }
  }

  static void _writeDeltaFooter(StringBuffer buffer, _DeltaStats stats) {
    _writeAdvisoryNotes(buffer, stats);
    buffer.writeln();

    if (stats.includedInGeoMean > 0) {
      final geomean = math.exp(stats.logSum / stats.includedInGeoMean);
      final geomeanStr = geomean.toStringAsFixed(2);
      final unresolvedStr = stats.unresolvedCount > 0
          ? ' | ❓ **${stats.unresolvedCount}** Unresolved '
                '(excluded from GeoMean)'
          : '';
      buffer.writeln(
        '> **Summary**: Geometric Mean Speedup: **${geomeanStr}x** | '
        '🚀 **${stats.fasterCount}** Faster | '
        '⚠️ **${stats.slowerCount}** Slower | '
        '➖ **${stats.neutralCount}** Neutral$unresolvedStr',
      );
    } else {
      buffer.writeln(
        '> **Summary**: No resolved measurements to compute Geometric Mean '
        'Speedup | '
        '❓ **${stats.unresolvedCount}** Unresolved (excluded from GeoMean)',
      );
    }
  }

  static (String, double, int, _Verdict) _formatDeltaRow(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    bool hasThroughput = false,
    bool gate = true,
  }) {
    final baseMean = base.metrics.meanNs;
    final curMean = cur.metrics.meanNs;
    final diffNs = curMean - baseMean;
    final deltaPct = baseMean > 0.0 ? (diffNs / baseMean) * 100.0 : 0.0;
    final speedup = (curMean > 0.0 && baseMean > 0.0)
        ? (baseMean / curMean)
        : 1.0;

    final verdict = _computeFiellerVerdict(base, cur);
    final isUnresolved = gate && !verdict.resolved;

    final (statusStr, trend) = isUnresolved
        ? ('❓ Unresolved', 0)
        : _classifyMovement(speedup, isDelta: true);

    final baseStr = _formatLatency(baseMean);
    final curStr = _formatLatency(curMean);
    final diffStr = _formatDelta(diffNs);
    final pctStr = _formatPercent(deltaPct);
    final speedupStr = isUnresolved
        ? 'unresolved'
        : '${speedup.toStringAsFixed(2)}x';
    final ciStr = verdict.ciString;

    final baseBatch = base.calibratedBatchIterations?.toString() ?? '-';
    final curBatch = cur.calibratedBatchIterations?.toString() ?? '-';
    final batchStr = identical(base, cur)
        ? baseBatch
        : (baseBatch == curBatch ? baseBatch : '$baseBatch → $curBatch');

    if (hasThroughput) {
      final tp = cur.throughput ?? base.throughput;
      final tpStr = tp?.formatRate(curMean) ?? '-';
      final row =
          '| ${cur.name} | `${cur.target}` | $batchStr | $tpStr | $baseStr | '
          '$curStr | $diffStr | $pctStr | $speedupStr | $ciStr | $statusStr |';
      return (row, speedup, trend, verdict);
    }

    final row =
        '| ${cur.name} | `${cur.target}` | $batchStr | $baseStr | $curStr | '
        '$diffStr | $pctStr | $speedupStr | $ciStr | $statusStr |';

    return (row, speedup, trend, verdict);
  }

  /// Renders a Markdown summary report directly from a stored JSON file.
  static String renderFromFile(File file, {String? title, bool gate = true}) {
    final suite = BenchmarkSuiteResult.loadFromFile(file);
    return renderSuite(suite, title: title, gate: gate);
  }

  /// Renders a Markdown summary report directly from a stored JSON file path.
  static String renderFromPath(
    String path, {
    String? title,
    bool gate = true,
  }) => renderFromFile(File(path), title: title, gate: gate);

  /// Renders an isolated delta comparison table comparing two stored JSON
  /// files.
  static String renderDeltaFromFiles({
    required File baselineFile,
    required File currentFile,
    String? title,
    String baselineLabel = 'Baseline',
    String currentLabel = 'Current',
    bool gate = true,
  }) {
    final baseline = BenchmarkSuiteResult.loadFromFile(baselineFile);
    final current = BenchmarkSuiteResult.loadFromFile(currentFile);
    return renderDeltaTable(
      baseline: baseline,
      current: current,
      title: title,
      baselineLabel: baselineLabel,
      currentLabel: currentLabel,
      gate: gate,
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

  static _Verdict _computeFiellerVerdict(
    BenchmarkEntry base,
    BenchmarkEntry cur,
  ) {
    final baseUnstable = !base.metrics.isRobustStable;
    final curUnstable = !cur.metrics.isRobustStable;
    if (baseUnstable || curUnstable) {
      return (
        resolved: false,
        ciString: '[N/A]',
        matrixCiString: '[N/A]',
        reasons: [
          if (baseUnstable) 'baseline samples unstable',
          if (curUnstable) 'candidate samples unstable',
        ],
      );
    }
    if (base.rawTrialsNs.length < 2 || cur.rawTrialsNs.length < 2) {
      return (
        resolved: false,
        ciString: '[N/A]',
        matrixCiString: '[N/A]',
        reasons: const ['unbounded CI'],
      );
    }
    final interval = FiellerInterval.compute(
      sampleA: base.rawTrialsNs,
      sampleB: cur.rawTrialsNs,
    );
    if (!interval.isValid ||
        interval.lowerBound.isNaN ||
        interval.upperBound.isNaN) {
      return (
        resolved: false,
        ciString: '[N/A]',
        matrixCiString: '[N/A]',
        reasons: const ['unbounded CI'],
      );
    }
    final low = interval.lowerBound.toStringAsFixed(2);
    final high = interval.upperBound.toStringAsFixed(2);
    return (
      resolved: true,
      ciString: '[$low x, $high x]',
      matrixCiString: '[${low}x – ${high}x]',
      reasons: const [],
    );
  }
}

typedef _Verdict = ({
  bool resolved,
  String ciString,
  String matrixCiString,
  List<String> reasons,
});

final class _DeltaStats() {
  int fasterCount = 0;
  int slowerCount = 0;
  int neutralCount = 0;
  int unresolvedCount = 0;
  double logSum = 0.0;
  int includedInGeoMean = 0;
  double maxBatchDiv = 1.0;
  int divMinBatch = 0;
  int divMaxBatch = 0;
  Set<String> reasons = {};
}
