import 'dart:async';
import 'dart:io';

import 'cpu_affinity.dart';

/// Categories of host configuration or contention conditions known to inflate
/// wall-clock or memory benchmark variance.
enum HostWarningKind() {
  /// Running inside a virtualized guest (`/proc/cpuinfo` `hypervisor` or
  /// `/sys/hypervisor/type`).
  virtualMachine,

  /// Scaling governor on a benchmark CPU is not `'performance'`.
  nonPerformanceGovernor,

  /// Dynamic frequency turbo boost is enabled (`intel_pstate/no_turbo == 0` or
  /// `cpufreq/boost == 1`).
  turboBoostEnabled,

  /// Transparent huge pages are set to `[always]`, making TLB behavior depend
  /// on host page fragmentation.
  transparentHugePagesAlways,

  /// 1-minute OS load average exceeds `1.0`.
  highLoadAverage,

  /// Multiple logical CPUs pinned in one [CpuAffinity] share a physical core
  /// (SMT siblings).
  pinnedSmtSiblings,

  /// A pinned CPU or its SMT sibling exceeded 5% busy utilization prior to the
  /// benchmark.
  busyCpu,

  /// Hypervisor CPU steal time exceeded 1% during preflight sampling.
  hypervisorSteal,
}

String _warningKindJsonName(HostWarningKind kind) => switch (kind) {
  HostWarningKind.virtualMachine => 'virtual_machine',
  HostWarningKind.nonPerformanceGovernor => 'non_performance_governor',
  HostWarningKind.turboBoostEnabled => 'turbo_boost_enabled',
  HostWarningKind.transparentHugePagesAlways => 'transparent_huge_pages_always',
  HostWarningKind.highLoadAverage => 'high_load_average',
  HostWarningKind.pinnedSmtSiblings => 'pinned_smt_siblings',
  HostWarningKind.busyCpu => 'busy_cpu',
  HostWarningKind.hypervisorSteal => 'hypervisor_steal',
};

/// A structured preflight host noise warning with a human-readable diagnostic.
final class const HostWarning._({
  /// Structured category of the warning.
  required final HostWarningKind kind,

  /// Actionable human-readable diagnostic message.
  required final String message,

  /// Logical CPU index associated with this warning, when applicable.
  final int? cpu,
}) {
  Map<String, Object?> _toJson() => {
    'kind': _warningKindJsonName(kind),
    'message': message,
    if (cpu != null) 'cpu': cpu,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HostWarning &&
          other.kind == kind &&
          other.message == message &&
          other.cpu == cpu);

  @override
  int get hashCode => Object.hash(kind, message, cpu);

  @override
  String toString() => message;
}

/// Structured result of a host machine preflight noise and topology check.
final class const HostCheckResult._({
  /// Operating system identifier (e.g. `'linux'`, `'macos'`, `'windows'`).
  required final String os,

  /// Whether `/proc` and `/sys` inspection was supported on this host.
  required final bool isSupported,

  /// Whether the host was detected as a virtual machine guest.
  final bool? isVirtualMachine,

  /// Observed `scaling_governor` per inspected logical CPU.
  final Map<int, String> cpuGovernors = const {},

  /// Whether turbo boost is enabled (`true`), disabled (`false`), or unreadable
  /// (`null`).
  final bool? turboBoostEnabled,

  /// Active transparent hugepage policy (`'always'`, `'madvise'`, `'never'`),
  /// if readable.
  final String? transparentHugePages,

  /// 1-minute load average from `/proc/loadavg`, if readable.
  final double? loadAverage1m,

  /// Mapping from each inspected logical CPU to its physical core SMT siblings.
  final Map<int, List<int>> smtSiblings = const {},

  /// Sampled busy fraction (`0.0 .. 1.0`) per watched logical CPU.
  final Map<int, double> cpuBusyFraction = const {},

  /// Sampled hypervisor steal fraction (`0.0 .. 1.0`) per watched logical CPU.
  final Map<int, double> cpuStealFraction = const {},

  /// Advisory noise warnings discovered during the check.
  final List<HostWarning> warnings = const [],
}) {
  /// Whether zero host noise warnings were detected.
  bool get isClean => warnings.isEmpty;

  /// Converts this result to a JSON-compatible map suitable for embedding in
  /// `EnvironmentInfo.extra`.
  Map<String, Object?> toJson() => {
    'os': os,
    'is_supported': isSupported,
    'is_virtual_machine': ?isVirtualMachine,
    'cpu_governors': ?_stringifyIntKeys(cpuGovernors),
    'turbo_boost_enabled': ?turboBoostEnabled,
    'transparent_huge_pages': ?transparentHugePages,
    'load_average_1m': ?loadAverage1m,
    'smt_siblings': ?_stringifyIntKeys(smtSiblings),
    'cpu_busy_fraction': ?_stringifyIntKeys(cpuBusyFraction),
    'cpu_steal_fraction': ?_stringifyIntKeys(cpuStealFraction),
    if (warnings.isNotEmpty)
      'warnings': [for (final w in warnings) w._toJson()],
  };

  static Map<String, V>? _stringifyIntKeys<V>(Map<int, V> map) => map.isEmpty
      ? null
      : {for (final MapEntry(:key, :value) in map.entries) '$key': value};

  @override
  String toString() =>
      'HostCheckResult(os: $os, supported: $isSupported, '
      'warnings: ${warnings.length})';
}

