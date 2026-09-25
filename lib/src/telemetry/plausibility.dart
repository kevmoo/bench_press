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
  /// [bytesPerSecond] expressed in GiB/s.
  double get gibPerSecond => bytesPerSecond / (1024 * 1024 * 1024);

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

  /// Highest single-threaded rate treated as physically plausible.
  ///
  /// Deliberately generous: roughly the ceiling of a large server's DRAM
  /// bandwidth, so anything flagged is over the limit of the fastest hardware
  /// the benchmark could plausibly be running on, not merely over this one
  /// machine's.
  static const double maxPlausibleBytesPerSecond = 100 * 1024 * 1024 * 1024;

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

  /// Largest latency ratio still treated as "did not move".
  ///
  /// Payload-proportional work across a [minVolumeRatio] spread should cost far
  /// more than this; anything under it means the payload is not being touched.
  static const double maxInvariantLatencyRatio = 1.25;

  /// Returns every benchmark in [suite] measured at byte volumes spanning at
  /// least [minVolumeRatio] whose mean latency grew by no more than
  /// [maxInvariantLatencyRatio], ordered by widest volume spread first.
  ///
  /// Entries are matched by name and target, so the comparison is one
  /// benchmark across the payload sizes it was run at — typically the groups
  /// of a `BenchmarkMatrix` — never two unrelated benchmarks.
  ///
  /// Unlike [screenSuite] this has no size floor, so it catches a payload small
  /// enough to hide under the bandwidth ceiling.
  static List<InvariantLatency> screenInvariance(BenchmarkSuiteResult suite) {
    final byBenchmark = <(String, String), List<(int, double)>>{};
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
      byBenchmark.putIfAbsent((benchmark.name, benchmark.target), () => []).add(
        (throughput.bytes, latencyNs),
      );
    }

    final findings = <InvariantLatency>[];
    for (final MapEntry(:key, :value) in byBenchmark.entries) {
      if (value.length < 2) {
        continue;
      }
      final points = value.toList()..sort((a, b) => a.$1.compareTo(b.$1));
      final (smallBytes, smallLatencyNs) = points.first;
      final (largeBytes, largeLatencyNs) = points.last;
      if (largeBytes / smallBytes < minVolumeRatio ||
          largeLatencyNs / smallLatencyNs > maxInvariantLatencyRatio) {
        continue;
      }
      findings.add(
        InvariantLatency(
          benchmarkName: key.$1,
          target: key.$2,
          smallBytes: smallBytes,
          largeBytes: largeBytes,
          smallLatencyNs: smallLatencyNs,
          largeLatencyNs: largeLatencyNs,
        ),
      );
    }
    findings.sort((a, b) => b.volumeRatio.compareTo(a.volumeRatio));
    return findings;
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
}) {
  /// How many times larger [largeBytes] is than [smallBytes].
  double get volumeRatio => largeBytes / smallBytes;

  /// How many times slower the large payload was than the small one.
  ///
  /// A value near `1.0` alongside a large [volumeRatio] is the finding.
  double get latencyRatio => largeLatencyNs / smallLatencyNs;
}
