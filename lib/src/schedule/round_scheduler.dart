import 'dart:async';
import 'dart:math' as math;

import 'pairing.dart';

/// Ordering policy for executing multiple benchmark arms across rounds.
sealed class const ScheduleMode() {
  /// Counterbalanced `ABBA BAAB` mirror rounds (`AB`, `BA`, `BA`, `AB`, ...).
  ///
  /// Even round counts cancel linear drift across any number of arms; multiples
  /// of 4 rounds cancel both linear and quadratic drift across 2 arms.
  const factory abbaBaab() = AbbaBaabSchedule;

  /// Randomized block design shuffling arm order independently in each round.
  const factory randomized({int? seed}) = RandomizedSchedule;

  /// Non-interleaved sequential execution (all rounds of arm 0, then arm 1,
  /// ...), stamping `PairingInfo.interleaved == false`.
  const factory sequential() = SequentialSchedule;
}

/// Counterbalanced `ABBA BAAB` schedule mode.
final class const AbbaBaabSchedule() extends ScheduleMode;

/// Seeded randomized-round schedule mode.
final class const RandomizedSchedule({final int? seed}) extends ScheduleMode;

/// Non-interleaved sequential schedule mode.
final class const SequentialSchedule() extends ScheduleMode;

/// Per-invocation execution metadata passed to each scheduled arm callback.
final class const RoundContext({
  /// Name of the arm being measured.
  required final String armName,

  /// Zero-based index of the arm in the schedule's arm list.
  required final int armIndex,

  /// Zero-based round index (`0 .. warmupRounds - 1` during warmup,
  /// `0 .. rounds - 1` during measurement).
  required final int round,

  /// Zero-based execution slot within the current round (`0 .. armCount - 1`).
  required final int positionInRound,

  /// Monotonically increasing execution counter across the entire run.
  required final int globalSequence,

  /// Whether this invocation is an unrecorded warmup or switch-discard pass.
  required final bool isWarmup,

  /// Whether this invocation is a throwaway transition discard triggered by
  /// switching arms.
  final bool isSwitchDiscard = false,
});

/// An asynchronous or synchronous benchmark arm driven by [RoundScheduler.run].
final class ScheduleArm<T>(
  /// Unique arm name within the schedule.
  final String name,

  /// Measurement callback invoked once per round.
  final FutureOr<T> Function(RoundContext context) measure, {

  /// Whether this arm is the control/baseline reference for its comparison
  /// group.
  final bool isBaseline = false,

  /// Optional matrix/group coordinates attached to this arm.
  final Map<String, String> coordinates = const {},
});

/// A synchronous benchmark arm driven by [RoundScheduler.runSync].
final class SyncScheduleArm<T>(
  /// Unique arm name within the schedule.
  final String name,

  /// Synchronous measurement callback invoked once per round.
  final T Function(RoundContext context) measure, {

  /// Whether this arm is the control/baseline reference for its comparison
  /// group.
  final bool isBaseline = false,

  /// Optional matrix/group coordinates attached to this arm.
  final Map<String, String> coordinates = const {},
});

/// A single measured sample recorded for an arm in a specific [round].
final class const ScheduledSample<T>({
  /// Zero-based measured round index (`0 .. rounds - 1`).
  required final int round,

  /// Zero-based execution position within [round].
  required final int positionInRound,

  /// Global execution sequence index across the schedule.
  required final int globalSequence,

  /// Recorded measurement payload.
  required final T value,
});

/// All measured and warmup observations collected for a single scheduled arm.
final class const ScheduledArmResult<T>({
  /// Unique arm name.
  required final String name,

  /// Whether this arm was marked as baseline/control.
  required final bool isBaseline,

  /// Coordinates associated with this arm.
  required final Map<String, String> coordinates,

  /// Measured records ordered strictly by `round` (`0 .. rounds - 1`).
  required final List<ScheduledSample<T>> records,

  /// Samples collected during `warmupRounds` (excluding switch discards).
  required final List<T> warmupSamples,

  /// Pairing provenance shared across this schedule execution.
  required final PairingInfo pairing,
}) {
  /// Unmodifiable list of measured values ordered by round (`0 .. rounds - 1`).
  List<T> get samples =>
      List<T>.unmodifiable([for (final r in records) r.value]);
}