/// Programmatic host topology validation and machine noise preflight checks.
abstract final class HostEnvironment() {
  /// Validates on Linux that every logical CPU in [affinity] exists and is
  /// online, returning the first error message or `null` when valid.
  static String? validateAffinity(CpuAffinity affinity) =>
      validateAffinityWith(affinity);

  /// Non-blocking preflight check of host CPU frequency scaling, turbo boost,
  /// transparent huge pages, load average, VM hypervisor flags, SMT sibling
  /// topology, and `/proc/stat` core contention/steal.
  static Future<HostCheckResult> check({
    CpuAffinity? affinity,
    Duration sampleDuration = const Duration(milliseconds: 200),
  }) => runHostCheck(affinity: affinity, sampleDuration: sampleDuration);
}

String? _defaultReadFile(String path) {
  try {
    return File(path).readAsStringSync();
  } on Object {
    return null;
  }
}

/// Testable single-core validation helper kept internal to `lib/src/host/`.
String? validateCoreWith(
  int core, {
  String? os,
  String? Function(String path)? readFile,
}) {
  if (core < 0) {
    return 'CPU index $core must be >= 0.';
  }
  final effectiveOs = os ?? Platform.operatingSystem;
  if (effectiveOs != 'linux') return null;

  final reader = readFile ?? _defaultReadFile;
  final cpuDir = '/sys/devices/system/cpu/cpu$core';
  if (reader('$cpuDir/topology/thread_siblings_list') == null) {
    final present = reader('/sys/devices/system/cpu/present')?.trim();
    final avail = (present != null && present.isNotEmpty)
        ? ' (available CPUs: $present)'
        : '';
    return 'CPU $core is not a valid logical CPU on this host$avail.';
  }
  if (reader('$cpuDir/online')?.trim() == '0') {
    return 'CPU $core is offline.';
  }
  return null;
}

/// Testable affinity validation helper kept internal to `lib/src/host/`.
String? validateAffinityWith(
  CpuAffinity affinity, {
  String? os,
  String? Function(String path)? readFile,
}) {
  for (final core in affinity.cpus) {
    final err = validateCoreWith(core, os: os, readFile: readFile);
    if (err != null) return err;
  }
  return null;
}

/// Testable async host preflight check kept internal to `lib/src/host/`.
Future<HostCheckResult> runHostCheck({
  CpuAffinity? affinity,
  Duration sampleDuration = const Duration(milliseconds: 200),
  String? os,
  String? Function(String path)? readFile,
  Future<void> Function(Duration)? delay,
}) async {
  final effectiveOs = os ?? Platform.operatingSystem;
  if (effectiveOs != 'linux') {
    return HostCheckResult._(os: effectiveOs, isSupported: false);
  }
  final reader = readFile ?? _defaultReadFile;
  final staticState = _collectStaticLinuxState(affinity, reader);
  if (!staticState.supported) {
    return HostCheckResult._(os: effectiveOs, isSupported: false);
  }

  Map<int, _CpuTimes>? afterStat;
  if (staticState.beforeStat != null && sampleDuration > Duration.zero) {
    await (delay ?? Future<void>.delayed)(sampleDuration);
    afterStat = _parseProcStat(reader('/proc/stat'));
  }

  return _finalizeLinuxCheck(effectiveOs, affinity, staticState, afterStat);
}

