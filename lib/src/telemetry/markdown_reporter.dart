import 'dart:io';
import 'dart:math' as math;

import '../stats/difference.dart';
import '../stats/fieller.dart';
import '../stats/metrics.dart';
import '../stats/sample_summary.dart';
import 'plausibility.dart';
import 'schema.dart';

/// Scale used when comparing candidate benchmark cells against a baseline.
enum ComparisonScale() {
  /// Multiplicative speedup ratio (`baseline / candidate`, Fieller 95% CI).
  ratio,

  /// Additive delta (`candidate - baseline`, Student/Welch 95% CI).
  difference,

  /// Both additive delta CI and multiplicative Fieller ratio CI.
  both,
}

/// Parses [raw] (`'ratio'`, `'difference'`, or `'both'`), returning `null` if
/// unrecognized (internal to `lib/src/`).
ComparisonScale? tryParseComparisonScale(String raw) =>
    ComparisonScale.values.asNameMap()[raw.trim().toLowerCase()];

/// Generates formatted Markdown tables and performance telemetry reports.
abstract final class MarkdownReporter() {
  /// Renders a full comprehensive Markdown report for a [BenchmarkSuiteResult].
  static String renderSuite(
    BenchmarkSuiteResult suite, {
    String? title,
    bool gate = true,
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
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
      buffer.write(
        _renderLegacyGroupedSuite(
          suite,
          gate: gate,
          threshold: threshold,
          scale: scale,
        ),
      );
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
        _renderMatrixComparisonTable(
          workloadName: workloadName,
          entries: workload.value,
          title: defaultTitle,
          gate: gate,
          threshold: threshold,
          scale: scale,
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
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    final buffer = StringBuffer();
    if (scale != ComparisonScale.difference) {
      final suiteSummary = renderSuiteSummaryTable(suite, gate: gate);
      if (suiteSummary.isNotEmpty) {
        buffer.writeln(suiteSummary);
        buffer.writeln();
      }
    }
    final groupTables = _renderAllGroupComparisonTables(
      suite,
      gate: gate,
      threshold: threshold,
      scale: scale,
    );
    if (groupTables.isNotEmpty) {
      buffer.write(groupTables);
    }
    final summaryTitle = groupTables.isNotEmpty ? 'All Benchmarks' : null;
    buffer.writeln(renderSummaryTable(suite, title: summaryTitle));
    _writeUngroupedDriftNotes(buffer, suite);
    return buffer.toString();
  }

  /// Footnotes drift for cells with no `group` coordinate.
  ///
  /// In the legacy grouped layout these cells appear only in the summary
  /// table, which has no advisory footer of its own.
  static void _writeUngroupedDriftNotes(
    StringBuffer buffer,
    BenchmarkSuiteResult suite,
  ) {
    final notes = <String>[];
    for (final entry in suite.benchmarks) {
      if (entry.coordinates.group != null) continue;
      _recordDrift(notes, entry.name, entry);
    }
    _writeDriftNotes(buffer, notes);
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

  static String _renderMatrixComparisonTable({
    required String workloadName,
    required List<BenchmarkEntry> entries,
    String? title,
    bool gate = true,
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
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

    final baselineLabel = _formatBaselineLabel(
      baseEntry,
      axesList,
      includeNameCol: includeNameCol,
    );
    final headerRow = <String>[
      if (includeNameCol) 'Implementation',
      for (final axis in axesList)
        axis.isEmpty ? 'Variant' : axis[0].toUpperCase() + axis.substring(1),
      'Ops/sec',
      if (hasThroughput) 'Throughput',
      'Mean Latency',
      ..._matrixScaleHeaders(baselineLabel, scale),
    ];
    buffer.writeln('| ${headerRow.join(' | ')} |');

    final dimCount = axesList.length + (includeNameCol ? 1 : 0);
    final metricCount = headerRow.length - dimCount;
    final sepRow = <String>[
      for (var i = 0; i < dimCount; i++) ':---',
      for (var i = 0; i < metricCount; i++) ':---:',
    ];
    buffer.writeln('| ${sepRow.join(' | ')} |');

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
          threshold: threshold,
          scale: scale,
        ),
      );
      _recordDrift(
        stats.driftNotes,
        _formatBaselineLabel(entry, axesList, includeNameCol: includeNameCol),
        entry,
      );
    }
    if (orderedEntries.length > 1) {
      _writeDeltaFooter(buffer, stats, scale: scale);
    } else {
      _writeAdvisoryNotes(buffer, stats, scale: scale);
    }
    return buffer.toString().trimRight();
  }

  static List<String> _matrixScaleHeaders(
    String baselineLabel,
    ComparisonScale scale,
  ) => switch (scale) {
    ComparisonScale.ratio => [
      'vs. Baseline (`$baselineLabel`)',
      'Speedup Ratio',
      '95% Confidence Interval',
      'Status',
    ],
    ComparisonScale.difference => [
      'Delta vs. Baseline (`$baselineLabel`)',
      'Delta (%)',
      '95% CI (Diff)',
      'Status',
    ],
    ComparisonScale.both => [
      'Delta vs. Baseline (`$baselineLabel`)',
      '95% CI (Diff)',
      'Speedup Ratio',
      '95% CI (Fieller)',
      'Status',
    ],
  };

  static List<String> _extractSortedAxes(List<BenchmarkEntry> entries) {
    final axes = <String>{};
    for (final e in entries) {
      axes.addAll(e.coordinates.keys);
    }
    return axes.toList()..sort();
  }

  /// Relative gap between a cell's trial median and its warmup per-op
  /// estimate above which the cell is footnoted as drifted.
  static const _driftThreshold = 0.25;

  /// Appends a drift note for [entry] to [notes] when its trial median moved
  /// more than [_driftThreshold] from the warmup estimate that sized its
  /// batch.
  ///
  /// Skipped when the estimate is absent (older JSON) or non-positive (the
  /// batch came from the fallback calibrator, not from warmup).
  static void _recordDrift(
    List<String> notes,
    String label,
    BenchmarkEntry entry,
  ) {
    final estimate = entry.warmup?['estimated_op_ns'];
    if (estimate is! num || estimate <= 0) return;
    final median = entry.metrics.medianNs;
    final drift = (median - estimate) / estimate;
    if (drift.abs() <= _driftThreshold) return;
    notes.add(
      '`$label`: warmup ${_formatLatency(estimate.toDouble())} → '
      'trials ${_formatLatency(median)} (${_formatPercent(drift * 100)})',
    );
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
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    final curMeanNs = entry.metrics.meanNs;
    final prefixCols = <String>[
      ..._formatDimensionCols(
        entry,
        baselineEntry,
        axes,
        includeNameCol: includeNameCol,
      ),
      _formatOps(entry.metrics.opsPerSec),
      if (hasThroughput) entry.throughput?.formatRate(curMeanNs) ?? '-',
      _formatLatency(curMeanNs),
    ];

    if (identical(entry, baselineEntry)) {
      final baseCols = [...prefixCols, ..._matrixBaselineSuffix(scale)];
      return '| ${baseCols.join(' | ')} |';
    }

    final prevUnresolved = stats.unresolvedCount;
    final suffix = switch (scale) {
      ComparisonScale.ratio => _formatMatrixRatioSuffix(
        entry,
        baselineEntry,
        baseMeanNs,
        gate: gate,
        threshold: threshold,
        stats: stats,
      ),
      ComparisonScale.difference => _formatMatrixDiffSuffix(
        entry,
        baselineEntry,
        baseMeanNs,
        gate: gate,
        threshold: threshold,
        stats: stats,
      ),
      ComparisonScale.both => _formatMatrixBothSuffix(
        entry,
        baselineEntry,
        baseMeanNs,
        gate: gate,
        threshold: threshold,
        stats: stats,
      ),
    };
    if (stats.unresolvedCount == prevUnresolved) {
      final baseLabel = _formatBaselineLabel(
        baselineEntry,
        axes,
        includeNameCol: includeNameCol,
      );
      final curLabel = _formatBaselineLabel(
        entry,
        axes,
        includeNameCol: includeNameCol,
      );
      _recordComparisonVariance(
        stats.varianceNotes,
        base: baselineEntry,
        cur: entry,
        baseLabel: baseLabel,
        curLabel: curLabel,
        pairLabel: curLabel,
        isDelta: false,
      );
    }
    return '| ${[...prefixCols, ...suffix].join(' | ')} |';
  }

  static List<String> _matrixBaselineSuffix(ComparisonScale scale) =>
      switch (scale) {
        ComparisonScale.ratio => const [
          '1.00x (ref)',
          '1.00x',
          '[1.00x – 1.00x]',
          'Ref',
        ],
        ComparisonScale.difference => const [
          '0.0 ns (ref)',
          '0.0%',
          '[0.0 ns – 0.0 ns]',
          'Ref',
        ],
        ComparisonScale.both => const [
          '0.0 ns (ref)',
          '[0.0 ns – 0.0 ns]',
          '1.00x',
          '[1.00x – 1.00x]',
          'Ref',
        ],
      };

  static List<String> _formatMatrixRatioSuffix(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double baseMeanNs, {
    required bool gate,
    required double threshold,
    required _DeltaStats stats,
  }) {
    final curMeanNs = entry.metrics.meanNs;
    final speedup = (curMeanNs > 0.0 && baseMeanNs > 0.0)
        ? (baseMeanNs / curMeanNs)
        : 1.0;
    final verdict = _computeFiellerVerdict(baselineEntry, entry, gate: gate);
    final isUnresolved = gate && !verdict.resolved;
    final movement = _classifyMovement(
      speedup,
      verdict,
      isDelta: false,
      threshold: threshold,
    );
    _tally(stats, verdict.reasons, speedup, movement, unresolved: isUnresolved);

    if (isUnresolved) {
      return [
        'unresolved',
        'unresolved',
        verdict.matrixCiString,
        '❓ Unresolved',
      ];
    }

    final ratioText = speedup >= 1.0
        ? '${speedup.toStringAsFixed(2)}x faster'
        : '${(1.0 / speedup).toStringAsFixed(2)}x slower';
    final diffStr = movement.$2 != 0 ? '**$ratioText**' : ratioText;
    final ratioStr = '${speedup.toStringAsFixed(2)}x';
    final ci = verdict.matrixCiString;
    final ciStr = verdict.resolved && movement.$2 != 0 ? '**$ci**' : ci;
    return [diffStr, ratioStr, ciStr, movement.$1];
  }

  static List<String> _formatMatrixDiffSuffix(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double baseMeanNs, {
    required bool gate,
    required double threshold,
    required _DeltaStats stats,
  }) {
    final curMeanNs = entry.metrics.meanNs;
    final rawDiff = curMeanNs - baseMeanNs;
    final speedup = (curMeanNs > 0.0 && baseMeanNs > 0.0)
        ? (baseMeanNs / curMeanNs)
        : 1.0;
    final diffVerdict = _computeDiffVerdict(baselineEntry, entry, gate: gate);
    final isUnresolved = gate && !diffVerdict.resolved;
    final movement = isUnresolved
        ? ('❓ Unresolved', 0)
        : _classifyDiffMovement(
            diffVerdict,
            rawDiff: rawDiff,
            baseMeanNs: baseMeanNs,
            isDelta: false,
            threshold: threshold,
          );
    _tally(
      stats,
      diffVerdict.reasons,
      speedup,
      movement,
      unresolved: isUnresolved,
    );

    if (isUnresolved) {
      return [
        'unresolved',
        'unresolved',
        diffVerdict.matrixCiString,
        '❓ Unresolved',
      ];
    }

    final diffText = _formatSignedDelta(rawDiff);
    final diffStr = movement.$2 != 0 ? '**$diffText**' : diffText;
    final deltaPct = baseMeanNs > 0.0 ? (rawDiff / baseMeanNs) * 100.0 : 0.0;
    final pctStr = _formatPercent(deltaPct);
    final ci = diffVerdict.matrixCiString;
    final ciStr = diffVerdict.resolved && movement.$2 != 0 ? '**$ci**' : ci;
    return [diffStr, pctStr, ciStr, movement.$1];
  }

  static List<String> _formatMatrixBothSuffix(
    BenchmarkEntry entry,
    BenchmarkEntry baselineEntry,
    double baseMeanNs, {
    required bool gate,
    required double threshold,
    required _DeltaStats stats,
  }) {
    final curMeanNs = entry.metrics.meanNs;
    final speedup = (curMeanNs > 0.0 && baseMeanNs > 0.0)
        ? (baseMeanNs / curMeanNs)
        : 1.0;
    final fieller = _computeFiellerVerdict(baselineEntry, entry, gate: gate);
    final diffVerdict = _computeDiffVerdict(baselineEntry, entry, gate: gate);
    final bothResolved = fieller.resolved && diffVerdict.resolved;
    final isUnresolved = gate && !bothResolved;
    final reasons = <String>[...fieller.reasons, ...diffVerdict.reasons];
    final movement = _classifyMovement(
      speedup,
      fieller,
      isDelta: false,
      threshold: threshold,
    );
    _tally(stats, reasons, speedup, movement, unresolved: isUnresolved);

    if (isUnresolved) {
      return [
        'unresolved',
        diffVerdict.matrixCiString,
        'unresolved',
        fieller.matrixCiString,
        '❓ Unresolved',
      ];
    }

    final rawDiff = curMeanNs - baseMeanNs;
    final deltaPct = baseMeanNs > 0.0 ? (rawDiff / baseMeanNs) * 100.0 : 0.0;
    final diffText =
        '${_formatSignedDelta(rawDiff)} '
        '(${_formatPercent(deltaPct)})';
    final diffStr = movement.$2 != 0 ? '**$diffText**' : diffText;
    final diffCi = movement.$2 != 0
        ? '**${diffVerdict.matrixCiString}**'
        : diffVerdict.matrixCiString;
    final ratioStr = '${speedup.toStringAsFixed(2)}x';
    final fiellerCi = movement.$2 != 0
        ? '**${fieller.matrixCiString}**'
        : fieller.matrixCiString;
    return [diffStr, diffCi, ratioStr, fiellerCi, movement.$1];
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

  static String _renderAllGroupComparisonTables(
    BenchmarkSuiteResult suite, {
    bool gate = true,
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    final buffer = StringBuffer();
    final map = <(String, String), List<BenchmarkEntry>>{};
    for (final entry in suite.benchmarks) {
      final group = entry.coordinates.group;
      if (group != null && group.isNotEmpty) {
        map.putIfAbsent((group, entry.target), () => []).add(entry);
      }
    }

    for (final MapEntry(:key, value: entries) in map.entries) {
      buffer.writeln(
        renderGroupComparisonTable(
          groupName: key.$1,
          target: key.$2,
          entries: entries,
          gate: gate,
          threshold: threshold,
          scale: scale,
        ),
      );
      buffer.writeln();
    }
    return buffer.toString();
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
    final hasMultiProcess = suite.benchmarks.any((b) => b.processes > 1);
    final collidingKeys = _duplicateSummaryKeys(suite.benchmarks);
    final headers = <String>[
      'Benchmark',
      'Target',
      'Ops/sec',
      if (hasThroughput) 'Throughput',
      'Mean Latency',
      'Median',
      'Min',
      'StdDev',
      if (hasMultiProcess) ...['Processes', 'Between-Process Share'],
      'Stability',
    ];
    final alignments = <String>[
      ':---',
      ':---',
      for (var i = 2; i < headers.length; i++) ':---:',
    ];
    buffer.writeln('| ${headers.join(' | ')} |');
    buffer.writeln('| ${alignments.join(' | ')} |');

    for (final b in suite.benchmarks) {
      buffer.writeln(
        _formatSummaryRow(
          b,
          hasThroughput: hasThroughput,
          hasMultiProcess: hasMultiProcess,
          disambiguateName: collidingKeys.contains((b.name, b.target)),
        ),
      );
    }

    return buffer.toString();
  }

  static Set<(String, String)> _duplicateSummaryKeys(
    List<BenchmarkEntry> entries,
  ) {
    final seen = <(String, String)>{};
    final duplicates = <(String, String)>{};
    for (final e in entries) {
      if (!seen.add((e.name, e.target))) duplicates.add((e.name, e.target));
    }
    return duplicates;
  }

  static String _formatSummaryRow(
    BenchmarkEntry b, {
    required bool hasThroughput,
    required bool hasMultiProcess,
    bool disambiguateName = false,
  }) {
    final m = b.metrics;
    final cvPct = (m.cv * 100).toStringAsFixed(1);
    final vc = m.varianceComponents;
    final shareStr = vc != null
        ? '${(vc.betweenProcessShare * 100.0).toStringAsFixed(1)}%'
        : '-';
    final cols = <String>[
      disambiguateName ? _deltaRowLabel(b) : b.name,
      '`${b.target}`',
      _formatOps(m.opsPerSec),
      if (hasThroughput) b.throughput?.formatRate(m.meanNs) ?? '-',
      _formatLatency(m.meanNs),
      _formatLatency(m.medianNs),
      _formatLatency(m.minNs),
      '±${_formatLatency(m.stddevNs)} ($cvPct%)',
      if (hasMultiProcess) ...['${b.processes}', shareStr],
      m.isStable ? '✅ Stable' : '⚠️ Unstable',
    ];
    return '| ${cols.join(' | ')} |';
  }

  /// Pairs cells by composite key (name, target, and every coordinate,
  /// including group), so a benchmark name reused across groups or matrix
  /// cells is never compared against the wrong cell.
  ///
  /// On a duplicate key within one run, the last entry wins, matching
  /// `deepMerge`.
  static _Pairing _pairByKey(
    BenchmarkSuiteResult baseline,
    BenchmarkSuiteResult current,
  ) {
    final baseByKey = {for (final e in baseline.benchmarks) e.key: e};
    final curByKey = {for (final e in current.benchmarks) e.key: e};
    final matched = <(BenchmarkEntry, BenchmarkEntry)>[];
    final onlyCurrent = <BenchmarkEntry>[];
    for (final MapEntry(:key, value: cur) in curByKey.entries) {
      final base = baseByKey[key];
      if (base == null) {
        onlyCurrent.add(cur);
      } else {
        matched.add((base, cur));
      }
    }
    return (
      matched: matched,
      onlyBaseline: [
        for (final MapEntry(:key, :value) in baseByKey.entries)
          if (!curByKey.containsKey(key)) value,
      ],
      onlyCurrent: onlyCurrent,
    );
  }

  static void _writeUnmatchedNotes(
    StringBuffer buffer,
    _Pairing pairing,
    String baselineLabel,
    String currentLabel,
  ) {
    final sides = [
      (baselineLabel, pairing.onlyBaseline),
      (currentLabel, pairing.onlyCurrent),
    ].where((side) => side.$2.isNotEmpty).toList();
    if (sides.isEmpty) return;
    final count = sides.fold(0, (sum, side) => sum + side.$2.length);
    buffer.writeln();
    buffer.writeln(
      '> ℹ️ **Unmatched**: $count benchmark${count == 1 ? '' : 's'} ran in '
      'only one of the two runs and ${count == 1 ? 'is' : 'are'} not '
      'compared.',
    );
    for (final (label, entries) in sides) {
      final names = entries
          .map((e) => '`${_deltaRowLabel(e)}` (`${e.target}`)')
          .join(', ');
      buffer.writeln('> - Only in $label: $names');
    }
  }

  /// The delta table's Benchmark cell: the name, plus its coordinates when
  /// it has any, so rows for one name in different groups stay distinct.
  static String _deltaRowLabel(BenchmarkEntry entry) {
    if (entry.coordinates.isEmpty) return entry.name;
    final coords = entry.coordinates.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final coordStr = coords.map((e) => '${e.key}=${e.value}').join(', ');
    return '${entry.name} ($coordStr)';
  }

  static String _renderDeltaRows(
    List<(BenchmarkEntry, BenchmarkEntry)> matched, {
    required String baselineLabel,
    required String currentLabel,
    bool gate = true,
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    final buffer = StringBuffer();
    final hasThroughput = matched.any(
      (p) => p.$1.throughput != null || p.$2.throughput != null,
    );

    final stats = _DeltaStats();

    _writeDeltaHeader(
      buffer,
      hasThroughput,
      baselineLabel,
      currentLabel,
      scale,
    );

    for (final (base, cur) in matched) {
      final (
        :row,
        :speedup,
        :movement,
        :reasons,
        :unresolved,
      ) = _formatDeltaRow(
        base,
        cur,
        hasThroughput: hasThroughput,
        gate: gate,
        threshold: threshold,
        scale: scale,
      );
      buffer.writeln(row);
      _tally(stats, reasons, speedup, movement, unresolved: unresolved);
      final rowLabel = '${_deltaRowLabel(cur)}, ${cur.target}';
      if (!unresolved) {
        _recordComparisonVariance(
          stats.varianceNotes,
          base: base,
          cur: cur,
          baseLabel: '$rowLabel, $baselineLabel',
          curLabel: '$rowLabel, $currentLabel',
          pairLabel: rowLabel,
          isDelta: true,
        );
      }
      _recordDrift(stats.driftNotes, '$rowLabel, $baselineLabel', base);
      _recordDrift(stats.driftNotes, '$rowLabel, $currentLabel', cur);
    }

    _writeDeltaFooter(buffer, stats, scale: scale);

    return buffer.toString();
  }

  static void _writeDeltaHeader(
    StringBuffer buffer,
    bool hasThroughput,
    String baselineLabel,
    String currentLabel,
    ComparisonScale scale,
  ) {
    final cols = <String>[
      'Benchmark',
      'Target',
      if (hasThroughput) 'Throughput',
      baselineLabel,
      currentLabel,
      'Absolute Delta',
      'Delta (%)',
      if (scale != ComparisonScale.ratio) '95% CI (Diff)',
      if (scale != ComparisonScale.difference) ...[
        'Speedup',
        '95% CI (Fieller)',
      ],
      'Status',
    ];
    final aligns = <String>[
      ':---',
      ':---',
      for (var i = 2; i < cols.length; i++) ':---:',
    ];
    buffer.writeln('| ${cols.join(' | ')} |');
    buffer.writeln('| ${aligns.join(' | ')} |');
  }

  /// Adds one comparison to [stats]: unresolved cells record their reasons;
  /// resolved cells join the geometric mean and the faster/slower/neutral/
  /// inconclusive counts by [movement].
  static void _tally(
    _DeltaStats stats,
    List<String> reasons,
    double speedup,
    (String, int) movement, {
    required bool unresolved,
  }) {
    if (unresolved) {
      stats.unresolvedCount++;
      stats.reasons.addAll(reasons);
      return;
    }
    if (speedup > 0.0 && speedup.isFinite) {
      stats.logSum += math.log(speedup);
      stats.includedInGeoMean++;
    }
    final (status, trend) = movement;
    if (trend > 0) stats.fasterCount++;
    if (trend < 0) stats.slowerCount++;
    if (status == '➖ ⚪ Inconclusive') {
      stats.inconclusiveCount++;
    } else if (trend == 0) {
      stats.neutralCount++;
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
    final ceiling = ThroughputPlausibility.maxPlausibleBytesPerSecond / 1e9;
    final isOne = findings.length == 1;
    buffer.writeln(
      '> 🚩 **Implausible throughput** — '
      '${findings.length} benchmark${isOne ? '' : 's'} '
      'report${isOne ? 's' : ''} faster than '
      '${ceiling.toStringAsFixed(0)} GB/s, above the single-threaded memory '
      'bandwidth of any machine this could run on.',
    );
    for (final finding in findings) {
      buffer.writeln(
        '> - `${finding.benchmarkName}` (`${finding.target}`): '
        '**${finding.gbPerSecond.toStringAsFixed(2)} GB/s** on a '
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
      final volumeRatioStr = finding.volumeRatio >= 100
          ? finding.volumeRatio.toStringAsFixed(0)
          : finding.volumeRatio.toStringAsFixed(1);
      buffer.writeln(
        '> - `${finding.benchmarkName}` (`${finding.target}`): '
        '${_formatBytes(finding.smallBytes)} at '
        '${_formatLatency(finding.smallLatencyNs)} vs '
        '${_formatBytes(finding.largeBytes)} at '
        '${_formatLatency(finding.largeLatencyNs)} — '
        '**${volumeRatioStr}x** the data for '
        '**${finding.latencyRatio.toStringAsFixed(2)}x** the time.',
      );
    }
    buffer.writeln(
      '> Work proportional to the payload cannot be free. Confirm the bytes '
      'are read rather than passed along by reference.',
    );
    buffer.writeln();
  }

  /// Payload sizes use binary prefixes (`KiB`, `MiB`, `GiB`); rates stay
  /// decimal (see `ByteThroughput`).
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

  static void _writeAdvisoryNotes(
    StringBuffer buffer,
    _DeltaStats stats, {
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    _writeDriftNotes(buffer, stats.driftNotes);
    _writeVarianceNotes(buffer, stats.varianceNotes);
    if (stats.reasons.isNotEmpty) {
      final joinedReasons = (stats.reasons.toList()..sort()).join(' and ');
      final what = scale == ComparisonScale.difference ? 'Delta' : 'Speedup';
      buffer.writeln();
      buffer.writeln(
        '> ❓ **Unresolved**: $what omitted due to $joinedReasons.',
      );
    }
  }

  static void _writeVarianceNotes(StringBuffer buffer, Set<String> notes) {
    if (notes.isEmpty) return;
    buffer.writeln();
    buffer.writeln(
      '> ⚠️ **High variance**: sample dispersion exceeded 5% on one or more '
      'resolved comparisons; confidence intervals reflect the wider spread.',
    );
    for (final note in notes) {
      buffer.writeln('> - $note');
    }
  }

  static void _writeDriftNotes(StringBuffer buffer, List<String> notes) {
    if (notes.isEmpty) return;
    final pct = (_driftThreshold * 100).round();
    buffer.writeln();
    buffer.writeln(
      '> ⚠️ **Calibration drift**: the trial median moved more than $pct% '
      'from the warmup estimate that sized the batch.',
    );
    for (final note in notes) {
      buffer.writeln('> - $note');
    }
    buffer.writeln(
      '> The process changed state between calibration and measurement '
      '(for example JIT tier-up or GC pressure); treat these latencies with '
      'caution.',
    );
  }

  static void _writeDeltaFooter(
    StringBuffer buffer,
    _DeltaStats stats, {
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    _writeAdvisoryNotes(buffer, stats, scale: scale);
    buffer.writeln();

    final inconclusiveStr = stats.inconclusiveCount > 0
        ? ' | ⚪ **${stats.inconclusiveCount}** Inconclusive'
        : '';

    if (scale == ComparisonScale.difference) {
      final unresolvedStr = stats.unresolvedCount > 0
          ? ' | ❓ **${stats.unresolvedCount}** Unresolved'
          : '';
      buffer.writeln(
        '> **Summary**: '
        '🚀 **${stats.fasterCount}** Faster | '
        '⚠️ **${stats.slowerCount}** Slower | '
        '➖ **${stats.neutralCount}** Neutral'
        '$inconclusiveStr$unresolvedStr',
      );
      return;
    }

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
        '➖ **${stats.neutralCount}** Neutral'
        '$inconclusiveStr$unresolvedStr',
      );
    } else {
      buffer.writeln(
        '> **Summary**: No resolved measurements to compute Geometric Mean '
        'Speedup | '
        '❓ **${stats.unresolvedCount}** Unresolved (excluded from GeoMean)',
      );
    }
  }

  static ({
    String row,
    double speedup,
    (String, int) movement,
    List<String> reasons,
    bool unresolved,
  })
  _formatDeltaRow(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    bool hasThroughput = false,
    bool gate = true,
    double threshold = 0.0,
    ComparisonScale scale = ComparisonScale.ratio,
  }) {
    final baseMean = base.metrics.meanNs;
    final curMean = cur.metrics.meanNs;
    final diffVal = curMean - baseMean;
    final deltaPct = baseMean > 0.0 ? (diffVal / baseMean) * 100.0 : 0.0;
    final speedup = (curMean > 0.0 && baseMean > 0.0)
        ? (baseMean / curMean)
        : 1.0;

    final eval = _evaluateDeltaVerdicts(
      base,
      cur,
      speedup: speedup,
      gate: gate,
      threshold: threshold,
      scale: scale,
    );
    final diffCells = _formatDeltaDiffCells(
      diffVal: diffVal,
      deltaPct: deltaPct,
      scale: scale,
      unresolved: eval.unresolved,
    );

    final cols = <String>[
      _deltaRowLabel(cur),
      '`${cur.target}`',
      if (hasThroughput) _formatDeltaThroughputCell(base, cur),
      _formatLatency(baseMean),
      _formatLatency(curMean),
      ...diffCells,
      if (eval.diffCi != null) eval.diffCi!,
      if (eval.ratioCi != null) ...[
        eval.unresolved ? 'unresolved' : '${speedup.toStringAsFixed(2)}x',
        eval.ratioCi!,
      ],
      eval.movement.$1,
    ];

    return (
      row: '| ${cols.join(' | ')} |',
      speedup: speedup,
      movement: eval.movement,
      reasons: eval.reasons,
      unresolved: eval.unresolved,
    );
  }

  static List<String> _formatDeltaDiffCells({
    required double diffVal,
    required double deltaPct,
    required ComparisonScale scale,
    required bool unresolved,
  }) {
    if (scale == ComparisonScale.difference && unresolved) {
      return const ['unresolved', 'unresolved'];
    }
    return [_formatSignedDelta(diffVal), _formatPercent(deltaPct)];
  }

  static String _formatDeltaThroughputCell(
    BenchmarkEntry base,
    BenchmarkEntry cur,
  ) {
    final tp = cur.throughput ?? base.throughput;
    return tp?.formatRate(cur.metrics.meanNs) ?? '-';
  }

  static ({
    String? ratioCi,
    String? diffCi,
    bool unresolved,
    List<String> reasons,
    (String, int) movement,
  })
  _evaluateDeltaVerdicts(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    required double speedup,
    required bool gate,
    required double threshold,
    required ComparisonScale scale,
  }) {
    final fieller = scale != ComparisonScale.difference
        ? _computeFiellerVerdict(base, cur, isDelta: true, gate: gate)
        : null;
    final diffVerdict = scale != ComparisonScale.ratio
        ? _computeDiffVerdict(base, cur, isDelta: true, gate: gate)
        : null;
    final resolved =
        (fieller?.resolved ?? true) && (diffVerdict?.resolved ?? true);
    final isUnresolved = gate && !resolved;
    final movement = _selectDeltaMovement(
      isUnresolved: isUnresolved,
      scale: scale,
      speedup: speedup,
      rawDiff: cur.metrics.meanNs - base.metrics.meanNs,
      baseMeanNs: base.metrics.meanNs,
      threshold: threshold,
      fieller: fieller,
      diffVerdict: diffVerdict,
    );
    return (
      ratioCi: fieller?.ciString,
      diffCi: diffVerdict?.ciString,
      unresolved: isUnresolved,
      reasons: <String>[...?fieller?.reasons, ...?diffVerdict?.reasons],
      movement: movement,
    );
  }

  static (String, int) _selectDeltaMovement({
    required bool isUnresolved,
    required ComparisonScale scale,
    required double speedup,
    required double rawDiff,
    required double baseMeanNs,
    required double threshold,
    required _Verdict? fieller,
    required _DiffVerdict? diffVerdict,
  }) {
    if (isUnresolved) return ('❓ Unresolved', 0);
    if (scale == ComparisonScale.difference) {
      return _classifyDiffMovement(
        diffVerdict!,
        rawDiff: rawDiff,
        baseMeanNs: baseMeanNs,
        isDelta: true,
        threshold: threshold,
      );
    }
    return _classifyMovement(
      speedup,
      fieller!,
      isDelta: true,
      threshold: threshold,
    );
  }

  /// Classifies [speedup] and [verdict] against the ±5% default band or an
  /// explicit equivalence [threshold].
  ///
  /// When [threshold] is `0.0` (the default), a resolved 95% CI that contains
  /// 1.00x (`verdict.straddlesOne`) is always Neutral: the data cannot tell
  /// faster from slower, whatever the point estimate says.
  ///
  /// When [threshold] > `0.0`, directional claims (`🚀 Faster` / `⚠️ Regression`)
  /// require the 95% CI to clear `1.0 + threshold` or `1.0 / (1.0 + threshold)`,
  /// and `✅ Equivalent` requires the 90% Fieller CI (Schuirmann TOST at
  /// `alpha = 0.05` per side) to lie completely within
  /// `[1.0 / (1.0 + threshold), 1.0 + threshold]`.
  static (String, int) _classifyMovement(
    double speedup,
    _Verdict verdict, {
    bool isDelta = false,
    double threshold = 0.0,
  }) {
    if (threshold > 0.0) {
      return _classifyThresholdMovement(verdict, threshold, isDelta: isDelta);
    }
    if (verdict.straddlesOne) return ('➖ ⚪ Neutral', 0);
    if (speedup >= 1.05) return (isDelta ? '🚀 Faster' : '🚀 🥇 Peak', 1);
    if (speedup <= 0.95) return (isDelta ? '⚠️ Regression' : '⚠️ 🔴 Slow', -1);
    return ('➖ ⚪ Neutral', 0);
  }

  static (String, int) _classifyThresholdMovement(
    _Verdict verdict,
    double threshold, {
    required bool isDelta,
  }) {
    final upperEq = 1.0 + threshold;
    final lowerEq = 1.0 / upperEq;
    if (verdict.lowerBound >= upperEq) {
      return (isDelta ? '🚀 Faster' : '🚀 🥇 Peak', 1);
    }
    if (verdict.upperBound <= lowerEq) {
      return (isDelta ? '⚠️ Regression' : '⚠️ 🔴 Slow', -1);
    }
    if (verdict.lowerBound90 >= lowerEq && verdict.upperBound90 <= upperEq) {
      return ('✅ Equivalent', 0);
    }
    return ('➖ ⚪ Inconclusive', 0);
  }

  static String _formatSignedDelta(double diff) {
    if (diff.abs() < 1e-9) return '0.0 ns';
    return '${diff > 0 ? '+' : '-'}${_formatLatency(diff.abs())}';
  }

  static String _formatLatency(double ns) => switch (ns) {
    < 1000.0 => '${ns.toStringAsFixed(1)} ns',
    < 1000000.0 => '${(ns / 1000.0).toStringAsFixed(2)} µs',
    < 1000000000.0 => '${(ns / 1000000.0).toStringAsFixed(2)} ms',
    _ => '${(ns / 1000000000.0).toStringAsFixed(2)} s',
  };

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

  static (String, int) _classifyDiffMovement(
    _DiffVerdict verdict, {
    required double rawDiff,
    required double baseMeanNs,
    required bool isDelta,
    required double threshold,
  }) {
    final interval = verdict.interval;
    if (threshold > 0.0) {
      return _classifyThresholdDiffMovement(
        interval,
        margin: threshold * baseMeanNs.abs(),
        isDelta: isDelta,
      );
    }
    if (interval != null && !interval.isSignificant) return ('➖ ⚪ Neutral', 0);
    final estimate = interval?.meanDiff ?? rawDiff;
    final defaultBand = 0.05 * baseMeanNs.abs();
    if (estimate <= -defaultBand) return _fasterMovement(isDelta);
    if (estimate >= defaultBand) return _slowerMovement(isDelta);
    return ('➖ ⚪ Neutral', 0);
  }

  static (String, int) _classifyThresholdDiffMovement(
    DifferenceInterval? interval, {
    required double margin,
    required bool isDelta,
  }) {
    if (interval == null) return ('➖ ⚪ Inconclusive', 0);
    if (interval.upperBound <= -margin) return _fasterMovement(isDelta);
    if (interval.lowerBound >= margin) return _slowerMovement(isDelta);
    if (interval.isEquivalentWithin(margin)) return ('✅ Equivalent', 0);
    return ('➖ ⚪ Inconclusive', 0);
  }

  static (String, int) _fasterMovement(bool isDelta) =>
      (isDelta ? '🚀 Faster' : '🚀 🥇 Peak', 1);

  static (String, int) _slowerMovement(bool isDelta) =>
      (isDelta ? '⚠️ Regression' : '⚠️ 🔴 Slow', -1);

  static bool _shouldUsePairedComparison(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    required bool isDelta,
  }) {
    if (base.pairing != null || cur.pairing != null) {
      return canPairEntries(base, cur);
    }
    if (isDelta) return false;
    return base.processes > 1 &&
        base.processes == cur.processes &&
        _sharedProcessLaunchCoordinates(base, cur);
  }

  static List<String>? _checkCompatibilityAndStability(
    BenchmarkEntry base,
    BenchmarkEntry cur,
  ) {
    final baseUnconverged = base.warmup?['is_stable'] == false;
    final curUnconverged = cur.warmup?['is_stable'] == false;
    if (baseUnconverged || curUnconverged) {
      return [
        if (baseUnconverged) 'baseline warmup did not converge',
        if (curUnconverged) 'candidate warmup did not converge',
      ];
    }
    return null;
  }

  static void _recordComparisonVariance(
    Set<String> notes, {
    required BenchmarkEntry base,
    required BenchmarkEntry cur,
    required String baseLabel,
    required String curLabel,
    required String pairLabel,
    required bool isDelta,
  }) {
    if (_shouldUsePairedComparison(base, cur, isDelta: isDelta)) {
      final pairedCv = _pairedHighVarianceCv(base, cur);
      if (pairedCv != null) {
        final pct = (pairedCv * 100).toStringAsFixed(1);
        notes.add('`$pairLabel`: paired ratio CV $pct%');
      }
      return;
    }
    if (_hasHighSoloVariance(base)) {
      final pct = (base.metrics.cv * 100).toStringAsFixed(1);
      notes.add('`$baseLabel`: CV $pct%');
    }
    if (_hasHighSoloVariance(cur)) {
      final pct = (cur.metrics.cv * 100).toStringAsFixed(1);
      notes.add('`$curLabel`: CV $pct%');
    }
  }

  static double? _pairedHighVarianceCv(
    BenchmarkEntry base,
    BenchmarkEntry cur,
  ) {
    final a = base.effectiveSamplesNs;
    final b = cur.effectiveSamplesNs;
    if (a.length < 2 || a.length != b.length) return null;
    final ratios = <double>[];
    for (var i = 0; i < a.length; i++) {
      if (a[i] <= 0.0 || b[i] <= 0.0) return null;
      ratios.add(b[i] / a[i]);
    }
    final summary = SampleSummary.fromSamples(ratios);
    if (summary.cv <= BenchmarkMetrics.maxCvThreshold ||
        summary.robustCv <= BenchmarkMetrics.maxCvThreshold) {
      return null;
    }
    return summary.cv;
  }

  static bool _hasHighSoloVariance(BenchmarkEntry entry) =>
      !entry.metrics.isStable && entry.warmup?['is_stable'] != false;

  static _DiffVerdict _computeDiffVerdict(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    bool isDelta = false,
    bool gate = true,
  }) {
    final reasons = _checkCompatibilityAndStability(base, cur);
    final interval = _tryComputeDiffInterval(base, cur, isDelta: isDelta);
    if (interval == null) {
      return (
        resolved: false,
        interval: null,
        ciString: '[N/A]',
        matrixCiString: '[N/A]',
        reasons: reasons ?? const ['unbounded CI'],
      );
    }
    final resolved = reasons == null;
    final showCi = resolved || !gate;
    final low = _formatSignedDelta(interval.lowerBound);
    final high = _formatSignedDelta(interval.upperBound);
    return (
      resolved: resolved,
      interval: interval,
      ciString: showCi ? '[$low, $high]' : '[N/A]',
      matrixCiString: showCi ? '[$low – $high]' : '[N/A]',
      reasons: reasons ?? const [],
    );
  }

  static DifferenceInterval? _tryComputeDiffInterval(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    required bool isDelta,
  }) {
    final sampleA = base.effectiveSamplesNs;
    final sampleB = cur.effectiveSamplesNs;
    if (sampleA.length < 2 || sampleB.length < 2) return null;
    final interval = DifferenceInterval.compute(
      baseline: sampleA,
      candidate: sampleB,
      paired: _shouldUsePairedComparison(base, cur, isDelta: isDelta),
    );
    if (!interval.isValid ||
        interval.lowerBound.isNaN ||
        interval.upperBound.isNaN) {
      return null;
    }
    return interval;
  }

  static _Verdict _computeFiellerVerdict(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    bool isDelta = false,
    bool gate = true,
  }) {
    final reasons = _checkCompatibilityAndStability(base, cur);
    final intervals = _tryComputeFiellerIntervals(base, cur, isDelta: isDelta);
    if (intervals == null) {
      return _emptyFiellerVerdict(reasons ?? const ['unbounded CI']);
    }
    final (interval, interval90) = intervals;
    final resolved = reasons == null;
    final showCi = resolved || !gate;
    final low = interval.lowerBound.toStringAsFixed(2);
    final high = interval.upperBound.toStringAsFixed(2);
    return (
      resolved: resolved,
      straddlesOne: interval.lowerBound <= 1.0 && interval.upperBound >= 1.0,
      lowerBound: interval.lowerBound,
      upperBound: interval.upperBound,
      lowerBound90: interval90.lowerBound,
      upperBound90: interval90.upperBound,
      ciString: showCi ? '[$low x, $high x]' : '[N/A]',
      matrixCiString: showCi ? '[${low}x – ${high}x]' : '[N/A]',
      reasons: reasons ?? const [],
    );
  }

