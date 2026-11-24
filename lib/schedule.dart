/// Pure-Dart, runner-agnostic multi-round benchmark coordinator supporting
/// counterbalanced `ABBA BAAB`, seeded randomized, and sequential schedules
/// with explicit pairing provenance.
library;

export 'src/schedule/pairing.dart' show PairingInfo;
export 'src/schedule/round_scheduler.dart'
    show
        RoundContext,
        RoundScheduler,
        ScheduleArm,
        ScheduleMode,
        ScheduledArmResult,
        ScheduledRun,
        ScheduledSample;