_StaticLinuxState _collectStaticLinuxState(
  CpuAffinity? affinity,
  String? Function(String path) reader,
) {
  final cpuinfo = reader('/proc/cpuinfo');
  final loadavgRaw = reader('/proc/loadavg');
  final procStatRaw = reader('/proc/stat');
  final pinnedCpus = affinity?.cpus ?? const <int>[];
  final targetCpus = pinnedCpus.isEmpty ? const <int>[0] : pinnedCpus;

  final governors = _readGovernors(targetCpus, reader);
  final siblings = _readSmtSiblings(pinnedCpus, reader);
  final isVm = _detectVirtualMachine(cpuinfo, reader('/sys/hypervisor/type'));
  final turbo = _detectTurboBoost(
    reader('/sys/devices/system/cpu/intel_pstate/no_turbo')?.trim(),
    reader('/sys/devices/system/cpu/cpufreq/boost')?.trim(),
  );
  final thp = _parseBracketedMode(
    reader('/sys/kernel/mm/transparent_hugepage/enabled'),
  );

  final hasBasicProc =
      cpuinfo != null || loadavgRaw != null || procStatRaw != null;
  final hasSysfsAttrs = isVm != null || turbo != null || thp != null;
  final supported =
      hasBasicProc ||
      hasSysfsAttrs ||
      governors.isNotEmpty ||
      siblings.isNotEmpty;

  return (
    supported: supported,
    isVm: isVm,
    governors: governors,
    turbo: turbo,
    thp: thp,
    loadAvg: _parseLoadAvg(loadavgRaw),
    siblings: siblings,
    beforeStat: _parseProcStat(procStatRaw),
  );
}

Map<int, String> _readGovernors(
  List<int> cpus,
  String? Function(String path) reader,
) {
  final governors = <int, String>{};
  for (final cpu in cpus) {
    final gov = reader(
      '/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor',
    )?.trim();
    if (gov != null && gov.isNotEmpty) governors[cpu] = gov;
  }
  return governors;
}

Map<int, List<int>> _readSmtSiblings(
  List<int> cpus,
  String? Function(String path) reader,
) {
  final siblings = <int, List<int>>{};
  for (final cpu in cpus) {
    final rawSib = reader(
      '/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list',
    )?.trim();
    if (rawSib != null && rawSib.isNotEmpty) {
      final parsed = expandCpuList(rawSib);
      siblings[cpu] = parsed.contains(cpu)
          ? parsed
          : (List<int>.of(parsed)
              ..add(cpu)
              ..sort());
    }
  }
  return siblings;
}

HostCheckResult _finalizeLinuxCheck(
  String os,
  CpuAffinity? affinity,
  _StaticLinuxState s,
  Map<int, _CpuTimes>? afterStat,
) {
  final warnings = <HostWarning>[];
  _appendEnvironmentWarnings(warnings, s);
  if (affinity != null) {
    _appendSmtOverlapWarnings(warnings, affinity, s.siblings);
  }

  final busyMap = <int, double>{};
  final stealMap = <int, double>{};
  if (s.beforeStat != null && afterStat != null) {
    _evaluateCpuUtilization(
      affinity: affinity,
      siblings: s.siblings,
      before: s.beforeStat!,
      after: afterStat,
      busyMap: busyMap,
      stealMap: stealMap,
      warnings: warnings,
    );
  }

  return HostCheckResult._(
    os: os,
    isSupported: true,
    isVirtualMachine: s.isVm,
    cpuGovernors: Map<int, String>.unmodifiable(s.governors),
    turboBoostEnabled: s.turbo,
    transparentHugePages: s.thp,
    loadAverage1m: s.loadAvg,
    smtSiblings: Map<int, List<int>>.unmodifiable({
      for (final MapEntry(:key, :value) in s.siblings.entries)
        key: List<int>.unmodifiable(value),
    }),
    cpuBusyFraction: Map<int, double>.unmodifiable(busyMap),
    cpuStealFraction: Map<int, double>.unmodifiable(stealMap),
    warnings: List<HostWarning>.unmodifiable(warnings),
  );
}