/// Complete multi-arm execution result produced by [RoundScheduler].
final class const ScheduledRun<T>({
  /// Per-arm results in declaration order.
  required final List<ScheduledArmResult<T>> arms,

  /// Provenance metadata governing downstream paired comparisons.
  required final PairingInfo pairing,

  /// Advisory schedule diagnostics (e.g. odd round count under `abbaBaab`).
  final List<String> warnings = const [],
}) {
  /// Looks up the [ScheduledArmResult] named [name], or returns `null`.
  ScheduledArmResult<T>? operator [](String name) {
    for (final arm in arms) {
      if (arm.name == name) return arm;
    }
    return null;
  }

  /// Extracts round-aligned numeric sample vectors across all [arms] using
  /// [selector].
  ///
  /// Any round `r` in which any arm returns `null` or a non-finite `double` is
  /// omitted across *all* arms so that index `i` in every returned list still
  /// corresponds to the exact same measured round.
  Map<String, List<double>> extractAlignedSeries(
    double? Function(T sample) selector,
  ) {
    final result = <String, List<double>>{
      for (final arm in arms) arm.name: <double>[],
    };
    if (arms.isEmpty) return result;

    final roundCount = arms.first.records.length;
    for (var r = 0; r < roundCount; r++) {
      final roundValues = _selectRoundValues(r, selector);
      if (roundValues == null) continue;
      for (var i = 0; i < arms.length; i++) {
        result[arms[i].name]!.add(roundValues[i]);
      }
    }
    return {
      for (final MapEntry(:key, :value) in result.entries)
        key: List<double>.unmodifiable(value),
    };
  }

  List<double>? _selectRoundValues(
    int round,
    double? Function(T sample) selector,
  ) {
    final values = <double>[];
    for (final arm in arms) {
      if (round >= arm.records.length) return null;
      final selected = selector(arm.records[round].value);
      if (selected == null || !selected.isFinite) return null;
      values.add(selected);
    }
    return values;
  }
}

/// Runner-agnostic round coordinator driving arbitrary sync or async benchmark
/// callbacks across counterbalanced (`ABBA BAAB`), randomized, or sequential
/// schedules.
abstract final class RoundScheduler() {
  /// Default measured rounds (`4`, one complete `ABBA BAAB` block cancelling
  /// both linear and quadratic drift across two arms).
  static const int defaultRounds = 4;

  /// Executes asynchronous or mixed [arms] across [warmupRounds] + [rounds].
  static Future<ScheduledRun<T>> run<T>({
    required List<ScheduleArm<T>> arms,
    int rounds = defaultRounds,
    int warmupRounds = 0,
    int discardsOnSwitch = 0,
    ScheduleMode mode = const ScheduleMode.abbaBaab(),
    String? groupId,
  }) async {
    final plan = _buildPlan(
      armNames: [for (final a in arms) a.name],
      rounds: rounds,
      warmupRounds: warmupRounds,
      discardsOnSwitch: discardsOnSwitch,
      mode: mode,
      groupId: groupId,
    );
    final warmupPerArm = [for (var i = 0; i < arms.length; i++) <T>[]];
    final recordsPerArm = [
      for (var i = 0; i < arms.length; i++) <ScheduledSample<T>>[],
    ];

    var seq = 0;
    int? lastArm;
    for (final step in plan.steps) {
      final arm = arms[step.armIndex];
      if (discardsOnSwitch > 0 && lastArm != null && lastArm != step.armIndex) {
        for (var d = 0; d < discardsOnSwitch; d++) {
          await arm.measure(
            RoundContext(
              armName: arm.name,
              armIndex: step.armIndex,
              round: step.round,
              positionInRound: step.positionInRound,
              globalSequence: seq++,
              isWarmup: true,
              isSwitchDiscard: true,
            ),
          );
        }
      }
      final val = await arm.measure(
        RoundContext(
          armName: arm.name,
          armIndex: step.armIndex,
          round: step.round,
          positionInRound: step.positionInRound,
          globalSequence: seq,
          isWarmup: step.isWarmup,
        ),
      );
      if (step.isWarmup) {
        warmupPerArm[step.armIndex].add(val);
      } else {
        recordsPerArm[step.armIndex].add(
          ScheduledSample<T>(
            round: step.round,
            positionInRound: step.positionInRound,
            globalSequence: seq,
            value: val,
          ),
        );
      }
      seq++;
      lastArm = step.armIndex;
    }

    return _finalizeRun(
      armSpecs: [
        for (final a in arms)
          (name: a.name, isBaseline: a.isBaseline, coordinates: a.coordinates),
      ],
      recordsPerArm: recordsPerArm,
      warmupPerArm: warmupPerArm,
      plan: plan,
    );
  }

