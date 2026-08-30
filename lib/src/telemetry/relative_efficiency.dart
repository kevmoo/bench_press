import 'schema.dart';

/// Utilities for assigning status badges to relative efficiency scores.
abstract final class EfficiencyBadge {
  /// Returns the emoji badge prefix associated with [score].
  static String iconForScore(int score) => switch (score) {
    >= 100 => '🥇',
    >= 90 => '🟢',
    >= 70 => '🟡',
    _ => '🔴',
  };

  /// Formats [score] with its full descriptive badge.
  static String format(int score) => switch (score) {
    >= 100 => '🥇 Peak 100',
    >= 90 => '🟢 $score%',
    >= 70 => '🟡 $score%',
    _ => '🔴 $score%',
  };
}

/// Represents the `[Worst / Avg / Best]` relative efficiency triplet for a
/// target across multiple benchmark workloads.
final class EfficiencyTriplet {
  /// The lowest relative efficiency score observed across workloads.
  final int worst;

  /// The arithmetic mean relative efficiency score across workloads.
  final int avg;

  /// The highest relative efficiency score observed across workloads.
  final int best;

  const EfficiencyTriplet({
    required this.worst,
    required this.avg,
    required this.best,
  });

  /// Computes the triplet from a list of individual workload efficiency scores.
  factory EfficiencyTriplet.fromScores(List<int> scores) {
    if (scores.isEmpty) {
      return const EfficiencyTriplet(worst: 0, avg: 0, best: 0);
    }
    var minScore = scores.first;
    var maxScore = scores.first;
    var sum = 0;

    for (final s in scores) {
      if (s < minScore) minScore = s;
      if (s > maxScore) maxScore = s;
      sum += s;
    }

    final avgScore = (sum / scores.length).round();
    return EfficiencyTriplet(worst: minScore, avg: avgScore, best: maxScore);
  }

  /// The status badge icon corresponding to the average score.
  String get badge => EfficiencyBadge.iconForScore(avg);

  /// Formats the triplet as `[Worst% / Avg% / Best%]`.
  String format() => '[$worst% / $avg% / $best%]';

  /// Formats the triplet with its leading status badge icon.
  String formatWithBadge() => '$badge [$worst% / $avg% / $best%]';

  @override
  String toString() => formatWithBadge();
}

/// Relative efficiency breakdown for a single benchmark workload across
/// targets.
final class WorkloadEfficiency {
  /// The benchmark workload identifier.
  final String benchmarkName;

  /// The minimum latency in nanoseconds observed across all evaluated targets.
  final double minLatencyNs;

  /// The target that achieved the peak (lowest) latency on this workload.
  final String peakTarget;

  /// Efficiency scores (0–100) keyed by target name.
  final Map<String, int> targetScores;

  const WorkloadEfficiency({
    required this.benchmarkName,
    required this.minLatencyNs,
    required this.peakTarget,
    required this.targetScores,
  });
}

/// Aggregate efficiency summary for a specific compilation/execution target.
final class TargetEfficiencySummary {
  /// The target name (e.g. 'aot', 'wasm', 'jit', 'js').
  final String target;

  /// The `[Worst / Avg / Best]` relative efficiency triplet across workloads.
  final EfficiencyTriplet triplet;

  /// Number of workloads where this target achieved peak (100%) performance.
  final int peakWins;

  /// Total number of workloads evaluated for this target.
  final int totalWorkloads;

  /// Arithmetic mean operations per second across all workloads.
  final double meanOpsPerSec;

  const TargetEfficiencySummary({
    required this.target,
    required this.triplet,
    required this.peakWins,
    required this.totalWorkloads,
    required this.meanOpsPerSec,
  });
}

/// Multi-target relative efficiency matrix and ranking analyzer.
final class RelativeEfficiencyAnalysis {
  /// Efficiency breakdowns for each individual benchmark workload.
  final List<WorkloadEfficiency> workloadEfficiencies;

  /// Aggregated summary statistics and triplets for each target.
  final List<TargetEfficiencySummary> targetSummaries;

