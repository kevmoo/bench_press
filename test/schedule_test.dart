import 'package:bench_press/schedule.dart';
import 'package:bench_press/src/schedule/pairing.dart' show canPairInfo;
import 'package:bench_press/stats.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('RoundScheduler', () {
    test('executes exact ABBA BAAB order across 2 and 3 arms', () {
      final trace2 = <String>[];
      final run2 = RoundScheduler.runSync<int>(
        arms: [
          SyncScheduleArm('A', isBaseline: true, (ctx) {
            trace2.add('A:${ctx.round}:${ctx.positionInRound}');
            return ctx.globalSequence;
          }),
          SyncScheduleArm('B', (ctx) {
            trace2.add('B:${ctx.round}:${ctx.positionInRound}');
            return ctx.globalSequence;
          }),
        ],
        rounds: 4,
      );

      check(trace2).deepEquals([
        'A:0:0',
        'B:0:1',
        'B:1:0',
        'A:1:1',
        'B:2:0',
        'A:2:1',
        'A:3:0',
        'B:3:1',
      ]);
      // Samples per arm stay indexed by round (0..3), NOT scrambled.
      check(run2['A']!.samples).deepEquals([0, 3, 5, 6]);
      check(run2['B']!.samples).deepEquals([1, 2, 4, 7]);
      check(run2.pairing.interleaved).isTrue;
      check(run2.pairing.schedule).equals('abba_baab');
      check(run2.warnings).isEmpty;

      // K = 3 arms over 4 rounds: ABC, CBA, CBA, ABC
      final order3 = <String>[];
      final run3 = RoundScheduler.runSync<int>(
        arms: [
          SyncScheduleArm('A', (ctx) {
            order3.add('A');
            return ctx.globalSequence;
          }),
          SyncScheduleArm('B', (ctx) {
            order3.add('B');
            return ctx.globalSequence;
          }),
          SyncScheduleArm('C', (ctx) {
            order3.add('C');
            return ctx.globalSequence;
          }),
        ],
        rounds: 4,
      );
      check(order3.join()).equals('ABCCBACBAABC');
      // Linear drift cancels across all 3 arms (mean globalSequence == 5.5).
      check(SampleSummary.fromSamples(run3['A']!.samples).mean).equals(5.5);
      check(SampleSummary.fromSamples(run3['B']!.samples).mean).equals(5.5);
      check(SampleSummary.fromSamples(run3['C']!.samples).mean).equals(5.5);
    });

    test(
      'ABBA BAAB cancels both linear and quadratic host drift on K=2, R=4',
      () {
        // Null experiment (true delta = 0) under quadratic thermal drift:
        // latency(t) = 1000 + 20*t - 1.5*t^2.
        double driftedLatency(RoundContext ctx) {
          final t = ctx.globalSequence.toDouble();
          return 1000.0 + 20.0 * t - 1.5 * t * t;
        }

        final run = RoundScheduler.runSync<double>(
          arms: [
            SyncScheduleArm('control', isBaseline: true, driftedLatency),
            SyncScheduleArm('candidate', driftedLatency),
          ],
          rounds: 4,
        );

        final meanControl = SampleSummary.fromSamples(run['control']!.samples)
            .mean;
        final meanCand = SampleSummary.fromSamples(run['candidate']!.samples)
            .mean;
        check(meanCand).isCloseTo(meanControl, 1e-12);
      },
    );

    test(
      'emits advisory warning on odd round count under AbbaBaabSchedule',
      () {
        final run = RoundScheduler.runSync<int>(
          arms: [
            SyncScheduleArm('A', (ctx) => ctx.round),
            SyncScheduleArm('B', (ctx) => ctx.round),
          ],
          rounds: 3,
        );
        check(run.warnings).isNotEmpty;
        check(run.warnings.single).contains('Odd round count (3)');
      },
    );

    test(
      'randomized schedule is reproducible and sequential unpairs',
      () async {
        Future<ScheduledRun<int>> runWithSeed(int seed) =>
            RoundScheduler.run<int>(
              arms: [
                ScheduleArm('A', (ctx) async => ctx.positionInRound),
                ScheduleArm('B', (ctx) async => ctx.positionInRound),
                ScheduleArm('C', (ctx) async => ctx.positionInRound),
              ],
              rounds: 5,
              mode: ScheduleMode.randomized(seed: seed),
            );

        final r1 = await runWithSeed(123456);
        final r2 = await runWithSeed(123456);
        check(r1['A']!.samples).deepEquals(r2['A']!.samples);
        check(r1['B']!.samples).deepEquals(r2['B']!.samples);
        check(r1['C']!.samples).deepEquals(r2['C']!.samples);
        check(r1.pairing.interleaved).isTrue;
        check(r1.pairing.seed).equals(123456);

        final seqOrder = <String>[];
        final seqRun = await RoundScheduler.run<int>(
          arms: [
            ScheduleArm('A', (ctx) {
              seqOrder.add('A${ctx.isWarmup ? 'w' : ctx.round}');
              return ctx.round;
            }),
            ScheduleArm('B', (ctx) {
              seqOrder.add('B${ctx.isWarmup ? 'w' : ctx.round}');
              return ctx.round;
            }),
          ],
          warmupRounds: 1,
          rounds: 2,
          mode: const ScheduleMode.sequential(),
        );
        check(seqOrder).deepEquals(['Aw', 'A0', 'A1', 'Bw', 'B0', 'B1']);
        check(seqRun.pairing.interleaved).isFalse;
        check(canPairInfo(seqRun.pairing, seqRun.pairing)).isFalse;
      },
    );

    test('supports warmupRounds, discardsOnSwitch, and aligned series', () {
      var discards = 0;
      final run = RoundScheduler.runSync<Map<String, double?>>(
        arms: [
          SyncScheduleArm('A', (ctx) {
            if (ctx.isSwitchDiscard) discards++;
            return {'ms': ctx.round == 1 ? null : 10.0 + ctx.round};
          }),
          SyncScheduleArm('B', (ctx) {
            if (ctx.isSwitchDiscard) discards++;
            return {'ms': 20.0 + ctx.round};
          }),
        ],
        warmupRounds: 1,
        rounds: 3,
        discardsOnSwitch: 2,
      );

      check(discards).isGreaterThan(0);
      check(run['A']!.warmupSamples.length).equals(1);
      check(run['A']!.samples.length).equals(3);

      // Round 1 had null for arm A, so round 1 is dropped across both arms.
      final aligned = run.extractAlignedSeries((m) => m['ms']);
      check(aligned['A']!).deepEquals([10.0, 12.0]);
      check(aligned['B']!).deepEquals([20.0, 22.0]);

      final pairingRt = PairingInfo.fromJson(run.pairing.toJson());
      check(pairingRt).equals(run.pairing);
    });

    test('validates invalid schedule configurations', () {
      check(() => RoundScheduler.runSync<int>(arms: const []))
          .throws<ArgumentError>();
      check(
        () => RoundScheduler.runSync<int>(
          arms: [
            SyncScheduleArm('dup', (_) => 1),
            SyncScheduleArm('dup', (_) => 2),
          ],
        ),
      ).throws<ArgumentError>();
      check(
        () => RoundScheduler.runSync<int>(
          arms: [SyncScheduleArm('A', (_) => 1)],
          rounds: 0,
        ),
      ).throws<ArgumentError>();
    });
  });
}
