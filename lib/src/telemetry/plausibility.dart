import '../throughput.dart';
import 'schema.dart';

/// A declared byte throughput too fast to have been produced by code that
/// actually read the payload.
final class const ImplausibleThroughput({
  /// Name of the benchmark that declared the throughput.
  required final String benchmarkName,

  /// Compilation target the benchmark ran against.
  required final String target,

  /// Byte volume the benchmark declared per invocation.
  required final int bytes,

  /// Rate implied by the declared volume and the measured mean latency.
  required final double bytesPerSecond,
}) {
  /// [bytesPerSecond] expressed in decimal GB/s (`1e9` B/s).
  double get gbPerSecond => bytesPerSecond / 1e9;

  /// How far past [ThroughputPlausibility.maxPlausibleBytesPerSecond] this
  /// rate sits.
  double get overCeilingFactor =>
      bytesPerSecond / ThroughputPlausibility.maxPlausibleBytesPerSecond;
}

/// Screens declared byte throughput against a memory-bandwidth ceiling.
///
/// A benchmark that declares `Throughput.bytes` but never reads the payload —
/// storing a reference, or handing the buffer to a sink that keeps it without
/// touching it — is timing loop overhead rather than data movement. The
/// reported rate is then bounded by nothing physical, and the same latency
/// shows up for 13 bytes and for 1 MiB.
///
/// A rate above a machine's memory bandwidth is the cheapest signal that this
/// has happened, so [screenSuite] flags it before the number can be quoted.
///
/// The ceiling only catches payloads large enough that no cache could explain
/// the rate. [screenInvariance] catches the same defect from the other side,
/// by looking for a benchmark whose latency does not move when its payload
/// does, and it works at any size.
abstract final class ThroughputPlausibility() {
  /// Smallest declared volume worth screening.
  ///
  /// Below this a payload sits in L1 or L2, where rates well past DRAM
  /// bandwidth are real rather than suspect. This is the loose end of the
  /// screen: a payload at or just above this size can still be cache-resident,
  /// so raise it if a genuinely tight copy loop trips the ceiling.
  static const int minCheckedBytes = 1024 * 1024;

  /// Highest single-threaded rate treated as physically plausible (`100 GB/s`).
  ///
  /// Deliberately generous: roughly the ceiling of a large server's DRAM
  /// bandwidth, so anything flagged is over the limit of the fastest hardware
  /// the benchmark could plausibly be running on, not merely over this one
  /// machine's.
  static const double maxPlausibleBytesPerSecond = 100e9;

  /// Returns every entry in [suite] whose declared byte throughput exceeds
  /// [maxPlausibleBytesPerSecond], ordered fastest first.
  static List<ImplausibleThroughput> screenSuite(BenchmarkSuiteResult suite) {
    final findings = <ImplausibleThroughput>[];
    for (final benchmark in suite.benchmarks) {
      final finding = screen(
        benchmarkName: benchmark.name,
        target: benchmark.target,
        throughput: benchmark.throughput,
        meanLatencyNs: benchmark.metrics.meanNs,
      );
      if (finding != null) {
        findings.add(finding);
      }
    }
    findings.sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
    return findings;
  }

  /// Returns an [ImplausibleThroughput] when [throughput] declares at least
  /// [minCheckedBytes] and the rate implied by [meanLatencyNs] exceeds
  /// [maxPlausibleBytesPerSecond], or `null` when the rate is believable, not
  /// measured in bytes, or not measurable at all.
  static ImplausibleThroughput? screen({
    required String benchmarkName,
    required String target,
    required Throughput? throughput,
    required double meanLatencyNs,
  }) {
    if (throughput is! ByteThroughput ||
        throughput.bytes < minCheckedBytes ||
        meanLatencyNs.isNaN ||
        meanLatencyNs.isInfinite ||
        meanLatencyNs <= 0.0) {
      return null;
    }
    final bytesPerSecond = throughput.bytes / (meanLatencyNs / 1e9);
    if (bytesPerSecond <= maxPlausibleBytesPerSecond) {
      return null;
    }
    return ImplausibleThroughput(
      benchmarkName: benchmarkName,
      target: target,
      bytes: throughput.bytes,
      bytesPerSecond: bytesPerSecond,
    );
  }

  /// Smallest spread in declared payload size worth reading as a signal.
  ///
  /// Below this the two points are close enough that fixed per-invocation
  /// overhead can genuinely dominate both.
  static const double minVolumeRatio = 8.0;

  /// Smallest latency ratio still treated as "did not move".
  ///
  /// A payload that is never read gives a ratio of ~1.0 by construction, so a
  /// large payload coming out materially *faster* is not invariance — it means
  /// the two points are doing different work. Without this floor a comparison
  /// group holding unrelated arms (different body-handling strategies, say)
  /// reads as a finding.
  static const double minInvariantLatencyRatio = 0.9;

