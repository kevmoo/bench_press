import 'dart:io';

import 'package:bench_press/report.dart';
import 'package:bench_press/schedule.dart';
import 'package:bench_press/src/cli/command_runner.dart';
import 'package:bench_press/src/schedule/pairing.dart' show createPairingInfo;
import 'package:bench_press/src/telemetry/markdown_reporter.dart'
    show renderDeltaFromFiles, renderDeltaTable, tryParseComparisonScale;
import 'package:bench_press/src/telemetry/schema.dart'
    show
        InternalBenchmarkEntry,
        InternalBenchmarkSuiteResult,
        canPairEntries,
        createBenchmarkEntry;
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('Schema v1 compatibility and toolkit factories', () {
    test(
      'nanosecond entries without pairing serialize identically to v0.4.2',
      () {
        final entry = BenchmarkEntry.fromSamples(
          name: 'warm_startup',
          samples: const [250, 252, 248],
          scaleToCanonical: 1e6,
          target: 'aot',
          mode: 'async',
        );

        final json = entry.toJson();
        check(json.containsKey('unit')).isFalse;
        check(json.containsKey('pairing')).isFalse;
        check(json.containsKey('warmup')).isFalse;
        check(json.containsKey('calibrated_batch_iterations')).isFalse;
        check(json['samples']).equals(3);

        final parsed = BenchmarkEntry.fromJson(json);
        check(parsed.pairing).isNull;
        check(parsed.metrics.meanNs).equals(250e6);
      },
    );
  });

  group('PairingInfo gating and ComparisonScale reporting', () {
    test('ScheduledRun pairs arms via BenchmarkEntry.fromSamples and renders '
        'overhead', () async {
      // Simulate Konstantin's warm startup benchmark with shared round drift
      // [0, +4, +8, +12 ms]: each arm stays within the 5% CV stability gate
      // while paired CIs cancel the drift (~±1.8 ms vs ~±8.6 ms unpaired).
      const driftMs = [0, 4, 8, 12];
      final run = await RoundScheduler.run<Duration>(
        arms: [
          ScheduleArm(
            'lsp_no_excludes',
            isBaseline: true,
            (ctx) => Duration(milliseconds: 180 + driftMs[ctx.round]),
          ),
          ScheduleArm(
            'lsp_3p_excludes',
            (ctx) => Duration(
              milliseconds:
                  250 + driftMs[ctx.round] + (ctx.round.isEven ? 1 : -1),
            ),
          ),
        ],
        rounds: 4,
      );
      final sequentialRun = await RoundScheduler.run<Duration>(
        arms: [
          ScheduleArm(
            'lsp_no_excludes',
            isBaseline: true,
            (ctx) => Duration(milliseconds: 180 + driftMs[ctx.round]),
          ),
          ScheduleArm(
            'lsp_3p_excludes',
            (ctx) => Duration(
              milliseconds:
                  250 + driftMs[ctx.round] + (ctx.round.isEven ? 1 : -1),
            ),
          ),
        ],
        rounds: 4,
        mode: const ScheduleMode.sequential(),
      );

      BenchmarkSuiteResult buildSuite(ScheduledRun<Duration> scheduled) =>
          BenchmarkSuiteResult(
            timestamp: DateTime.utc(2026, 11, 22),
            environment: const EnvironmentInfo(
              dartVersion: '3.13.0',
              os: 'linux',
              arch: 'x64',
            ),
            benchmarks: [
              for (final arm in scheduled.arms)
                BenchmarkEntry.fromSamples(
                  name: arm.name,
                  samples: [
                    for (final d in arm.samples) d.inMicroseconds * 1000.0,
                  ],
                  mode: 'async',
                  coordinates: const {'group': 'packages=25'},
                  isBaseline: arm.isBaseline,
                  pairing: scheduled.pairing,
                ),
            ],
          );

      final suite = buildSuite(run);
      final sequentialSuite = buildSuite(sequentialRun);
      check(canPairEntries(suite.benchmarks[0], suite.benchmarks[1])).isTrue;
      check(
        canPairEntries(
          sequentialSuite.benchmarks[0],
          sequentialSuite.benchmarks[1],
        ),
      ).isFalse;

      final diffMd = MarkdownReporter.renderSuite(
        suite,
        scale: ComparisonScale.difference,
      );
      final unpairedDiffMd = MarkdownReporter.renderSuite(
        sequentialSuite,
        scale: ComparisonScale.difference,
      );
      check(diffMd).contains('Delta vs. Baseline');
      check(diffMd).contains('**+70.00 ms**');
      check(diffMd).contains('[+68.16 ms – +71.84 ms]');
      check(unpairedDiffMd).contains('[+61.39 ms – +78.61 ms]');
      check(diffMd).contains('⚠️ 🔴 Slow');
      check(diffMd.contains('Geometric Mean Speedup')).isFalse;

      final bothMd = MarkdownReporter.renderSuite(
        suite,
        scale: ComparisonScale.both,
      );
      check(bothMd).contains('95% CI (Diff)');
      check(bothMd).contains('95% CI (Fieller)');
    });

    test(
      'PairingInfo pairs sdk matrix axes within one run and blocks merged runs',
      () {
        final run1Pairing = createPairingInfo(
          groupId: 'run_1',
          schedule: 'abba_baab',
          interleaved: true,
          rounds: 4,
        );
        final run2Pairing = createPairingInfo(
          groupId: 'run_2',
          schedule: 'abba_baab',
          interleaved: true,
          rounds: 4,
        );

        final stock = createBenchmarkEntry(
          name: 'parse',
          target: 'aot',
          mode: 'sync',
          samples: 4,
          metrics: BenchmarkMetrics.fromSamples(const [
            100,
            110,
            120,
            130,
          ], maxCvThreshold: 0.2),
          coordinates: const {'sdk': 'stock'},
          isBaseline: true,
          processes: 4,
          processMeansNs: const [100, 110, 120, 130],
          pairing: run1Pairing,
        );
        final patchedSameRun = createBenchmarkEntry(
          name: 'parse',
          target: 'aot',
          mode: 'sync',
          samples: 4,
          metrics: BenchmarkMetrics.fromSamples(const [
            80,
            90,
            100,
            110,
          ], maxCvThreshold: 0.2),
          coordinates: const {'sdk': 'patched'},
          processes: 4,
          processMeansNs: const [80, 90, 100, 110],
          pairing: run1Pairing,
        );
        final patchedSeparateRun = patchedSameRun.copyWith(
          pairing: run2Pairing,
        );

        // Same interleaved run pairs across different `sdk` coordinates!
        check(canPairEntries(stock, patchedSameRun)).isTrue;
        // Separate merged run with different groupId MUST NOT pair!
        check(canPairEntries(stock, patchedSeparateRun)).isFalse;
      },
    );

    test('canPair handles aligned dropped rounds and deepMerge', () async {
      // 5-round run where round 2 returns null across arms -> 4 aligned
      // samples under pairing.rounds == 5.
      final run = await RoundScheduler.run<int?>(
        arms: [
          ScheduleArm(
            'control',
            isBaseline: true,
            (ctx) => ctx.round == 2 ? null : 100 + ctx.round,
          ),
          ScheduleArm(
            'candidate',
            (ctx) => ctx.round == 2 ? null : 150 + ctx.round,
          ),
        ],
        rounds: 5,
      );
      final aligned = run.extractAlignedSeries((v) => v?.toDouble());
      check(aligned['control']!.length).equals(4);
      final e0 = BenchmarkEntry.fromSamples(
        name: 'control',
        samples: aligned['control']!,
        isBaseline: true,
        coordinates: const {'group': 'aligned_grp'},
        pairing: run.pairing,
      );
      final e1 = BenchmarkEntry.fromSamples(
        name: 'candidate',
        samples: aligned['candidate']!,
        coordinates: const {'group': 'aligned_grp'},
        pairing: run.pairing,
      );
      check(canPairEntries(e0, e1)).isTrue;

      // Single-cell multi-process runs merged via deepMerge carry distinct
      // groupIds and must use unpaired Welch-Fieller in MarkdownReporter.
      const env = EnvironmentInfo(
        dartVersion: '3.13.0',
        os: 'linux',
        arch: 'x64',
      );
      const drift = [100.0, 102.0, 104.0, 106.0];
      const candSamples = [120.0, 122.0, 124.0, 126.0];
      final suite1 = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [
          createBenchmarkEntry(
            name: 'single_a',
            target: 'jit',
            mode: 'sync',
            samples: 4,
            metrics: BenchmarkMetrics.fromSamples(drift),
            coordinates: const {'group': 'G'},
            isBaseline: true,
            processes: 4,
            processMeansNs: drift,
            pairing: createPairingInfo(
              groupId: 'proc_run_1',
              schedule: 'abba_baab',
              interleaved: true,
              rounds: 4,
            ),
          ),
        ],
      );
      final suite2 = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22, 0, 1),
        environment: env,
        benchmarks: [
          createBenchmarkEntry(
            name: 'single_b',
            target: 'jit',
            mode: 'sync',
            samples: 4,
            metrics: BenchmarkMetrics.fromSamples(candSamples),
            coordinates: const {'group': 'G'},
            processes: 4,
            processMeansNs: candSamples,
            pairing: createPairingInfo(
              groupId: 'proc_run_2',
              schedule: 'abba_baab',
              interleaved: true,
              rounds: 4,
            ),
          ),
        ],
      );
      final merged = suite1.deepMerge(suite2);
      check(canPairEntries(merged.benchmarks[0], merged.benchmarks[1])).isFalse;
      final mergedMd = MarkdownReporter.renderSuite(
        merged,
        scale: ComparisonScale.difference,
      );
      // If falsely paired, diff is constant +20.0 ns -> [+20.0 ns – +20.0 ns].
      // Unpaired Welch-Satterthwaite includes the drift variance (±4.4 ns).
      check(mergedMd.contains('[+20.0 ns – +20.0 ns]')).isFalse;
    });

    test(
      'ComparisonScale.difference honors gate: true vs gate: false on rows',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.13.0',
          os: 'linux',
          arch: 'x64',
        );
        const grp = {'group': 'G'};
        final baseSingle = BenchmarkEntry.fromSamples(
          name: 'single_shot',
          samples: const [200.0],
          coordinates: grp,
          isBaseline: true,
        );
        final curSingle = BenchmarkEntry.fromSamples(
          name: 'single_shot',
          samples: const [120.0],
          coordinates: grp,
        );
        final baseNoisy = BenchmarkEntry.fromSamples(
          name: 'noisy_shot',
          samples: const [200.0, 202.0, 198.0],
          coordinates: grp,
          isBaseline: true,
        );
        final curNoisy = BenchmarkEntry.fromSamples(
          name: 'noisy_shot',
          // CV = 10% (> 5% default maxCvThreshold -> !isStable), clearly faster
          samples: const [90.0, 100.0, 110.0],
          coordinates: grp,
        );
        final baseUnconverged = BenchmarkEntry.fromSamples(
          name: 'unconverged_shot',
          samples: const [200.0, 202.0, 198.0],
          coordinates: grp,
          isBaseline: true,
        );
        final curUnconverged = createBenchmarkEntry(
          name: 'unconverged_shot',
          target: 'aot',
          mode: 'sync',
          samples: 3,
          metrics: BenchmarkMetrics.fromSamples(const [
            99.0,
            100.0,
            101.0,
          ], isStable: false),
          rawTrialsNs: const [99.0, 100.0, 101.0],
          warmup: const {'is_stable': false},
          coordinates: grp,
        );

        final baseSuite = BenchmarkSuiteResult(
          timestamp: DateTime.utc(2026, 11, 22),
          environment: env,
          benchmarks: [baseSingle, baseNoisy, baseUnconverged],
        );
        final curSuite = BenchmarkSuiteResult(
          timestamp: DateTime.utc(2026, 11, 22, 1),
          environment: env,
          benchmarks: [curSingle, curNoisy, curUnconverged],
        );

        final gatedDelta = renderDeltaTable(
          baseline: baseSuite,
          current: curSuite,
          scale: ComparisonScale.difference,
        );
        check(gatedDelta).contains(
          '| single_shot (group=G) | `aot` | 200.0 ns | 120.0 ns | '
          'unresolved | unresolved | [N/A] | ❓ Unresolved |',
        );
        check(gatedDelta).contains(
          '| unconverged_shot (group=G) | `aot` | 200.0 ns | 100.0 ns | '
          'unresolved | unresolved | [N/A] | ❓ Unresolved |',
        );
        // High-CV row resolves via its 95% CI and emits a High variance note
        check(gatedDelta).contains('-100.0 ns | -50.0% | [');
        check(gatedDelta).contains('🚀 **1** Faster');
        check(gatedDelta).contains('❓ **2** Unresolved');
        check(gatedDelta)
            .contains('> ⚠️ **High variance**: sample dispersion exceeded 5%');
        check(gatedDelta)
            .contains('`noisy_shot (group=G), aot, Current`: CV 10.0%');
        check(gatedDelta).contains(
          'Delta omitted due to candidate warmup did not converge and '
          'unbounded CI.',
        );

        final ungatedDelta = renderDeltaTable(
          baseline: baseSuite,
          current: curSuite,
          scale: ComparisonScale.difference,
          gate: false,
        );
        check(ungatedDelta.contains('unresolved')).isFalse;
        check(ungatedDelta.contains('❓ Unresolved')).isFalse;
        check(ungatedDelta).contains('-80.0 ns | -40.0% | [N/A] | 🚀 Faster');
        check(ungatedDelta).contains('-100.0 ns | -50.0% | [');
        check(ungatedDelta).contains('🚀 **3** Faster');

        // Matrix/group suite table with unconverged warmup honors gate: false.
        final groupSuite = BenchmarkSuiteResult(
          timestamp: DateTime.utc(2026, 11, 22),
          environment: env,
          benchmarks: [baseUnconverged, curUnconverged],
        );
        final gatedGroup = MarkdownReporter.renderSuite(
          groupSuite,
          scale: ComparisonScale.difference,
        );
        check(gatedGroup).contains('❓ Unresolved');
        final ungatedGroup = MarkdownReporter.renderSuite(
          groupSuite,
          scale: ComparisonScale.difference,
          gate: false,
        );
        check(ungatedGroup.contains('❓ Unresolved')).isFalse;
        check(ungatedGroup).contains('🚀 🥇 Peak');
      },
    );
  });

  group('CLI --scale and reporter edge cases', () {
    test('CLI report and diff accept --scale', () async {
      final baseFile = File(d.path('base.json'));
      final curFile = File(d.path('cur.json'));
      final reportOut = File(d.path('report.md'));
      final diffOut = File(d.path('diff.md'));

      const env = EnvironmentInfo(
        dartVersion: '3.13.0',
        os: 'linux',
        arch: 'x64',
      );
      BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'WarmAnalysis',
            samples: const [500, 502, 498],
            scaleToCanonical: 1e6,
            mode: 'async',
          ),
        ],
      ).saveToFile(baseFile);

      BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22, 1),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'WarmAnalysis',
            samples: const [300, 301, 299],
            scaleToCanonical: 1e6,
            mode: 'async',
          ),
        ],
      ).saveToFile(curFile);

      final runner = BenchPressCommandRunner();
      check(
        await runner.run([
          'report',
          curFile.path,
          '--scale',
          'difference',
          '-o',
          reportOut.path,
        ]),
      ).equals(0);
      check(reportOut.readAsStringSync()).contains('WarmAnalysis');

      check(
        await runner.run([
          'diff',
          baseFile.path,
          curFile.path,
          '--scale',
          'difference',
          '-o',
          diffOut.path,
        ]),
      ).equals(0);
      final diffMd = diffOut.readAsStringSync();
      check(diffMd).contains('95% CI (Diff)');
      check(diffMd).contains('-200.00 ms');
      check(diffMd).contains('🚀 Faster');
    });

    test('ungated Fieller suppresses false Peak/Faster when unstable CI straddles 1.00x', () {
      const env = EnvironmentInfo(
        dartVersion: '3.13.0',
        os: 'linux',
        arch: 'x64',
      );
      const grp = {'group': 'G'};
      // Mean 108 vs 100 -> 1.08x (> 1.05x default band), but CV ~ 25% so
      // 95% Fieller CI straddles 1.00x.
      final noisyBase = BenchmarkEntry.fromSamples(
        name: 'base_arm',
        samples: const [80.0, 108.0, 136.0],
        coordinates: grp,
        isBaseline: true,
      );
      final noisyCand = BenchmarkEntry.fromSamples(
        name: 'cand_arm',
        samples: const [80.0, 100.0, 120.0],
        coordinates: grp,
      );
      final suite = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [noisyBase, noisyCand],
      );

      for (final scale in [ComparisonScale.ratio, ComparisonScale.both]) {
        final ungatedSuite = MarkdownReporter.renderSuite(
          suite,
          scale: scale,
          gate: false,
        );
        check(ungatedSuite.contains('🚀 🥇 Peak')).isFalse;
        check(ungatedSuite.contains('[N/A]')).isFalse;
        check(ungatedSuite).contains('➖ ⚪ Neutral');

        final ungatedDelta = renderDeltaTable(
          baseline: BenchmarkSuiteResult(
            timestamp: DateTime.utc(2026, 11, 22),
            environment: env,
            benchmarks: [noisyBase],
          ),
          current: BenchmarkSuiteResult(
            timestamp: DateTime.utc(2026, 11, 22, 1),
            environment: env,
            benchmarks: [
              BenchmarkEntry.fromSamples(
                name: 'base_arm',
                samples: const [80.0, 100.0, 120.0],
                coordinates: grp,
              ),
            ],
          ),
          scale: scale,
          gate: false,
        );
        check(ungatedDelta.contains('🚀 Faster')).isFalse;
        check(ungatedDelta.contains('[N/A]')).isFalse;
        check(ungatedDelta).contains('➖ ⚪ Neutral');
      }
    });

    test(
      'preserves group appearance order and disambiguates duplicate arm names',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.13.0',
          os: 'linux',
          arch: 'x64',
        );
        final entries = <BenchmarkEntry>[
          for (final pkgCount in [25, 50, 100]) ...[
            BenchmarkEntry.fromSamples(
              name: 'lsp_no_excludes',
              samples: [pkgCount * 4, pkgCount * 4 + 1],
              scaleToCanonical: 1e6,
              mode: 'async',
              coordinates: {'group': 'packages=$pkgCount'},
              isBaseline: true,
            ),
            BenchmarkEntry.fromSamples(
              name: 'lsp_3p_excludes',
              samples: [pkgCount * 5, pkgCount * 5 + 1],
              scaleToCanonical: 1e6,
              mode: 'async',
              coordinates: {'group': 'packages=$pkgCount'},
            ),
          ],
          BenchmarkEntry.fromSamples(
            name: 'UniqueBench',
            samples: const [10, 10],
            scaleToCanonical: 1e6,
            mode: 'async',
          ),
        ];
        final suite = BenchmarkSuiteResult(
          timestamp: DateTime.utc(2026, 11, 22),
          environment: env,
          benchmarks: entries,
        );

        // Group tables preserve appearance order (25 -> 50 -> 100).
        final groupsMd = MarkdownReporter.renderSuite(suite);
        final idx25 = groupsMd.indexOf('### Group: packages=25');
        final idx50 = groupsMd.indexOf('### Group: packages=50');
        final idx100 = groupsMd.indexOf('### Group: packages=100');
        check(idx25).isGreaterOrEqual(0);
        check(idx25).isLessThan(idx50);
        check(idx50).isLessThan(idx100);

        // Summary table disambiguates colliding names while keeping UniqueBench
        // bare.
        final summaryMd = MarkdownReporter.renderSummaryTable(suite);
        check(summaryMd).contains('| lsp_no_excludes (group=packages=25) |');
        check(summaryMd).contains('| lsp_no_excludes (group=packages=100) |');
        check(summaryMd).contains('| UniqueBench |');
      },
    );

    test('supports threshold TOST classification under '
        'ComparisonScale.difference, unresolved ComparisonScale.both, '
        'multi-target headers, and GiB banners', () {
      check(tryParseComparisonScale('ratio')).equals(ComparisonScale.ratio);
      check(tryParseComparisonScale('difference'))
          .equals(ComparisonScale.difference);
      check(tryParseComparisonScale(' BOTH ')).equals(ComparisonScale.both);
      check(tryParseComparisonScale('unknown')).isNull;

      const env = EnvironmentInfo(
        dartVersion: '3.13.0',
        os: 'linux',
        arch: 'x64',
      );
      const grp = {'group': 'ThreshGrp'};
      final base = BenchmarkEntry.fromSamples(
        name: 'base',
        samples: const [100.0, 100.2, 99.8, 100.0],
        coordinates: grp,
        isBaseline: true,
      );
      final faster = BenchmarkEntry.fromSamples(
        name: 'faster',
        samples: const [80.0, 80.2, 79.8, 80.0],
        coordinates: grp,
      );
      final slower = BenchmarkEntry.fromSamples(
        name: 'slower',
        samples: const [120.0, 120.2, 119.8, 120.0],
        coordinates: grp,
      );
      final equiv = BenchmarkEntry.fromSamples(
        name: 'equiv',
        samples: const [100.5, 100.7, 100.3, 100.5],
        coordinates: grp,
      );
      final inconc = BenchmarkEntry.fromSamples(
        name: 'inconc',
        samples: const [104.0, 106.0, 102.0, 108.0],
        coordinates: grp,
      );
      final singleSample = BenchmarkEntry.fromSamples(
        name: 'single',
        samples: const [90.0],
        coordinates: grp,
      );

      final threshSuite = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [base, faster, slower, equiv, inconc, singleSample],
      );
      final suiteDiffMd = MarkdownReporter.renderSuite(
        threshSuite,
        scale: ComparisonScale.difference,
        threshold: 0.05,
        gate: false,
      );
      check(suiteDiffMd)
        ..contains('🚀 🥇 Peak')
        ..contains('⚠️ 🔴 Slow')
        ..contains('✅ Equivalent')
        ..contains('➖ ⚪ Inconclusive');

      // Unresolved row under ComparisonScale.both emits unresolved cells.
      final gatedBothMd = MarkdownReporter.renderSuite(
        BenchmarkSuiteResult(
          timestamp: DateTime.utc(2026, 11, 22),
          environment: env,
          benchmarks: [base, singleSample],
        ),
        scale: ComparisonScale.both,
      );
      check(gatedBothMd).contains('| `single` |');
      check(gatedBothMd).contains('❓ Unresolved');

      // renderDeltaFromFiles with threshold on ComparisonScale.difference.
      final fBase = File(d.path('thresh_base.json'));
      final fCur = File(d.path('thresh_cur.json'));
      BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'w1',
            samples: const [100.0, 100.1, 99.9, 100.0],
          ),
        ],
      ).saveToFile(fBase);
      BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22, 1),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'w1',
            samples: const [100.2, 100.3, 100.1, 100.2],
          ),
        ],
      ).saveToFile(fCur);
      final fileDeltaMd = renderDeltaFromFiles(
        baselineFile: fBase,
        currentFile: fCur,
        scale: ComparisonScale.difference,
        threshold: 0.05,
      );
      check(fileDeltaMd).contains('✅ Equivalent');

      // Multi-target matrix headings, implicit group baseline, 1.0 GiB
      // implausible throughput, and <100x volume invariance formatting.
      final matrixMultiTarget = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'parse_op',
            target: 'jit',
            samples: const [10.0, 10.0],
            coordinates: const {'sdk': 'stock'},
            throughput: const Throughput.bytes(1024 * 1024 * 1024),
          ),
          BenchmarkEntry.fromSamples(
            name: 'parse_op',
            target: 'aot',
            samples: const [8.0, 8.0],
            coordinates: const {'sdk': 'stock'},
          ),
          BenchmarkEntry.fromSamples(
            name: 'inv_small',
            target: 'aot',
            samples: const [1000.0, 1000.0],
            coordinates: const {'sdk': 'stock'},
            throughput: const Throughput.bytes(1024),
          ),
          BenchmarkEntry.fromSamples(
            name: 'inv_large',
            target: 'aot',
            samples: const [1000.0, 1000.0],
            coordinates: const {'sdk': 'stock'},
            throughput: const Throughput.bytes(16 * 1024),
          ),
        ],
      );
      // Note: invariance matches benchmarks sharing prefix/family or same
      // group/suite—let's check multi-target headings and 1.0 GiB first:
      final multiTargetMd = MarkdownReporter.renderSuite(matrixMultiTarget);
      check(multiTargetMd)
        ..contains('### Benchmark: `parse_op` (`jit`)')
        ..contains('### Benchmark: `parse_op` (`aot`)')
        ..contains('1.0 GiB');

      // Legacy multi-group suite where neither entry sets isBaseline: true
      // falls back to entries.first in Suite Summary, and same-family sizes
      // with <100x ratio format volumeRatio with 1 decimal place.
      final implicitBaseGroups = BenchmarkSuiteResult(
        timestamp: DateTime.utc(2026, 11, 22),
        environment: env,
        benchmarks: [
          BenchmarkEntry.fromSamples(
            name: 'impl_a',
            samples: const [100.0, 100.0],
            coordinates: const {'group': 'g1'},
            throughput: const Throughput.bytes(1024),
          ),
          BenchmarkEntry.fromSamples(
            name: 'impl_b',
            samples: const [50.0, 50.0],
            coordinates: const {'group': 'g1'},
          ),
          BenchmarkEntry.fromSamples(
            name: 'impl_a',
            samples: const [100.0, 100.0],
            coordinates: const {'group': 'g2'},
            throughput: const Throughput.bytes(16 * 1024),
          ),
          BenchmarkEntry.fromSamples(
            name: 'impl_b',
            samples: const [50.0, 50.0],
            coordinates: const {'group': 'g2'},
          ),
        ],
      );
      final implicitMd = MarkdownReporter.renderSuite(implicitBaseGroups);
      check(implicitMd)
        ..contains('### Suite Summary')
        ..contains('**2.00x**')
        ..contains('**16.0x** the data');
    });
  });
}
