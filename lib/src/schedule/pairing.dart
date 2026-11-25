/// Provenance metadata certifying whether sample vectors across competing
/// benchmark arms were collected in lockstep interleaved rounds.
///
/// Downstream paired confidence intervals (`FiellerInterval` and
/// `DifferenceInterval` with `paired: true`) require two arms to share the same
/// [groupId], `interleaved == true`, and equal `rounds >= 2`. Sequential runs
/// stamp `interleaved: false` so paired CIs cannot be accidentally applied to
/// unaligned sequential series.
final class const PairingInfo._({
  /// Unique identifier shared strictly by arms executed in the same scheduled
  /// run.
  required final String groupId,

  /// Canonical schedule identifier (`'abba_baab'`, `'randomized'`, or
  /// `'sequential'`).
  required final String schedule,

  /// Whether the arms were interleaved within each round so shared slow host
  /// drift cancels pairwise across rounds.
  required final bool interleaved,

  /// Number of measured rounds executed per arm.
  required final int rounds,

  /// Random seed used when [schedule] is `'randomized'`, or `null` otherwise.
  final int? seed,
}) {
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PairingInfo &&
          other.groupId == groupId &&
          other.schedule == schedule &&
          other.interleaved == interleaved &&
          other.rounds == rounds &&
          other.seed == seed);

  @override
  int get hashCode => Object.hash(groupId, schedule, interleaved, rounds, seed);

  @override
  String toString() =>
      'PairingInfo($groupId, $schedule, interleaved: $interleaved, '
      'rounds: $rounds${seed != null ? ', seed: $seed' : ''})';
}

/// Internal [PairingInfo] serialization helpers kept out of `api.txt`.
extension InternalPairingInfo on PairingInfo {
  /// Converts this pairing provenance record to a JSON-compatible map.
  Map<String, Object?> toJson() => {
    'group_id': groupId,
    'schedule': schedule,
    'interleaved': interleaved,
    'rounds': rounds,
    if (seed != null) 'seed': seed,
  };
}

/// Reconstructs a [PairingInfo] from a JSON map (internal to `lib/src/`).
PairingInfo pairingInfoFromJson(Map<String, Object?> json) {
  final groupId = json['group_id'];
  final schedule = json['schedule'];
  final interleaved = json['interleaved'];
  final rounds = json['rounds'];
  final rawSeed = json['seed'];
  if (groupId is! String ||
      groupId.isEmpty ||
      schedule is! String ||
      schedule.isEmpty ||
      interleaved is! bool ||
      rounds is! int ||
      rounds < 1 ||
      (rawSeed != null && rawSeed is! int)) {
    throw const FormatException('Invalid or incomplete PairingInfo JSON');
  }
  return PairingInfo._(
    groupId: groupId,
    schedule: schedule,
    interleaved: interleaved,
    rounds: rounds,
    seed: rawSeed as int?,
  );
}

int _nextGroupNonce = 0;

/// Generates a fresh monotonic pairing group identifier (internal to
/// `lib/src/`).
String generatePairingGroupId() {
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final nonce = ++_nextGroupNonce;
  return 'pair_${micros}_$nonce';
}

/// Constructs a validated [PairingInfo] instance (internal to `lib/src/`).
PairingInfo createPairingInfo({
  required String groupId,
  required String schedule,
  required bool interleaved,
  required int rounds,
  int? seed,
}) {
  if (groupId.isEmpty) {
    throw ArgumentError.value(groupId, 'groupId', 'Cannot be empty.');
  }
  if (rounds < 1) {
    throw ArgumentError.value(rounds, 'rounds', 'Must be >= 1.');
  }
  return PairingInfo._(
    groupId: groupId,
    schedule: schedule,
    interleaved: interleaved,
    rounds: rounds,
    seed: seed,
  );
}

/// Whether [a] and [b] originate from the same interleaved multi-round
/// schedule and can be compared pairwise (internal to `lib/src/`).
bool canPairInfo(PairingInfo? a, PairingInfo? b) =>
    a != null &&
    b != null &&
    a.interleaved &&
    b.interleaved &&
    a.groupId == b.groupId &&
    a.rounds == b.rounds &&
    a.rounds >= 2;

/// Returns `true` when [round] (`0`-based) traverses arms in reverse order
/// under the counterbalanced `ABBA BAAB` schedule
/// (`(round & 1) != ((round >> 1) & 1)`: `AB`, `BA`, `BA`, `AB`, ...).
bool isReversedAbbaRound(int round) => (round & 1) != ((round >> 1) & 1);
