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
}