  /// Synchronously executes [arms] across [warmupRounds] + [rounds] without
  /// Future allocation overhead.
  static ScheduledRun<T> runSync<T>({
    required List<SyncScheduleArm<T>> arms,
    int rounds = defaultRounds,
    int warmupRounds = 0,
    int discardsOnSwitch = 0,
    ScheduleMode mode = const ScheduleMode.abbaBaab(),
    String? groupId,
  }) {
    final plan = _buildPlan(
      armNames: [for (final a in arms) a.name],
      rounds: rounds,
      warmupRounds: warmupRounds,
      discardsOnSwitch: discardsOnSwitch,
      mode: mode,
      groupId: groupId,
    );
    final warmupPerArm = [for (var i = 0; i < arms.length; i++) <T>[]];
    final recordsPerArm = [
      for (var i = 0; i < arms.length; i++) <ScheduledSample<T>>[],
    ];

    var seq = 0;
    int? lastArm;
    for (final step in plan.steps) {
      final arm = arms[step.armIndex];
      if (discardsOnSwitch > 0 && lastArm != null && lastArm != step.armIndex) {
        for (var d = 0; d < discardsOnSwitch; d++) {
          arm.measure(
            RoundContext(
              armName: arm.name,
              armIndex: step.armIndex,
              round: step.round,
              positionInRound: step.positionInRound,
              globalSequence: seq++,
              isWarmup: true,
              isSwitchDiscard: true,
            ),
          );
        }
      }
      final val = arm.measure(
        RoundContext(
          armName: arm.name,
          armIndex: step.armIndex,
          round: step.round,
          positionInRound: step.positionInRound,
          globalSequence: seq,
          isWarmup: step.isWarmup,
        ),
      );
      if (step.isWarmup) {
        warmupPerArm[step.armIndex].add(val);
      } else {
        recordsPerArm[step.armIndex].add(
          ScheduledSample<T>(
            round: step.round,
            positionInRound: step.positionInRound,
            globalSequence: seq,
            value: val,
          ),
        );
      }
      seq++;
      lastArm = step.armIndex;
    }

    return _finalizeRun(
      armSpecs: [
        for (final a in arms)
          (name: a.name, isBaseline: a.isBaseline, coordinates: a.coordinates),
      ],
      recordsPerArm: recordsPerArm,
      warmupPerArm: warmupPerArm,
      plan: plan,
    );
  }

  static _SchedulePlan _buildPlan({
    required List<String> armNames,
    required int rounds,
    required int warmupRounds,
    required int discardsOnSwitch,
    required ScheduleMode mode,
    required String? groupId,
  }) {
    _validateScheduleInputs(
      armNames: armNames,
      rounds: rounds,
      warmupRounds: warmupRounds,
      discardsOnSwitch: discardsOnSwitch,
    );

    final warnings = <String>[];
    final armCount = armNames.length;
    if (mode is AbbaBaabSchedule && armCount > 1 && rounds.isOdd) {
      warnings.add(
        'Odd round count ($rounds) under ScheduleMode.abbaBaab does not cancel '
        'linear drift; use an even round count (ideally a multiple of 4).',
      );
    }

    final effectiveSeed = switch (mode) {
      RandomizedSchedule(:final seed) =>
        seed ?? math.Random().nextInt(0x100000000),
      _ => null,
    };
    final random = effectiveSeed != null ? math.Random(effectiveSeed) : null;
    final scheduleName = switch (mode) {
      AbbaBaabSchedule() => 'abba_baab',
      RandomizedSchedule() => 'randomized',
      SequentialSchedule() => 'sequential',
    };
    final interleaved = mode is! SequentialSchedule && armCount > 1;
    final pairing = PairingInfo(
      groupId: (groupId != null && groupId.isNotEmpty)
          ? groupId
          : PairingInfo.generateGroupId(),
      schedule: scheduleName,
      interleaved: interleaved,
      rounds: rounds,
      seed: effectiveSeed,
    );

    final steps = mode is SequentialSchedule
        ? _buildSequentialSteps(armCount, warmupRounds, rounds)
        : _buildInterleavedSteps(armCount, warmupRounds, rounds, mode, random);

    return (
      pairing: pairing,
      warnings: List<String>.unmodifiable(warnings),
      steps: steps,
    );
  }

