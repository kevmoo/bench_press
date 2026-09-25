import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

// The real defect this guard exists for: a 1 MiB payload handed to a sink that
// stored the reference without reading it, timed at 1.15 µs — ~849 GiB/s.
const _oneMiB = 1024 * 1024;
const _neverReadLatencyNs = 1150.0;

void main() {
  group('ThroughputPlausibility.screen', () {
    test('flags a byte rate above the ceiling', () {
      final finding = ThroughputPlausibility.screen(
        benchmarkName: 'blackhole_1m',
        target: 'exe',
        throughput: const Throughput.bytes(_oneMiB),
        meanLatencyNs: _neverReadLatencyNs,
      );

      check(finding).isNotNull()
        ..has((f) => f.benchmarkName, 'benchmarkName').equals('blackhole_1m')
        ..has((f) => f.target, 'target').equals('exe')
        ..has((f) => f.bytes, 'bytes').equals(_oneMiB)
        ..has((f) => f.gibPerSecond, 'gibPerSecond').isGreaterThan(800)
        ..has((f) => f.overCeilingFactor, 'overCeilingFactor').isGreaterThan(8);
    });

    test('accepts a rate under the ceiling', () {
      // 1 MiB in 100 µs is ~10 GiB/s: fast, but a real memcpy can do it.
      check(
        ThroughputPlausibility.screen(
          benchmarkName: 'copy_1m',
          target: 'exe',
          throughput: const Throughput.bytes(_oneMiB),
          meanLatencyNs: 100000.0,
        ),
      ).isNull();
    });

    test('ignores payloads small enough to live in cache', () {
      // 13 B at the same latency implies a trivial rate, but even a fast one
      // would be a cache effect rather than a defect.
      check(
        ThroughputPlausibility.screen(
          benchmarkName: 'blackhole_13b',
          target: 'exe',
          throughput: const Throughput.bytes(13),
          meanLatencyNs: 1.0,
        ),
      ).isNull();
    });

    test('ignores element throughput and absent throughput', () {
      check(
        ThroughputPlausibility.screen(
          benchmarkName: 'parse_records',
          target: 'exe',
          throughput: const Throughput.elements(_oneMiB, unit: 'records'),
          meanLatencyNs: _neverReadLatencyNs,
        ),
      ).isNull();
      check(
        ThroughputPlausibility.screen(
          benchmarkName: 'no_declaration',
          target: 'exe',
          throughput: null,
          meanLatencyNs: _neverReadLatencyNs,
        ),
      ).isNull();
    });

    test('ignores unmeasurable latencies', () {
      for (final latency in [0.0, -1.0, double.nan, double.infinity]) {
        check(
          ThroughputPlausibility.screen(
            benchmarkName: 'broken',
            target: 'exe',
            throughput: const Throughput.bytes(_oneMiB),
            meanLatencyNs: latency,
          ),
          because: 'latency $latency is not measurable',
        ).isNull();
      }
    });
  });

  group('ThroughputPlausibility.screenSuite', () {
    test('returns findings fastest first and skips believable entries', () {
      final suite = _suite([
        _entry('slow_but_real', _oneMiB, 100000.0),
        _entry('never_read_1m', _oneMiB, _neverReadLatencyNs),
        _entry('never_read_4m', 4 * _oneMiB, _neverReadLatencyNs),
      ]);

      final findings = ThroughputPlausibility.screenSuite(suite);

      check(findings).length.equals(2);
      check(findings.map((f) => f.benchmarkName))
          .deepEquals(['never_read_4m', 'never_read_1m']);
    });

    test('returns nothing for a suite with no byte throughput', () {
      final suite = _suite([_entry('plain', null, 400.0)]);
      check(ThroughputPlausibility.screenSuite(suite)).isEmpty();
    });
  });

  group('ThroughputPlausibility.screenInvariance', () {
    test('flags one benchmark whose latency held across payload sizes', () {
      // The 256 KiB cell the bandwidth ceiling cannot see: below the size
      // floor, but identical in latency to a payload 20,000x smaller.
      final suite = _suite([
        _entry('blackhole', 13, _neverReadLatencyNs),
        _entry('blackhole', 256 * 1024, _neverReadLatencyNs),
      ]);

      final findings = ThroughputPlausibility.screenInvariance(suite);

      check(findings).length.equals(1);
      check(findings.single)
        ..has((f) => f.benchmarkName, 'benchmarkName').equals('blackhole')
        ..has((f) => f.smallBytes, 'smallBytes').equals(13)
        ..has((f) => f.largeBytes, 'largeBytes').equals(256 * 1024)
        ..has((f) => f.volumeRatio, 'volumeRatio').isGreaterThan(20000)
        ..has((f) => f.latencyRatio, 'latencyRatio').equals(1.0);
    });

    test('accepts latency that grows with the payload', () {
      final suite = _suite([
        _entry('wire', 13, 100.0),
        _entry('wire', _oneMiB, 46000.0),
      ]);

      check(ThroughputPlausibility.screenInvariance(suite)).isEmpty();
    });

    test('ignores a volume spread too narrow to read as a signal', () {
      final suite = _suite([
        _entry('narrow', _oneMiB, 1000.0),
        _entry('narrow', 2 * _oneMiB, 1000.0),
      ]);

      check(ThroughputPlausibility.screenInvariance(suite)).isEmpty();
    });

    test('never compares two different benchmarks', () {
      final suite = _suite([
        _entry('hash_small', 13, _neverReadLatencyNs),
        _entry('parse_large', _oneMiB, _neverReadLatencyNs),
      ]);

      check(ThroughputPlausibility.screenInvariance(suite)).isEmpty();
    });

    test('never compares across targets', () {
      final suite = _suite([
        _entry('same_name', 13, _neverReadLatencyNs),
        _entry('same_name', _oneMiB, _neverReadLatencyNs, target: 'wasm'),
      ]);

      check(ThroughputPlausibility.screenInvariance(suite)).isEmpty();
    });

    test('orders findings by widest volume spread first', () {
      final suite = _suite([
        _entry('narrower', 1024, _neverReadLatencyNs),
        _entry('narrower', 64 * 1024, _neverReadLatencyNs),
        _entry('wider', 13, _neverReadLatencyNs),
        _entry('wider', _oneMiB, _neverReadLatencyNs),
      ]);

      check(
        ThroughputPlausibility.screenInvariance(suite)
            .map((f) => f.benchmarkName),
      ).deepEquals(['wider', 'narrower']);
    });
  });

  group('MarkdownReporter.renderSuite', () {
    test('banners implausible throughput above the tables', () {
      final report = MarkdownReporter.renderSuite(
        _suite([_entry('never_read_1m', _oneMiB, _neverReadLatencyNs)]),
      );

      check(report).contains('🚩 **Implausible throughput**');
      check(report).contains('1 benchmark reports faster than 100 GiB/s');
      check(report).contains('`never_read_1m`');
      check(report).contains('1.0 MiB payload');
      check(report).contains('Confirm the bytes are consumed');
      // The banner has to land before any table, or it is read too late.
      check(report.indexOf('Implausible throughput'))
          .isLessThan(report.indexOf('| Benchmark |'));
    });

    test('pluralizes the banner for multiple findings', () {
      final report = MarkdownReporter.renderSuite(
        _suite([
          _entry('never_read_1m', _oneMiB, _neverReadLatencyNs),
          _entry('never_read_4m', 4 * _oneMiB, _neverReadLatencyNs),
        ]),
      );

      check(report).contains('2 benchmarks report faster than 100 GiB/s');
    });

    test('banners latency that does not track payload size', () {
      final report = MarkdownReporter.renderSuite(
        _suite([
          _entry('blackhole', 13, _neverReadLatencyNs),
          _entry('blackhole', 256 * 1024, _neverReadLatencyNs),
        ]),
      );

      check(report).contains('🚩 **Latency does not track payload size**');
      check(report).contains('1 benchmark costs the same');
      check(report).contains('13 B at 1.15 µs');
      check(report).contains('256.0 KiB at 1.15 µs');
      check(report).contains('**1.00x** the time');
      check(report).contains('Confirm the bytes are read');
      // This suite never trips the bandwidth ceiling — 256 KiB is under the
      // size floor — so invariance is the only thing that catches it.
      check(report).not((it) => it.contains('Implausible throughput'));
    });

    test('stays silent when every rate is believable', () {
      final report = MarkdownReporter.renderSuite(
        _suite([_entry('copy_1m', _oneMiB, 100000.0)]),
      );

      check(report).not((it) => it.contains('Implausible throughput'));
      check(report).not((it) => it.contains('does not track payload size'));
    });
  });
}

BenchmarkSuiteResult _suite(List<BenchmarkEntry> benchmarks) =>
    BenchmarkSuiteResult(
      timestamp: DateTime.parse('2026-09-25T00:00:00.000Z'),
      environment: const EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      ),
      benchmarks: benchmarks,
    );

BenchmarkEntry _entry(
  String name,
  int? bytes,
  double meanNs, {
  String target = 'exe',
}) => BenchmarkEntry(
  name: name,
  target: target,
  mode: 'sync',
  samples: 15,
  metrics: BenchmarkMetrics(
    meanNs: meanNs,
    medianNs: meanNs,
    minNs: meanNs * 0.95,
    maxNs: meanNs * 1.1,
    stddevNs: meanNs * 0.05,
    cv: 0.05,
    p95Ns: meanNs * 1.05,
    p99Ns: meanNs * 1.08,
    opsPerSec: 1e9 / meanNs,
    isStable: true,
  ),
  throughput: bytes == null ? null : Throughput.bytes(bytes),
);