  static (FiellerInterval, FiellerInterval)? _tryComputeFiellerIntervals(
    BenchmarkEntry base,
    BenchmarkEntry cur, {
    required bool isDelta,
  }) {
    final sampleA = base.effectiveSamplesNs;
    final sampleB = cur.effectiveSamplesNs;
    if (sampleA.length < 2 || sampleB.length < 2) return null;
    final usePaired = _shouldUsePairedComparison(base, cur, isDelta: isDelta);
    final interval = FiellerInterval.compute(
      sampleA: sampleA,
      sampleB: sampleB,
      paired: usePaired,
    );
    if (!interval.isValid ||
        interval.lowerBound.isNaN ||
        interval.upperBound.isNaN) {
      return null;
    }
    final interval90 = FiellerInterval.compute(
      sampleA: sampleA,
      sampleB: sampleB,
      confidenceLevel: 0.90,
      paired: usePaired,
    );
    return (interval, interval90);
  }

  static _Verdict _emptyFiellerVerdict(List<String> reasons) => (
    resolved: false,
    straddlesOne: false,
    lowerBound: double.nan,
    upperBound: double.nan,
    lowerBound90: double.nan,
    upperBound90: double.nan,
    ciString: '[N/A]',
    matrixCiString: '[N/A]',
    reasons: reasons,
  );