  static void _validateScheduleInputs({
    required List<String> armNames,
    required int rounds,
    required int warmupRounds,
    required int discardsOnSwitch,
  }) {
    if (armNames.isEmpty) {
      throw ArgumentError.value(armNames, 'arms', 'Must contain >= 1 arm.');
    }
    if (rounds < 1) {
      throw ArgumentError.value(rounds, 'rounds', 'Must be >= 1.');
    }
    if (warmupRounds < 0) {
      throw ArgumentError.value(warmupRounds, 'warmupRounds', 'Must be >= 0.');
    }
    if (discardsOnSwitch < 0) {
      throw ArgumentError.value(
        discardsOnSwitch,
        'discardsOnSwitch',
        'Must be >= 0.',
      );
    }
    final seen = <String>{};
    for (final name in armNames) {
      if (name.isEmpty) {
        throw ArgumentError.value(
          armNames,
          'arms',
          'Arm name cannot be empty.',
        );
      }
      if (!seen.add(name)) {
        throw ArgumentError.value(
          name,
          'arms',
          'Duplicate schedule arm name "$name".',
        );
      }
    }
  }

  static List<_Step> _buildSequentialSteps(
    int armCount,
    int warmupRounds,
    int rounds,
  ) {
    final steps = <_Step>[];
    for (var armIdx = 0; armIdx < armCount; armIdx++) {
      for (var w = 0; w < warmupRounds; w++) {
        steps.add((
          armIndex: armIdx,
          round: w,
          positionInRound: 0,
          isWarmup: true,
        ));
      }
      for (var r = 0; r < rounds; r++) {
        steps.add((
          armIndex: armIdx,
          round: r,
          positionInRound: 0,
          isWarmup: false,
        ));
      }
    }
    return steps;
  }

  static List<_Step> _buildInterleavedSteps(
    int armCount,
    int warmupRounds,
    int rounds,
    ScheduleMode mode,
    math.Random? random,
  ) {
    final steps = <_Step>[];
    for (var w = 0; w < warmupRounds; w++) {
      final order = _roundOrder(armCount, w, mode, random);
      for (var pos = 0; pos < order.length; pos++) {
        steps.add((
          armIndex: order[pos],
          round: w,
          positionInRound: pos,
          isWarmup: true,
        ));
      }
    }
    for (var r = 0; r < rounds; r++) {
      final order = _roundOrder(armCount, r, mode, random);
      for (var pos = 0; pos < order.length; pos++) {
        steps.add((
          armIndex: order[pos],
          round: r,
          positionInRound: pos,
          isWarmup: false,
        ));
      }
    }
    return steps;
  }

  static List<int> _roundOrder(
    int armCount,
    int round,
    ScheduleMode mode,
    math.Random? random,
  ) {
    if (mode is RandomizedSchedule) {
      return [for (var i = 0; i < armCount; i++) i]..shuffle(random);
    }
    final reverse = isReversedAbbaRound(round);
    return [for (var i = 0; i < armCount; i++) reverse ? armCount - 1 - i : i];
  }

  static ScheduledRun<T> _finalizeRun<T>({
    required List<
      ({String name, bool isBaseline, Map<String, String> coordinates})
    >
    armSpecs,
    required List<List<ScheduledSample<T>>> recordsPerArm,
    required List<List<T>> warmupPerArm,
    required _SchedulePlan plan,
  }) {
    final armResults = <ScheduledArmResult<T>>[
      for (var i = 0; i < armSpecs.length; i++)
        ScheduledArmResult<T>(
          name: armSpecs[i].name,
          isBaseline: armSpecs[i].isBaseline,
          coordinates: Map<String, String>.unmodifiable(
            armSpecs[i].coordinates,
          ),
          records: List<ScheduledSample<T>>.unmodifiable(recordsPerArm[i]),
          warmupSamples: List<T>.unmodifiable(warmupPerArm[i]),
          pairing: plan.pairing,
        ),
    ];
    return ScheduledRun<T>(
      arms: List<ScheduledArmResult<T>>.unmodifiable(armResults),
      pairing: plan.pairing,
      warnings: plan.warnings,
    );
  }
}

typedef _Step = ({int armIndex, int round, int positionInRound, bool isWarmup});

typedef _SchedulePlan = ({
  PairingInfo pairing,
  List<String> warnings,
  List<_Step> steps,
});