  /// Largest latency ratio still treated as "did not move".
  ///
  /// Payload-proportional work across a [minVolumeRatio] spread should cost far
  /// more than this; anything inside the band
  /// [minInvariantLatencyRatio]–[maxInvariantLatencyRatio] means the payload is
  /// not being touched.
  static const double maxInvariantLatencyRatio = 1.25;

  /// Returns every benchmark in [suite] measured at byte volumes spanning at
  /// least [minVolumeRatio] whose mean latency grew by no more than
  /// [maxInvariantLatencyRatio], ordered by widest volume spread first.
  ///
  /// Entries are matched by name, target, and any non-`group` matrix
  /// coordinates, so the comparison is one benchmark arm across the payload
  /// sizes it was run at — typically the groups of a `BenchmarkMatrix` — never
  /// two unrelated benchmarks or two different SDK/flag arms.
  ///
  /// When each payload size carries its own benchmark name inside one
  /// comparison group — `write_200_fixed_13b` and `write_200_fixed_1mb`, say —
  /// the name-keyed pass cannot pair them. A second, deliberately conservative
  /// pass covers that shape; see `_screenGroupInvariance`. Findings from it set
  /// [InvariantLatency.groupScoped].
  ///
  /// Unlike [screenSuite] this has no size floor, so it catches a payload small
  /// enough to hide under the bandwidth ceiling.
  static List<InvariantLatency> screenInvariance(BenchmarkSuiteResult suite) {
    final byBenchmark = <(String, String, String), List<(int, double)>>{};
    for (final benchmark in suite.benchmarks) {
      final throughput = benchmark.throughput;
      final latencyNs = benchmark.metrics.meanNs;
      if (throughput is! ByteThroughput ||
          throughput.bytes <= 0 ||
          latencyNs.isNaN ||
          latencyNs.isInfinite ||
          latencyNs <= 0.0) {
        continue;
      }
      final key = (
        benchmark.name,
        benchmark.target,
        _nonGroupCoordKey(benchmark.coordinates),
      );
      byBenchmark.putIfAbsent(key, () => []).add((throughput.bytes, latencyNs));
    }

    final findings = <InvariantLatency>[];
    final flagged = <String>{};
    for (final MapEntry(:key, :value) in byBenchmark.entries) {
      if (value.length < 2) {
        continue;
      }
      final points = value.toList()..sort((a, b) => a.$1.compareTo(b.$1));
      final widest = _findWidestInvariantPair(key.$1, key.$2, points);
      if (widest != null) {
        findings.add(widest);
        flagged.add(key.$1);
      }
    }

    findings.addAll(_screenGroupInvariance(suite, alreadyFlagged: flagged));
    findings.sort((a, b) => b.volumeRatio.compareTo(a.volumeRatio));
    return findings;
  }

  /// Catches the same defect when each payload size was given its own benchmark
  /// name inside one comparison group, which [screenInvariance]'s name-keyed
  /// pass cannot pair.
  ///
  /// Arms in a group are usually competing implementations of the same payload,
  /// so a naive pairing could compare a slow small-payload arm against a fast
  /// large-payload one and call the difference invariance. To rule that out,
  /// each payload size is collapsed to its fastest and slowest arm, and the
  /// comparison uses the **slowest** arm at the large size against the
  /// **fastest** arm at the small size — the pairing most likely to show
  /// growth. If even that shows none, no arm in the group scaled with payload.
  static List<InvariantLatency> _screenGroupInvariance(
    BenchmarkSuiteResult suite, {
    required Set<String> alreadyFlagged,
  }) {
    final groups = _collectGroupPoints(suite);
    final findings = <InvariantLatency>[];
    for (final MapEntry(:key, :value) in groups.entries) {
      if (value.byBytes.length < 2) continue;
      // The name-keyed pass already reported this group's problem.
      if (value.names.any(alreadyFlagged.contains)) continue;
      final finding = _findWidestGroupPair(key.$1, key.$2, value.byBytes);
      if (finding != null) findings.add(finding);
    }
    return findings;
  }

  /// Collapses each comparison group to, per declared byte volume, the fastest
  /// and slowest arm measured at that volume.
  static Map<(String, String, String), _GroupPoints> _collectGroupPoints(
    BenchmarkSuiteResult suite,
  ) {
    final groups = <(String, String, String), _GroupPoints>{};
    for (final benchmark in suite.benchmarks) {
      final group = benchmark.coordinates.group;
      final throughput = benchmark.throughput;
      final latencyNs = benchmark.metrics.meanNs;
      if (group == null || group.isEmpty || throughput is! ByteThroughput) {
        continue;
      }
      if (throughput.bytes <= 0 || !_isMeasurable(latencyNs)) continue;
      final key = (
        group,
        benchmark.target,
        _nonGroupCoordKey(benchmark.coordinates),
      );
      groups
          .putIfAbsent(key, _GroupPoints.new)
          .add(benchmark.name, throughput.bytes, latencyNs);
    }
    return groups;
  }