  /// Returns `true` when [a] and [b] executed inside the same `P` shared OS
  /// process launches (same target and identical matrix coordinates except for
  /// intra-file `group`).
  static bool _sharedProcessLaunchCoordinates(
    BenchmarkEntry a,
    BenchmarkEntry b,
  ) {
    if (a.target != b.target) return false;
    for (final entry in a.coordinates.entries) {
      if (entry.key == BenchmarkCoordinates.groupKey) continue;
      if (b.coordinates[entry.key] != entry.value) return false;
    }
    for (final key in b.coordinates.keys) {
      if (key == BenchmarkCoordinates.groupKey) continue;
      if (!a.coordinates.containsKey(key)) return false;
    }
    return true;
  }
}

typedef _Pairing = ({
  List<(BenchmarkEntry, BenchmarkEntry)> matched,
  List<BenchmarkEntry> onlyBaseline,
  List<BenchmarkEntry> onlyCurrent,
});

typedef _Verdict = ({
  bool resolved,

  /// Whether the resolved 95% CI contains 1.00x (no detectable change).
  bool straddlesOne,
  double lowerBound,
  double upperBound,
  double lowerBound90,
  double upperBound90,
  String ciString,
  String matrixCiString,
  List<String> reasons,
});

typedef _DiffVerdict = ({
  bool resolved,
  DifferenceInterval? interval,
  String ciString,
  String matrixCiString,
  List<String> reasons,
});