void _appendEnvironmentWarnings(
  List<HostWarning> warnings,
  _StaticLinuxState s,
) {
  if (s.isVm == true) {
    final govNote = s.governors.isEmpty
        ? ', and CPU frequency settings cannot be inspected from the guest'
        : '';
    warnings.add(
      HostWarning._(
        kind: HostWarningKind.virtualMachine,
        message:
            'Host appears to be a virtual machine; neighbor VMs on the '
            'physical host can perturb wall-clock latency$govNote.',
      ),
    );
  }
  for (final MapEntry(key: cpu, value: gov) in s.governors.entries) {
    if (gov != 'performance') {
      warnings.add(
        HostWarning._(
          kind: HostWarningKind.nonPerformanceGovernor,
          cpu: cpu,
          message:
              "CPU $cpu frequency governor is '$gov' rather than "
              "'performance'; clock frequency may scale mid-benchmark.",
        ),
      );
    }
  }
  if (s.turbo == true) {
    warnings.add(
      const HostWarning._(
        kind: HostWarningKind.turboBoostEnabled,
        message:
            'Turbo boost is enabled; clock speed may drift with thermal '
            'headroom and sibling core load.',
      ),
    );
  }
  if (s.thp == 'always') {
    warnings.add(
      const HostWarning._(
        kind: HostWarningKind.transparentHugePagesAlways,
        message:
            "Transparent huge pages are set to 'always'; backing-page "
            'allocation depends on memory fragmentation across runs.',
      ),
    );
  }
  if (s.loadAvg != null && s.loadAvg! > 1.0) {
    warnings.add(
      HostWarning._(
        kind: HostWarningKind.highLoadAverage,
        message:
            '1-minute load average is ${s.loadAvg!.toStringAsFixed(2)}; '
            'background processes may contend for caches and memory '
            'bandwidth.',
      ),
    );
  }
}

void _appendSmtOverlapWarnings(
  List<HostWarning> warnings,
  CpuAffinity affinity,
  Map<int, List<int>> siblings,
) {
  final pinnedSet = affinity.cpus.toSet();
  final reportedPairs = <(int, int)>{};
  for (final cpu in affinity.cpus) {
    final sibs = siblings[cpu];
    if (sibs == null) continue;
    for (final sib in sibs) {
      if (sib == cpu || !pinnedSet.contains(sib)) continue;
      final pair = cpu < sib ? (cpu, sib) : (sib, cpu);
      if (reportedPairs.add(pair)) {
        warnings.add(
          HostWarning._(
            kind: HostWarningKind.pinnedSmtSiblings,
            cpu: pair.$1,
            message:
                'Pinned CPU set (${affinity.cpuList}) includes SMT siblings '
                '(${pair.$1} and ${pair.$2}) sharing one physical core.',
          ),
        );
      }
    }
  }
}

void _evaluateCpuUtilization({
  required CpuAffinity? affinity,
  required Map<int, List<int>> siblings,
  required Map<int, _CpuTimes> before,
  required Map<int, _CpuTimes> after,
  required Map<int, double> busyMap,
  required Map<int, double> stealMap,
  required List<HostWarning> warnings,
}) {
  final pinnedSet = affinity?.cpus.toSet() ?? const <int>{};
  final watched = _watchedCpus(affinity, siblings, after);

  for (final cpu in watched) {
    final b = before[cpu];
    final a = after[cpu];
    if (b == null || a == null) continue;
    final total = a.total - b.total;
    if (total <= 0) continue;

    final busy = (a.busy - b.busy) / total;
    final steal = (a.steal - b.steal) / total;
    busyMap[cpu] = busy;
    stealMap[cpu] = steal;

    final label = _describeWatchedCpu(cpu, pinnedSet, siblings);
    if (affinity != null && busy > 0.05) {
      warnings.add(
        HostWarning._(
          kind: HostWarningKind.busyCpu,
          cpu: cpu,
          message:
              '$label was ${(busy * 100).toStringAsFixed(0)}% busy before '
              'the benchmark started.',
        ),
      );
    }
    if (steal > 0.01) {
      warnings.add(
        HostWarning._(
          kind: HostWarningKind.hypervisorSteal,
          cpu: cpu,
          message:
              '$label experienced ${(steal * 100).toStringAsFixed(0)}% '
              'hypervisor steal time.',
        ),
      );
    }
  }
}

