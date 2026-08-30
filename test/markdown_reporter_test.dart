import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('MarkdownReporter', () {
    test('renderSummaryTable formats table with guards and metrics', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      final entry1 = _createEntry(
        'json_decode/small',
        'wasm',
        400.0,
        isStable: true,
      );
      final entry2 = _createEntry(
        'json_decode/large',
        'wasm',
        1500000.0, // 1.5 ms
        isStable: false,
      );

      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [entry1, entry2],
      );

      final table = MarkdownReporter.renderSummaryTable(suite);

      check(table).contains('<!-- mdformat off(prevent table wrapping) -->');
      check(table).contains('<!-- mdformat on -->');
      check(table).contains(
        '| Benchmark | Target | Ops/sec | Mean Latency | Median | Min | '
        'StdDev | Stability |',
      );
      check(table).contains('`wasm`');
      check(table).contains('json_decode/small');
      check(table).contains('400.0 ns');
      check(table).contains('✅ Stable');
      check(table).contains('json_decode/large');
      check(table).contains('1.50 ms');
      check(table).contains('⚠️ Unstable');
    });

    test('renderDeltaTable produces delta report with Fieller intervals', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      // Baseline: 100ns (sample: [98, 100, 102])
      final baseEntry1 = _createEntryWithSamples('parser_fast', 'aot', 100.0, [
        98.0,
        100.0,
        102.0,
      ]);
      // Current: 50ns (sample: [49, 50, 51]) -> 2.0x faster
      final curEntry1 = _createEntryWithSamples('parser_fast', 'aot', 50.0, [
        49.0,
        50.0,
        51.0,
      ]);

      // Baseline 2: 100ns -> Current 2: 120ns (0.83x slower / regression)
      final baseEntry2 = _createEntryWithSamples('parser_slow', 'aot', 100.0, [
        98.0,
        100.0,
        102.0,
      ]);
      final curEntry2 = _createEntryWithSamples('parser_slow', 'aot', 120.0, [
        118.0,
        120.0,
        122.0,
      ]);

      final baseline = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry1, baseEntry2],
      );

      final current = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [curEntry1, curEntry2],
      );

      final deltaReport = MarkdownReporter.renderDeltaTable(
        baseline: baseline,
        current: current,
      );

      check(deltaReport).contains('### Before vs. After Delta Comparison');
      check(deltaReport)
          .contains('<!-- mdformat off(prevent table wrapping) -->');
      check(deltaReport).contains(
        '| Benchmark | Target | Baseline | Current | Absolute Delta | '
        'Delta (%) | Speedup | 95% CI (Fieller) | Status |',
      );
      check(deltaReport).contains('parser_fast');
      check(deltaReport).contains('2.00x');
      check(deltaReport).contains('🚀 Faster');
      check(deltaReport).contains('parser_slow');
      check(deltaReport).contains('0.83x');
      check(deltaReport).contains('⚠️ Regression');
      check(deltaReport).contains('Geometric Mean Speedup');
      check(deltaReport).contains('<!-- mdformat on -->');
    });

    test('Zero-Token rehydration from JSON file renders complete report', () {
      final tempDir = Directory.systemTemp.createTempSync(
        'bench_press_report_test_',
      );
      try {
        final baseFile = File('${tempDir.path}/baseline.json');
        final curFile = File('${tempDir.path}/current.json');

        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        final baseSuite = BenchmarkSuiteResult(
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [_createEntry('crypto_sign', 'aot', 200.0)],
        );
        baseSuite.saveToFile(baseFile);

        final curSuite = BenchmarkSuiteResult(
          timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
          environment: env,
          benchmarks: [_createEntry('crypto_sign', 'aot', 100.0)],
        );
        curSuite.saveToFile(curFile);

        final rehydratedReport = MarkdownReporter.renderFromFile(curFile);
        check(rehydratedReport).contains('# Benchmark Suite Results');
        check(rehydratedReport).contains('crypto_sign');
        check(rehydratedReport).contains('100.0 ns');

        final deltaReport = MarkdownReporter.renderDeltaFromFiles(
          baselineFile: baseFile,
          currentFile: curFile,
        );
        check(deltaReport).contains('2.00x');
        check(deltaReport).contains('🚀 Faster');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

BenchmarkEntry _createEntry(
  String name,
  String target,
  double meanNs, {
  bool isStable = true,
}) {
  final metrics = BenchmarkMetrics(
    meanNs: meanNs,
    medianNs: meanNs,
    minNs: meanNs * 0.95,
    maxNs: meanNs * 1.1,
    stddevNs: meanNs * 0.05,
    cv: 0.05,
    p95Ns: meanNs * 1.05,
    p99Ns: meanNs * 1.08,
    opsPerSec: 1e9 / meanNs,
    isStable: isStable,
  );
  return BenchmarkEntry(
    name: name,
    target: target,
    mode: 'sync',
    samples: 15,
    metrics: metrics,
    rawTrialsNs: [meanNs * 0.95, meanNs, meanNs * 1.05],
  );
}

BenchmarkEntry _createEntryWithSamples(
  String name,
  String target,
  double meanNs,
  List<double> samples,
) {
  final metrics = BenchmarkMetrics(
    meanNs: meanNs,
    medianNs: meanNs,
    minNs: samples.reduce((a, b) => a < b ? a : b),
    maxNs: samples.reduce((a, b) => a > b ? a : b),
    stddevNs: 1.0,
    cv: 0.01,
    p95Ns: meanNs,
    p99Ns: meanNs,
    opsPerSec: 1e9 / meanNs,
    isStable: true,
  );
  return BenchmarkEntry(
    name: name,
    target: target,
    mode: 'sync',
    samples: samples.length,
    metrics: metrics,
    rawTrialsNs: samples,
  );
}