final class _DeltaStats() {
  int fasterCount = 0;
  int slowerCount = 0;
  int neutralCount = 0;
  int inconclusiveCount = 0;
  int unresolvedCount = 0;
  double logSum = 0.0;
  int includedInGeoMean = 0;
  final List<String> driftNotes = [];
  final Set<String> varianceNotes = {};
  Set<String> reasons = {};
}

/// Renders a top-level Suite Summary table rolling up candidate performance
/// across multiple `coordinates.group` comparison groups using geometric mean
/// speedup (internal to `lib/src/`).
String renderSuiteSummaryTable(
  BenchmarkSuiteResult suite, {
  String? title,
  bool gate = true,
}) {
  final (distinctGroupCount, candidateSpeedups) =
      MarkdownReporter._collectCandidateGroupSpeedups(suite, gate: gate);
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
          MarkdownReporter._formatSuiteSummaryRow(
            key.$1,
            target,
            candidateSpeedups[key]!,
          ),
        );
      }
    }
  }
  return buffer.toString().trimRight();
}

/// Renders a direct variant comparison table for a single `group` (internal to
/// `lib/src/`).
String renderGroupComparisonTable({
  required String groupName,
  required String target,
  required List<BenchmarkEntry> entries,
  String? title,
  bool gate = true,
  double threshold = 0.0,
  ComparisonScale scale = ComparisonScale.ratio,
}) {
  if (entries.isEmpty) return '';
  final strippedEntries = entries.map((e) {
    final newCoords = Map<String, String>.from(e.coordinates);
    newCoords.remove(BenchmarkCoordinates.groupKey);
    return e.copyWith(coordinates: newCoords);
  }).toList();
  final legacyHeading = 'Group: $groupName (`$target`)';
  return MarkdownReporter._renderMatrixComparisonTable(
    workloadName: groupName,
    entries: strippedEntries,
    title: title ?? legacyHeading,
    gate: gate,
    threshold: threshold,
    scale: scale,
  );
}