List<int> _watchedCpus(
  CpuAffinity? affinity,
  Map<int, List<int>> siblings,
  Map<int, _CpuTimes> after,
) {
  if (affinity == null) {
    return after.keys.toList()..sort();
  }
  final set = <int>{...affinity.cpus};
  for (final sibs in siblings.values) {
    set.addAll(sibs);
  }
  return set.toList()..sort();
}

String _describeWatchedCpu(
  int cpu,
  Set<int> pinnedSet,
  Map<int, List<int>> siblings,
) {
  if (pinnedSet.contains(cpu)) return 'CPU $cpu (pinned benchmark core)';
  for (final MapEntry(key: pinned, value: sibs) in siblings.entries) {
    if (sibs.contains(cpu)) {
      return 'CPU $cpu (SMT sibling of CPU $pinned)';
    }
  }
  return 'CPU $cpu';
}

bool? _detectVirtualMachine(String? cpuinfo, String? hypervisorType) {
  if (hypervisorType != null && hypervisorType.trim().isNotEmpty) {
    return true;
  }
  if (cpuinfo == null) return null;
  for (final line in cpuinfo.split('\n')) {
    if (line.startsWith('flags') &&
        line.split(RegExp(r'\s+')).contains('hypervisor')) {
      return true;
    }
  }
  return false;
}

bool? _detectTurboBoost(String? intelNoTurbo, String? genericBoost) {
  if (intelNoTurbo == '0' || genericBoost == '1') return true;
  if (intelNoTurbo == '1' || genericBoost == '0') return false;
  return null;
}

String? _parseBracketedMode(String? raw) {
  if (raw == null) return null;
  final start = raw.indexOf('[');
  final end = start >= 0 ? raw.indexOf(']', start + 1) : -1;
  if (start < 0 || end <= start + 1) return null;
  return raw.substring(start + 1, end).trim();
}

double? _parseLoadAvg(String? raw) {
  if (raw == null) return null;
  final first = raw.trim().split(RegExp(r'\s+')).first;
  return double.tryParse(first);
}

Map<int, _CpuTimes>? _parseProcStat(String? contents) {
  if (contents == null) return null;
  final result = <int, _CpuTimes>{};
  for (final line in contents.split('\n')) {
    final parsed = _parseProcStatLine(line);
    if (parsed != null) result[parsed.$1] = parsed.$2;
  }
  return result.isEmpty ? null : result;
}

(int, _CpuTimes)? _parseProcStatLine(String line) {
  if (!line.startsWith('cpu') || line.startsWith('cpu ')) return null;
  final fields = line.split(RegExp(r'\s+'));
  final cpu = int.tryParse(fields[0].substring(3));
  if (cpu == null || fields.length < 5) return null;

  final values = <int>[
    for (final f in fields.skip(1))
      if (f.isNotEmpty) int.tryParse(f) ?? 0,
  ];
  if (values.length < 4) return null;

  var total = 0;
  for (var i = 0; i < values.length && i < 8; i++) {
    total += values[i];
  }
  final idle = values[3] + (values.length > 4 ? values[4] : 0);
  final steal = values.length > 7 ? values[7] : 0;
  return (cpu, (total: total, busy: total - idle - steal, steal: steal));
}

typedef _CpuTimes = ({int total, int busy, int steal});

typedef _StaticLinuxState = ({
  bool supported,
  bool? isVm,
  Map<int, String> governors,
  bool? turbo,
  String? thp,
  double? loadAvg,
  Map<int, List<int>> siblings,
  Map<int, _CpuTimes>? beforeStat,
});