  /// Widest volume spread in [byBytes] whose latency did not move, comparing
  /// the slowest arm at the large size against the fastest at the small size.
  static InvariantLatency? _findWidestGroupPair(
    String group,
    String target,
    Map<int, (double, double)> byBytes,
  ) {
    final volumes = byBytes.keys.toList()..sort();
    InvariantLatency? widest;
    var bestVolumeRatio = 0.0;
    for (var i = 0; i < volumes.length; i++) {
      final smallBytes = volumes[i];
      final smallLatencyNs = byBytes[smallBytes]!.$1;
      for (var j = volumes.length - 1; j > i; j--) {
        final largeBytes = volumes[j];
        final volumeRatio = largeBytes / smallBytes;
        if (volumeRatio < minVolumeRatio || volumeRatio <= bestVolumeRatio) {
          break;
        }
        final largeLatencyNs = byBytes[largeBytes]!.$2;
        if (!_isInvariant(smallLatencyNs, largeLatencyNs)) continue;
        bestVolumeRatio = volumeRatio;
        widest = InvariantLatency(
          benchmarkName: group,
          target: target,
          smallBytes: smallBytes,
          largeBytes: largeBytes,
          smallLatencyNs: smallLatencyNs,
          largeLatencyNs: largeLatencyNs,
          groupScoped: true,
        );
      }
    }
    return widest;
  }

  /// Whether latency held steady between the two points.
  static bool _isInvariant(double smallLatencyNs, double largeLatencyNs) {
    final ratio = largeLatencyNs / smallLatencyNs;
    return ratio >= minInvariantLatencyRatio &&
        ratio <= maxInvariantLatencyRatio;
  }

  static bool _isMeasurable(double latencyNs) =>
      !latencyNs.isNaN && !latencyNs.isInfinite && latencyNs > 0.0;

  static String _nonGroupCoordKey(BenchmarkCoordinates coordinates) {
    if (coordinates.isEmpty) return '';
    final entries = [
      for (final entry in coordinates.entries)
        if (entry.key != BenchmarkCoordinates.groupKey)
          '${entry.key}=${entry.value}',
    ]..sort();
    return entries.join(',');
  }

  static InvariantLatency? _findWidestInvariantPair(
    String benchmarkName,
    String target,
    List<(int, double)> points,
  ) {
    InvariantLatency? widest;
    var bestVolumeRatio = 0.0;
    for (var i = 0; i < points.length; i++) {
      final (smallBytes, smallLatencyNs) = points[i];
      for (var j = points.length - 1; j > i; j--) {
        final (largeBytes, largeLatencyNs) = points[j];
        final volumeRatio = largeBytes / smallBytes;
        if (volumeRatio < minVolumeRatio || volumeRatio <= bestVolumeRatio) {
          break;
        }
        final latencyRatio = largeLatencyNs / smallLatencyNs;
        if (latencyRatio >= minInvariantLatencyRatio &&
            latencyRatio <= maxInvariantLatencyRatio) {
          bestVolumeRatio = volumeRatio;
          widest = InvariantLatency(
            benchmarkName: benchmarkName,
            target: target,
            smallBytes: smallBytes,
            largeBytes: largeBytes,
            smallLatencyNs: smallLatencyNs,
            largeLatencyNs: largeLatencyNs,
          );
          break;
        }
      }
    }
    return widest;
  }
}

/// A benchmark whose measured latency barely moved while its declared payload
/// grew by a wide margin.
final class const InvariantLatency({
  /// Name of the benchmark measured at both volumes.
  required final String benchmarkName,

  /// Compilation target the benchmark ran against.
  required final String target,

  /// Smallest declared volume for this benchmark.
  required final int smallBytes,

  /// Largest declared volume for this benchmark.
  required final int largeBytes,

  /// Mean latency measured at [smallBytes].
  required final double smallLatencyNs,

  /// Mean latency measured at [largeBytes].
  required final double largeLatencyNs,

  /// Whether [benchmarkName] names a comparison group rather than one
  /// benchmark.
  ///
  /// Set when the payload sizes were measured under different benchmark names
  /// inside one group, so the comparison is across the group's arms rather than
  /// one arm across sizes.
  final bool groupScoped = false,
}) {
  /// How many times larger [largeBytes] is than [smallBytes].
  double get volumeRatio => largeBytes / smallBytes;

  /// How many times slower the large payload was than the small one.
  ///
  /// A value near `1.0` alongside a large [volumeRatio] is the finding.
  double get latencyRatio => largeLatencyNs / smallLatencyNs;
}

/// Per-volume fastest and slowest arm within one comparison group.
final class _GroupPoints() {
  final Map<int, (double, double)> byBytes = {};
  final Set<String> names = {};

  void add(String name, int bytes, double latencyNs) {
    names.add(name);
    final existing = byBytes[bytes];
    byBytes[bytes] = existing == null
        ? (latencyNs, latencyNs)
        : (
            latencyNs < existing.$1 ? latencyNs : existing.$1,
            latencyNs > existing.$2 ? latencyNs : existing.$2,
          );
  }
}