/// Renders an isolated Before-vs-After delta comparison table comparing
/// [baseline] to [current] (internal to `lib/src/`).
String renderDeltaTable({
  required BenchmarkSuiteResult baseline,
  required BenchmarkSuiteResult current,
  String? title,
  String baselineLabel = 'Baseline',
  String currentLabel = 'Current',
  bool gate = true,
  double threshold = 0.0,
  ComparisonScale scale = ComparisonScale.ratio,
}) {
  final buffer = StringBuffer();
  final heading = title ?? 'Before vs. After Delta Comparison';
  buffer.writeln('### $heading');
  buffer.writeln();

  final pairing = MarkdownReporter._pairByKey(baseline, current);
  if (pairing.matched.isEmpty) {
    buffer.writeln(
      '_No matching benchmarks found between baseline and current results._',
    );
  } else {
    buffer.write(
      MarkdownReporter._renderDeltaRows(
        pairing.matched,
        baselineLabel: baselineLabel,
        currentLabel: currentLabel,
        gate: gate,
        threshold: threshold,
        scale: scale,
      ),
    );
  }
  MarkdownReporter._writeUnmatchedNotes(
    buffer,
    pairing,
    baselineLabel,
    currentLabel,
  );

  return buffer.toString();
}

/// Renders an isolated delta comparison table comparing two stored JSON files
/// (internal to `lib/src/`).
String renderDeltaFromFiles({
  required File baselineFile,
  required File currentFile,
  String? title,
  String baselineLabel = 'Baseline',
  String currentLabel = 'Current',
  bool gate = true,
  double threshold = 0.0,
  ComparisonScale scale = ComparisonScale.ratio,
}) {
  final baseline = loadSuiteFromFile(baselineFile);
  final current = loadSuiteFromFile(currentFile);
  return renderDeltaTable(
    baseline: baseline,
    current: current,
    title: title,
    baselineLabel: baselineLabel,
    currentLabel: currentLabel,
    gate: gate,
    threshold: threshold,
    scale: scale,
  );
}
