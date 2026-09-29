import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

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

      check<String>(table).not((it) => it.contains('mdformat'));
      check<String>(table).contains(
        '| Benchmark | Target | Ops/sec | Mean Latency | Median | Min | '
        'StdDev | Stability |',
      );
      check<String>(table).contains('`wasm`');
      check<String>(table).contains('json_decode/small');
      check<String>(table).contains('400.0 ns');
      check<String>(table).contains('✅ Stable');
      check<String>(table).contains('json_decode/large');
      check<String>(table).contains('1.50 ms');
      check<String>(table).contains('⚠️ Unstable');
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
      check(deltaReport).not((it) => it.contains('mdformat'));
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
    });

    test('Zero-Token rehydration from JSON file renders complete report', () {
      final baseFile = File(d.path('baseline.json'));
      final curFile = File(d.path('current.json'));

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
    });

    test('renderGroupComparisonTable formats Model 1 variant matrix', () {
      final baseEntry = _createGroupEntryWithSamples(
        name: 'concat',
        target: 'jit',
        meanNs: 1000.0,
        samples: [980.0, 1000.0, 1020.0],
        group: 'String Construction',
        isBaseline: true,
      );

      final fastEntry = _createGroupEntryWithSamples(
        name: 'string_buffer',
        target: 'jit',
        meanNs: 200.0, // 5.0x faster
        samples: [195.0, 200.0, 205.0],
        group: 'String Construction',
        isBaseline: false,
      );

      final slowEntry = _createGroupEntryWithSamples(
        name: 'naive_builder',
        target: 'jit',
        meanNs: 2000.0, // 2.0x slower
        samples: [1950.0, 2000.0, 2050.0],
        group: 'String Construction',
        isBaseline: false,
      );

      final table = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'String Construction',
        target: 'jit',
        entries: [baseEntry, fastEntry, slowEntry],
      );

      check<String>(table).contains('### Group: String Construction (`jit`)');
      check<String>(table).not((it) => it.contains('mdformat'));
      check<String>(table).contains(
        '| Implementation | Ops/sec | Mean Latency | vs. Baseline (`concat`) | '
        'Speedup Ratio | 95% Confidence Interval | Status |',
      );
      check<String>(table).contains('`concat` (Baseline)');
      check<String>(table).contains('1.00x (ref)');
      check<String>(table).contains('Ref');

      check<String>(table).contains('`string_buffer`');
      check<String>(table).contains('**5.00x faster**');
      check<String>(table).contains('🚀 🥇 Peak');

      check<String>(table).contains('`naive_builder`');
      check<String>(table).contains('**2.00x slower**');
      check<String>(table).contains('⚠️ 🔴 Slow');
    });

    test('renderSuite automatically embeds group comparison tables', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      final baseEntry = _createGroupEntryWithSamples(
        name: 'json_std',
        target: 'jit',
        meanNs: 500.0,
        samples: [490.0, 500.0, 510.0],
        group: 'JSON Group',
        isBaseline: true,
      );

      final fastEntry = _createGroupEntryWithSamples(
        name: 'json_custom',
        target: 'jit',
        meanNs: 250.0,
        samples: [245.0, 250.0, 255.0],
        group: 'JSON Group',
        isBaseline: false,
      );

      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry, fastEntry],
      );

      final fullReport = MarkdownReporter.renderSuite(suite);

      check(fullReport).contains('# Benchmark Suite Results');
      check(fullReport).contains('### Group: JSON Group (`jit`)');
      check(fullReport).contains('`json_std` (Baseline)');
      check(fullReport).contains('**2.00x faster**');
      check(fullReport).contains('🚀 🥇 Peak');
      check(fullReport).contains('### All Benchmarks');
    });

    test('renderDeltaTable formats throughput delta when available', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      const baseEntry = BenchmarkEntry(
        name: 'io_task',
        target: 'jit',
        mode: 'sync',
        samples: 3,
        metrics: BenchmarkMetrics(
          meanNs: 1000.0,
          medianNs: 1000.0,
          minNs: 950.0,
          maxNs: 1050.0,
          stddevNs: 10.0,
          cv: 0.01,
          p95Ns: 1020.0,
          p99Ns: 1040.0,
          opsPerSec: 1000000.0,
          isStable: true,
        ),
        rawTrialsNs: [950.0, 1000.0, 1050.0],
        throughput: Throughput.bytes(1024),
      );

      const curEntry = BenchmarkEntry(
        name: 'io_task',
        target: 'jit',
        mode: 'sync',
        samples: 3,
        metrics: BenchmarkMetrics(
          meanNs: 500.0,
          medianNs: 500.0,
          minNs: 480.0,
          maxNs: 520.0,
          stddevNs: 5.0,
          cv: 0.01,
          p95Ns: 510.0,
          p99Ns: 515.0,
          opsPerSec: 2000000.0,
          isStable: true,
        ),
        rawTrialsNs: [480.0, 500.0, 520.0],
        throughput: Throughput.bytes(1024),
      );

      final baseSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry],
      );

      final curSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [curEntry],
      );

      final delta = MarkdownReporter.renderDeltaTable(
        baseline: baseSuite,
        current: curSuite,
      );

      check(delta).contains('| Throughput |');
      check(delta).contains('2.00x');
    });

    test('renderGroupComparisonTable falls back to first variant when none '
        'marked isBaseline', () {
      final v1 = _createGroupEntryWithSamples(
        name: 'v1_first',
        target: 'jit',
        meanNs: 100.0,
        samples: [98.0, 100.0, 102.0],
        group: 'NoMarkedBaseline',
        isBaseline: false,
      );

      final v2 = _createGroupEntryWithSamples(
        name: 'v2_second',
        target: 'jit',
        meanNs: 50.0,
        samples: [49.0, 50.0, 51.0],
        group: 'NoMarkedBaseline',
        isBaseline: false,
      );

      final table = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'NoMarkedBaseline',
        target: 'jit',
        entries: [v1, v2],
      );

      check<String>(table).contains('`v1_first` (Baseline)');
      check<String>(table).contains('`v2_second`');
      check<String>(table).contains('**2.00x faster**');
    });

    test('renderDeltaTable geometric mean handles extreme speedups without '
        'overflow/underflow', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      // Three 1e200 speedup entries whose naive product (1e600) would overflow
      // double to Infinity, verifying that log-sum computes the exact geometric
      // mean (1e200).
      final baseEntry1 = _createEntry('extreme_fast_1', 'jit', 1e200);
      final curEntry1 = _createEntry('extreme_fast_1', 'jit', 1.0);

      final baseEntry2 = _createEntry('extreme_fast_2', 'jit', 1e200);
      final curEntry2 = _createEntry('extreme_fast_2', 'jit', 1.0);

      final baseEntry3 = _createEntry('extreme_fast_3', 'jit', 1e200);
      final curEntry3 = _createEntry('extreme_fast_3', 'jit', 1.0);

      final baseline = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry1, baseEntry2, baseEntry3],
      );

      final current = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [curEntry1, curEntry2, curEntry3],
      );

      final deltaReport = MarkdownReporter.renderDeltaTable(
        baseline: baseline,
        current: current,
      );

      check(deltaReport).contains('Geometric Mean Speedup: **1');
      check(deltaReport).contains('e+200x**');
      check(deltaReport)
          .not((it) => it.contains('Geometric Mean Speedup: **Infinity'));
      check(deltaReport)
          .not((it) => it.contains('Geometric Mean Speedup: **NaN'));
    });

    test(
      'renderSummaryTable formats ops/s for < 10 ops/s and integer thousands',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        final slowEntry1 = _createEntry('slow_workload_1', 'jit', 1e9 / 0.42);
        final slowEntry2 = _createEntry('slow_workload_2', 'jit', 1e9 / 2.15);
        final fastEntry = _createEntry('fast_workload', 'jit', 1e9 / 1234567.0);

        final suite = BenchmarkSuiteResult(
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [slowEntry1, slowEntry2, fastEntry],
        );

        final table = MarkdownReporter.renderSummaryTable(suite);

        check<String>(table).contains('0.42 ops/s');
        check<String>(table).contains('2.15 ops/s');
        check<String>(table).contains('1,234,567 ops/s');
      },
    );

    test('single-group suite omits Suite Summary table', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      final baseEntry = _createGroupEntryWithSamples(
        name: 'baseline_impl',
        target: 'jit',
        meanNs: 100.0,
        samples: [98.0, 100.0, 102.0],
        group: 'Single Group',
        isBaseline: true,
      );

      final candEntry = _createGroupEntryWithSamples(
        name: 'candidate_impl',
        target: 'jit',
        meanNs: 50.0,
        samples: [49.0, 50.0, 51.0],
        group: 'Single Group',
        isBaseline: false,
      );

      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry, candEntry],
      );

      final summaryTable = MarkdownReporter.renderSuiteSummaryTable(suite);
      check<String>(summaryTable).equals('');

      final report = MarkdownReporter.renderSuite(suite);
      check<String>(report).not((it) => it.contains('### Suite Summary'));
    });

    test(
      'multi-group suite renders Suite Summary table at top with geomean, min, '
      'and max speedups',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        // Group 1: baseline 100ns, candidate 50ns (2.00x speedup)
        final g1Base = _createGroupEntryWithSamples(
          name: 'std_json',
          target: 'jit',
          meanNs: 100.0,
          samples: [99.0, 100.0, 101.0],
          group: 'Decode: small',
          isBaseline: true,
        );
        final g1Cand = _createGroupEntryWithSamples(
          name: 'fast_json',
          target: 'jit',
          meanNs: 50.0,
          samples: [49.0, 50.0, 51.0],
          group: 'Decode: small',
          isBaseline: false,
        );

        // Group 2: baseline 800ns, candidate 100ns (8.00x speedup)
        // Geometric mean of 2.00x and 8.00x = sqrt(16.0) = 4.00x
        final g2Base = _createGroupEntryWithSamples(
          name: 'std_json',
          target: 'jit',
          meanNs: 800.0,
          samples: [790.0, 800.0, 810.0],
          group: 'Decode: large',
          isBaseline: true,
        );
        final g2Cand = _createGroupEntryWithSamples(
          name: 'fast_json',
          target: 'jit',
          meanNs: 100.0,
          samples: [99.0, 100.0, 101.0],
          group: 'Decode: large',
          isBaseline: false,
        );

        final suite = BenchmarkSuiteResult(
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [g1Base, g1Cand, g2Base, g2Cand],
        );

        final summaryTable = MarkdownReporter.renderSuiteSummaryTable(suite);
        check<String>(summaryTable).contains('### Suite Summary');
        check<String>(summaryTable).not((it) => it.contains('mdformat'));
        check<String>(summaryTable).contains(
          '| Candidate | Target | Geometric Mean Speedup | Min Speedup | '
          'Max Speedup | Groups |',
        );
        check<String>(
          summaryTable,
        ).contains('| `fast_json` | `jit` | **4.00x** | 2.00x | 8.00x | 2 |');

        final fullReport = MarkdownReporter.renderSuite(suite);
        final summaryIdx = fullReport.indexOf('### Suite Summary');
        final firstGroupIdx = fullReport.indexOf('### Group:');
        check<int>(summaryIdx).isGreaterOrEqual(0);
        check<int>(firstGroupIdx).isGreaterThan(summaryIdx);
      },
    );

    test('Change 1: invalid Fieller interval renders unresolved, excludes from '
        'GeoMean, and gate: false restores ratio', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      // Valid pair (2.00x speedup)
      final validBase = _createEntry('valid_bench', 'jit', 100.0);
      final validCur = _createEntry('valid_bench', 'jit', 50.0);

      // Invalid Fieller pair (fewer than 2 raw trials -> unbounded CI)
      const invalidBase = BenchmarkEntry(
        name: 'unbounded_bench',
        target: 'jit',
        mode: 'sync',
        samples: 1,
        metrics: BenchmarkMetrics(
          meanNs: 139.0,
          medianNs: 139.0,
          minNs: 139.0,
          maxNs: 139.0,
          stddevNs: 0.0,
          cv: 0.0,
          p95Ns: 139.0,
          p99Ns: 139.0,
          opsPerSec: 7194244.0,
          isStable: true,
        ),
        rawTrialsNs: [139.0],
      );
      const invalidCur = BenchmarkEntry(
        name: 'unbounded_bench',
        target: 'jit',
        mode: 'sync',
        samples: 1,
        metrics: BenchmarkMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 100.0,
          maxNs: 100.0,
          stddevNs: 0.0,
          cv: 0.0,
          p95Ns: 100.0,
          p99Ns: 100.0,
          opsPerSec: 10000000.0,
          isStable: true,
        ),
        rawTrialsNs: [100.0],
      );

      final baseSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [validBase, invalidBase],
      );
      final curSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [validCur, invalidCur],
      );

      final gated = MarkdownReporter.renderDeltaTable(
        baseline: baseSuite,
        current: curSuite,
      );
      check(gated).contains(
        '| unbounded_bench | `jit` | 139.0 ns | 100.0 ns | -39.0 ns | '
        '-28.1% | unresolved | [N/A] | ❓ Unresolved |',
      );
      // GeoMean must be 2.00x (from valid_bench only), not contaminated
      // by 1.39x
      check(gated).contains('Geometric Mean Speedup: **2.00x**');
      check(gated).contains('❓ **1** Unresolved (excluded from GeoMean)');
      check(gated)
          .contains('> ❓ **Unresolved**: Speedup omitted due to unbounded CI.');

      final ungated = MarkdownReporter.renderDeltaTable(
        baseline: baseSuite,
        current: curSuite,
        gate: false,
      );
      check(ungated).contains('1.39x');
      check(ungated).not((it) => it.contains('unresolved'));
    });

    test('Change 1: !isStable renders unresolved and all-unresolved table '
        'guards against NaN GeoMean while keeping baseline 1.00x (ref)', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      final baseEntry = _createEntry(
        'unstable_bench',
        'jit',
        100.0,
        isStable: true,
        group: 'G1',
        isBaseline: true,
      );
      final unstableCur = _createEntry(
        'unstable_cand',
        'jit',
        50.0,
        isStable: false,
        group: 'G1',
      );

      // Matrix/Group table check: baseline renders 1.00x (ref), candidate
      // renders unresolved with 'candidate samples unstable'
      final groupTable = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'G1',
        target: 'jit',
        entries: [baseEntry, unstableCur],
      );
      check(groupTable).contains('1.00x (ref)');
      check(groupTable).contains('unresolved');
      check(groupTable).contains('❓ Unresolved');
      check(groupTable).contains(
        '> ❓ **Unresolved**: Speedup omitted due to '
        'candidate samples unstable.',
      );

      // When the baseline is unstable and the candidate is stable, the
      // footnote explicitly attributes the failure to the baseline:
      final unstableBase = _createEntry(
        'unstable_base',
        'jit',
        100.0,
        isStable: false,
        group: 'G1',
        isBaseline: true,
      );
      final stableCur = _createEntry(
        'stable_cand',
        'jit',
        50.0,
        isStable: true,
        group: 'G1',
      );
      final baselineUnstableTable = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'G1',
        target: 'jit',
        entries: [unstableBase, stableCur],
      );
      check(baselineUnstableTable).contains(
        '> ❓ **Unresolved**: Speedup omitted due to '
        'baseline samples unstable.',
      );

      // Delta table where EVERY row is unresolved must not emit NaN
      final baseSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [baseEntry],
      );
      final curSuite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [
          _createEntry(
            'unstable_bench',
            'jit',
            50.0,
            isStable: false,
            group: 'G1',
          ),
        ],
      );

      final delta = MarkdownReporter.renderDeltaTable(
        baseline: baseSuite,
        current: curSuite,
      );
      check(delta).not((it) => it.contains('NaN'));
      check(
        delta,
      ).contains('No resolved measurements to compute Geometric Mean Speedup');
      check(delta).contains('❓ **1** Unresolved (excluded from GeoMean)');
    });

    test('matrix drops the Batch column and footnotes only cells whose trial '
        'median drifted more than 25% from the warmup estimate', () {
      BenchmarkEntry cell(String name, double meanNs, Object? estimate) =>
          _createGroupEntryWithSamples(
            name: name,
            target: 'jit',
            meanNs: meanNs,
            samples: [meanNs - 1, meanNs, meanNs + 1],
            group: 'DriftGroup',
            isBaseline: name == 'v_base',
            calibratedBatchIterations: 7,
            warmup: {'is_stable': true, 'estimated_op_ns': ?estimate},
          );

      final table = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'DriftGroup',
        target: 'jit',
        entries: [
          cell('v_base', 100.0, 100.0),
          cell('v_drift', 50.0, 100.0),
          cell('v_edge', 125.0, 100.0),
          cell('v_missing', 80.0, null),
          cell('v_fallback', 60.0, 0.0),
          cell('v_slow', 130.0, 100.0),
        ],
      );

      check(table).not((it) => it.contains('Batch'));
      check(table).not((it) => it.contains('| 7 |'));
      check(table).contains('| `v_base` (Baseline) | 10,000,000 ops/s |');
      check(table).contains('⚠️ **Calibration drift**');
      check(table)
          .contains('> - `v_drift`: warmup 100.0 ns → trials 50.0 ns (-50.0%)');
      check(table)
          .contains('> - `v_slow`: warmup 100.0 ns → trials 130.0 ns (+30.0%)');
      for (final quiet in ['v_base', 'v_edge', 'v_missing', 'v_fallback']) {
        check(table).not((it) => it.contains('> - `$quiet`'));
      }

      final clean = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'DriftGroup',
        target: 'jit',
        entries: [cell('v_base', 100.0, 100.0), cell('v_edge', 125.0, 100.0)],
      );
      check(clean).not((it) => it.contains('Calibration drift'));
    });

    test('delta table footnotes drift on the baseline and current cells '
        'separately, labeled by run', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );
      BenchmarkSuiteResult suite(double meanNs, double estimate) =>
          BenchmarkSuiteResult(
            timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
            environment: env,
            benchmarks: [
              _createGroupEntryWithSamples(
                name: 'parse',
                target: 'aot',
                meanNs: meanNs,
                samples: [meanNs - 1, meanNs, meanNs + 1],
                group: 'g',
                isBaseline: false,
                warmup: {'estimated_op_ns': estimate},
              ),
            ],
          );

      final delta = MarkdownReporter.renderDeltaTable(
        baseline: suite(100.0, 100.0),
        current: suite(100.0, 200.0),
        baselineLabel: 'Before',
        currentLabel: 'After',
      );
      check(delta).not((it) => it.contains('Batch'));
      check(delta).contains(
        '> - `parse (group=g), aot, After`: warmup 200.0 ns → trials 100.0 ns '
        '(-50.0%)',
      );
      check(delta).not((it) => it.contains('`parse (group=g), aot, Before`'));
    });

    test('legacy grouped suite footnotes drift on ungrouped cells', () {
      BenchmarkEntry cell(String name, String? group, double estimate) =>
          _createGroupEntryWithSamples(
            name: name,
            target: 'jit',
            meanNs: 100.0,
            samples: [99.0, 100.0, 101.0],
            group: group,
            isBaseline: name == 'g_base',
            warmup: {'estimated_op_ns': estimate},
          );
      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: const EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        ),
        benchmarks: [
          cell('g_base', 'g', 100.0),
          cell('g_cand', 'g', 100.0),
          cell('solo', null, 50.0),
        ],
      );

      final report = MarkdownReporter.renderSuite(suite);
      check(report).contains('### All Benchmarks');
      check(report).contains('⚠️ **Calibration drift**');
      check(report)
          .contains('> - `solo`: warmup 50.0 ns → trials 100.0 ns (+100.0%)');
      check(report).not((it) => it.contains('> - `g_'));
    });

    group('delta pairing (#63)', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );
      BenchmarkEntry cell(String name, String group, double meanNs) =>
          _createGroupEntryWithSamples(
            name: name,
            target: 'jit',
            meanNs: meanNs,
            samples: [meanNs - 1, meanNs, meanNs + 1],
            group: group,
            isBaseline: false,
          );
      BenchmarkSuiteResult suite(List<BenchmarkEntry> entries) =>
          BenchmarkSuiteResult(
            timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
            environment: env,
            benchmarks: entries,
          );

      test('pairs a name reused across groups by group, not by first '
          'match, and labels rows with their coordinates', () {
        final delta = MarkdownReporter.renderDeltaTable(
          baseline: suite([
            cell('encode', 'A', 100.0),
            cell('encode', 'B', 1000.0),
          ]),
          current: suite([
            cell('encode', 'A', 50.0),
            cell('encode', 'B', 1000.0),
          ]),
        );
        check(delta).contains(
          '| encode (group=A) | `jit` | 100.0 ns | 50.0 ns | -50.0 ns |',
        );
        check(
          delta,
        ).contains('| encode (group=B) | `jit` | 1.00 µs | 1.00 µs | 0.0 ns |');
        // Before #63, group B paired with group A's baseline (100 ns).
        check(delta).not((it) => it.contains('Regression'));
        check(delta).not((it) => it.contains('Unmatched'));
      });

      test('on duplicate keys within a run, the last entry wins', () {
        final delta = MarkdownReporter.renderDeltaTable(
          baseline: suite([
            cell('encode', 'A', 999.0),
            cell('encode', 'A', 100.0),
          ]),
          current: suite([
            cell('encode', 'A', 777.0),
            cell('encode', 'A', 50.0),
          ]),
        );
        check(delta).contains(
          '| encode (group=A) | `jit` | 100.0 ns | 50.0 ns | -50.0 ns |',
        );
        check('| encode (group=A) |'.allMatches(delta).length).equals(1);
        check(delta).not((it) => it.contains('Unmatched'));
      });

      test('lists cells present in only one run', () {
        final delta = MarkdownReporter.renderDeltaTable(
          baseline: suite([cell('keep', 'A', 100.0), cell('gone', 'A', 100.0)]),
          current: suite([cell('keep', 'A', 50.0), cell('keep', 'B', 50.0)]),
          baselineLabel: 'Before',
          currentLabel: 'After',
        );
        check(delta).contains('| keep (group=A) |');
        check(delta).contains(
          '> ℹ️ **Unmatched**: 2 benchmarks ran in only one of the two runs '
          'and are not compared.\n'
          '> - Only in Before: `gone (group=A)` (`jit`)\n'
          '> - Only in After: `keep (group=B)` (`jit`)',
        );
      });

      test('still lists unmatched cells when nothing pairs', () {
        final delta = MarkdownReporter.renderDeltaTable(
          baseline: suite([cell('encode', 'A', 100.0)]),
          current: suite([cell('encode', 'B', 100.0)]),
        );
        check(delta).contains('_No matching benchmarks found');
        check(delta).contains(
          '> ℹ️ **Unmatched**: 2 benchmarks ran in only one of the two runs',
        );
        check(delta).contains('> - Only in Baseline: `encode (group=A)`');
        check(delta).contains('> - Only in Current: `encode (group=B)`');
      });
    });

    test('gate follows isStable, so a cell that is stable by CV but not '
        'robustly stable still resolves', () {
      final base = _createGroupEntryWithSamples(
        name: 'base',
        target: 'jit',
        meanNs: 100.0,
        samples: [99.0, 100.0, 101.0],
        group: 'G',
        isBaseline: true,
        isRobustStable: false,
      );
      final fast = _createGroupEntryWithSamples(
        name: 'fast',
        target: 'jit',
        meanNs: 50.0,
        samples: [49.0, 50.0, 51.0],
        group: 'G',
        isBaseline: false,
        isRobustStable: false,
      );
      final table = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'G',
        target: 'jit',
        entries: [base, fast],
      );
      check(table).not((it) => it.contains('unresolved'));
      check(table).contains('**2.00x faster**');
      check(table).contains('🚀 🥇 Peak');
    });

    test('a resolved CI that straddles 1.00x is Neutral even past the 5% '
        'band', () {
      // 100 ns vs 95 ns is a 1.05x point estimate, but three noisy trials
      // give a 95% CI that contains 1.00x.
      BenchmarkEntry cell(String name, double meanNs, {bool base = false}) =>
          _createGroupEntryWithSamples(
            name: name,
            target: 'jit',
            meanNs: meanNs,
            samples: [meanNs - 10, meanNs, meanNs + 10],
            group: 'G',
            isBaseline: base,
          );

      final table = MarkdownReporter.renderGroupComparisonTable(
        groupName: 'G',
        target: 'jit',
        entries: [cell('before', 100.0, base: true), cell('after', 95.0)],
      );
      check(table).contains('➖ ⚪ Neutral');
      check(table).not((it) => it.contains('Peak'));
      check(table).not((it) => it.contains('**['));
      check(table).contains('| 1.05x faster |');
      check(table).not((it) => it.contains('**1.05x faster**'));
      check(table).contains('➖ **1** Neutral');

      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );
      BenchmarkSuiteResult suite(double meanNs) => BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [cell('after', meanNs)],
      );
      final delta = MarkdownReporter.renderDeltaTable(
        baseline: suite(100.0),
        current: suite(95.0),
      );
      check(delta).contains('1.05x');
      check(delta).contains('➖ ⚪ Neutral');
      check(delta).not((it) => it.contains('🚀 Faster'));
    });

    test(
      'renderSuite collates grouped benchmarks alongside standalone benchmarks '
      'into a single multi-row Group table with baseline first and '
      'deterministic sorted reasons',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.11.0-edge',
          os: 'linux',
          arch: 'x64',
        );
        final standalone = _createEntry('standalone_bench', 'jit', 100.0);
        final candidateUnstable = _createEntry(
          'candidate_unstable',
          'jit',
          50.0,
          isStable: false,
          group: 'String Construction',
          isBaseline: false,
        );
        final baselineSecond = _createGroupEntryWithSamples(
          name: 'plus_concat',
          target: 'jit',
          meanNs: 200.0,
          samples: [199.0, 200.0, 201.0],
          group: 'String Construction',
          isBaseline: true,
          calibratedBatchIterations: 100,
        );
        final candidateUnbounded = _createGroupEntryWithSamples(
          name: 'candidate_unbounded',
          target: 'jit',
          meanNs: 1.0,
          samples: [-100.0, 1.0, 102.0],
          group: 'String Construction',
          isBaseline: false,
          calibratedBatchIterations: 150,
        );

        final mixedSuite = BenchmarkSuiteResult(
          timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
          environment: env,
          benchmarks: [
            standalone,
            candidateUnstable,
            baselineSecond,
            candidateUnbounded,
          ],
        );

        final report = MarkdownReporter.renderSuite(mixedSuite);
        check(report).contains('### Group: String Construction (`jit`)');
        check(report).not((it) => it.contains('### Benchmark: `plus_concat`'));
        check(report)
            .not((it) => it.contains('### Benchmark: `candidate_unstable`'));

        // Baseline must be ordered as the first data row in the group table
        final baseIdx = report.indexOf('| `plus_concat` (Baseline) |');
        final candIdx = report.indexOf('| `candidate_unstable` |');
        check(baseIdx).isGreaterThan(0);
        check(candIdx).isGreaterThan(baseIdx);

        // Reasons must be sorted alphabetically
        check(report).contains(
          '> ❓ **Unresolved**: Speedup omitted due to '
          'candidate samples unstable and unbounded CI.',
        );
        check(report).contains(
          '> **Summary**: No resolved measurements to compute Geometric Mean '
          'Speedup | ❓ **2** Unresolved (excluded from GeoMean)',
        );
      },
    );

    test('renderSuite with group + multiple coordinate axes across two targets '
        'produces distinct row labels and never spans multiple targets in a '
        'single table', () {
      const env = EnvironmentInfo(
        dartVersion: '3.11.0-edge',
        os: 'linux',
        arch: 'x64',
      );

      BenchmarkEntry makeMultiAxisEntry({
        required String name,
        required String target,
        required String sdk,
        required String tier,
        required double meanNs,
        required bool isBaseline,
      }) =>
          _createGroupEntryWithSamples(
            name: name,
            target: target,
            meanNs: meanNs,
            samples: [meanNs - 1.0, meanNs, meanNs + 1.0],
            group: 'Decode Group',
            isBaseline: isBaseline,
            calibratedBatchIterations: 1000,
          ).copyWith(
            coordinates: {'group': 'Decode Group', 'sdk': sdk, 'tier': tier},
          );

      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.parse('2026-08-30T00:00:00.000Z'),
        environment: env,
        benchmarks: [
          makeMultiAxisEntry(
            name: 'decode_json',
            target: 'jit',
            sdk: 'stock',
            tier: 't1',
            meanNs: 200.0,
            isBaseline: true,
          ),
          makeMultiAxisEntry(
            name: 'decode_codable',
            target: 'jit',
            sdk: 'stock',
            tier: 't1',
            meanNs: 100.0,
            isBaseline: false,
          ),
          makeMultiAxisEntry(
            name: 'decode_json',
            target: 'jit',
            sdk: 'fork',
            tier: 't2',
            meanNs: 180.0,
            isBaseline: false,
          ),
          makeMultiAxisEntry(
            name: 'decode_codable',
            target: 'jit',
            sdk: 'fork',
            tier: 't2',
            meanNs: 80.0,
            isBaseline: false,
          ),
          makeMultiAxisEntry(
            name: 'decode_json',
            target: 'aot',
            sdk: 'stock',
            tier: 't1',
            meanNs: 150.0,
            isBaseline: true,
          ),
          makeMultiAxisEntry(
            name: 'decode_codable',
            target: 'aot',
            sdk: 'stock',
            tier: 't1',
            meanNs: 75.0,
            isBaseline: false,
          ),
        ],
      );

      final report = MarkdownReporter.renderSuite(suite);

      // (b) Separate tables per target — never spanning multiple targets
      check(report).contains('### Group: Decode Group (`jit`)');
      check(report).contains('### Group: Decode Group (`aot`)');

      final jitSectionStart = report.indexOf('### Group: Decode Group (`jit`)');
      final aotSectionStart = report.indexOf('### Group: Decode Group (`aot`)');
      final allBenchesStart = report.indexOf('### All Benchmarks');
      check(jitSectionStart).isGreaterThan(0);
      check(aotSectionStart).isGreaterThan(jitSectionStart);

      final jitTableText = report.substring(jitSectionStart, aotSectionStart);
      final aotTableText = report.substring(aotSectionStart, allBenchesStart);

      // Extract data rows from each table and assert (a) every row has a
      // distinct dimension tuple (Implementation | Sdk | Tier)
      List<String> extractDimensionTuples(String section) {
        final lines = section
            .split('\n')
            .where((l) => l.startsWith('| `'))
            .toList();
        return [
          for (final line in lines)
            line.split('|').sublist(1, 4).map((c) => c.trim()).join(' | '),
        ];
      }

      final jitTuples = extractDimensionTuples(jitTableText);
      check(jitTuples.length).equals(4);
      check(jitTuples.toSet().length).equals(4);
      check(jitTuples).contains('`decode_json` (Baseline) | `stock` | `t1`');
      check(jitTuples).contains('`decode_codable` | `stock` | `t1`');
      check(jitTuples).contains('`decode_json` | `fork` | `t2`');
      check(jitTuples).contains('`decode_codable` | `fork` | `t2`');

      final aotTuples = extractDimensionTuples(aotTableText);
      check(aotTuples.length).equals(2);
      check(aotTuples.toSet().length).equals(2);
      check(aotTuples).contains('`decode_json` (Baseline) | `stock` | `t1`');
      check(aotTuples).contains('`decode_codable` | `stock` | `t1`');
    });
  });
}

BenchmarkEntry _createGroupEntryWithSamples({
  required String name,
  required String target,
  required double meanNs,
  required List<double> samples,
  required String? group,
  required bool isBaseline,
  int? calibratedBatchIterations,
  Map<String, Object?>? warmup,
  bool isRobustStable = true,
}) {
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
    isRobustStable: isRobustStable,
  );
  return BenchmarkEntry(
    name: name,
    target: target,
    mode: 'sync',
    samples: samples.length,
    metrics: metrics,
    rawTrialsNs: samples,
    warmup: warmup,
    calibratedBatchIterations: calibratedBatchIterations,
    coordinates: BenchmarkCoordinates({'group': ?group}),
    isBaseline: isBaseline,
  );
}

BenchmarkEntry _createEntry(
  String name,
  String target,
  double meanNs, {
  bool isStable = true,
  String? group,
  bool isBaseline = false,
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
    isRobustStable: isStable,
  );
  return BenchmarkEntry(
    name: name,
    target: target,
    mode: 'sync',
    samples: 15,
    metrics: metrics,
    rawTrialsNs: [meanNs * 0.95, meanNs, meanNs * 1.05],
    coordinates: BenchmarkCoordinates({'group': ?group}),
    isBaseline: isBaseline,
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
