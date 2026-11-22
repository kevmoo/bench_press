/// Pure-Dart, runner-agnostic multi-round benchmark coordinator supporting
/// counterbalanced `ABBA BAAB`, seeded randomized, and sequential schedules
/// with explicit pairing provenance.
library;

export 'src/schedule/pairing.dart' show PairingInfo, isReversedAbbaRound;
export 'src/schedule/round_scheduler.dart'
    show
        AbbaBaabSchedule,
        RandomizedSchedule,
        RoundContext,
        RoundScheduler,
        ScheduleArm,
        ScheduleMode,
        ScheduledArmResult,
        ScheduledRun,
        ScheduledSample,
        SequentialSchedule,
        SyncScheduleArm;