  const RelativeEfficiencyAnalysis({
    required this.workloadEfficiencies,
    required this.targetSummaries,
  });

  /// Analyzes a [BenchmarkSuiteResult] to compute the relative efficiency
  /// matrix.
  factory RelativeEfficiencyAnalysis.fromSuite(
    BenchmarkSuiteResult suite, {
    bool useMinLatency = false,
  }) {
    final workloads = <WorkloadEfficiency>[];
    for (final name in suite.benchmarkNames) {
      final workload = _evaluateWorkload(suite, name, useMinLatency);
      if (workload != null) {
        workloads.add(workload);
      }
    }

    final targetSummaries = _computeTargetSummaries(suite, workloads);
    return RelativeEfficiencyAnalysis(
      workloadEfficiencies: workloads,
      targetSummaries: targetSummaries,
    );
  }

  static WorkloadEfficiency? _evaluateWorkload(
    BenchmarkSuiteResult suite,
    String name,
    bool useMinLatency,
  ) {
    final entries = suite.getEntriesForBenchmark(name);
    if (entries.isEmpty) return null;

    final (bestLatency, peakTarget) = _findPeakLatency(entries, useMinLatency);
    final scores = <String, int>{};

    for (final entry in entries) {
      final latency = useMinLatency
          ? entry.metrics.minNs
          : entry.metrics.meanNs;
      final score = (latency > 0.0 && bestLatency < double.infinity)
          ? ((bestLatency / latency) * 100.0).round().clamp(0, 100)
          : 0;
      scores[entry.target] = score;
    }

    return WorkloadEfficiency(
      benchmarkName: name,
      minLatencyNs: bestLatency,
      peakTarget: peakTarget,
      targetScores: scores,
    );
  }

  static (double, String) _findPeakLatency(
    List<BenchmarkEntry> entries,
    bool useMinLatency,
  ) {
    var best = double.infinity;
    var peak = entries.first.target;
    for (final entry in entries) {
      final latency = useMinLatency
          ? entry.metrics.minNs
          : entry.metrics.meanNs;
      if (latency > 0.0 && latency < best) {
        best = latency;
        peak = entry.target;
      }
    }
    return (best, peak);
  }

  static List<TargetEfficiencySummary> _computeTargetSummaries(
    BenchmarkSuiteResult suite,
    List<WorkloadEfficiency> workloads,
  ) {
    final summaries = <TargetEfficiencySummary>[];
    for (final target in suite.targets) {
      summaries.add(_buildTargetSummary(suite, workloads, target));
    }

    summaries.sort((a, b) {
      final avgComp = b.triplet.avg.compareTo(a.triplet.avg);
      if (avgComp != 0) return avgComp;
      return b.peakWins.compareTo(a.peakWins);
    });

    return summaries;
  }

  static TargetEfficiencySummary _buildTargetSummary(
    BenchmarkSuiteResult suite,
    List<WorkloadEfficiency> workloads,
    String target,
  ) {
    final (scores, peakWins) = _collectTargetScores(workloads, target);
    final meanOps = _calculateMeanOps(suite.getEntriesForTarget(target));
    final triplet = EfficiencyTriplet.fromScores(scores);

    return TargetEfficiencySummary(
      target: target,
      triplet: triplet,
      peakWins: peakWins,
      totalWorkloads: scores.length,
      meanOpsPerSec: meanOps,
    );
  }

  static (List<int>, int) _collectTargetScores(
    List<WorkloadEfficiency> workloads,
    String target,
  ) {
    final scores = <int>[];
    var peakWins = 0;
    for (final w in workloads) {
      final score = w.targetScores[target];
      if (score != null) {
        scores.add(score);
        if (score == 100) peakWins++;
      }
    }
    return (scores, peakWins);
  }

  static double _calculateMeanOps(List<BenchmarkEntry> entries) {
    if (entries.isEmpty) return 0.0;
    var sum = 0.0;
    for (final entry in entries) {
      sum += entry.metrics.opsPerSec;
    }
    return sum / entries.length;
  }
}
