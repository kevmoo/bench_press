import 'dart:io';

/// A request to pin benchmark subprocesses to a fixed set of CPUs.
///
/// Thread migration between cores invalidates L1/L2 caches mid-measurement, and
/// an SMT sibling running unrelated work contends for the same physical core's
/// execution units. Both show up as run-to-run variance that no amount of
/// additional trials removes, because it is not sampling noise — the machine is
/// genuinely doing something different each time.
///
/// Pinning is implemented by prefixing each benchmark command with `taskset`
/// from `util-linux`, rather than setting affinity in-process, so it applies
/// uniformly to every runtime `bench_press` drives: the Dart VM, AOT
/// executables, Node.js, and D8.
final class const CpuAffinity._(
  /// The CPU set in `taskset -c` list syntax, exactly as supplied.
  final String cpuList,
) {
  /// Matches a `taskset -c` CPU list: comma-separated single CPUs or ranges,
  /// where a range may carry a `:stride` suffix (`0-7:2` is every other CPU).
  ///
  /// The stride is `[1-9]\d*`, not `\d+`: `taskset` rejects a zero stride, and
  /// `:0` is a plausible mistype of `:1`.
  static final RegExp _cpuListPattern = RegExp(
    r'^\d+(-\d+(:[1-9]\d*)?)?(,\d+(-\d+(:[1-9]\d*)?)?)*$',
  );

  /// Constructs a [CpuAffinity] pinned to a single logical [core] (`>= 0`).
  factory singleCore(int core) {
    if (core < 0) {
      throw RangeError.value(core, 'core', 'CPU index must be >= 0.');
    }
    return CpuAffinity._('$core');
  }

  /// Parses a `--pin-cpu` value in `taskset -c` list syntax.
  ///
  /// Accepts a single CPU (`2`), a comma-separated list (`0,2,4`), a range
  /// (`0-3`), a strided range (`0-7:2`), and any combination (`0-3,8`).
  ///
  /// Throws [FormatException] if [spec] is not that syntax, if a range runs
  /// backwards, or if a CPU index does not fit in an `int`.
  factory parse(String spec) {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) {
      throw FormatException('CPU list is empty.', spec);
    }
    if (!_cpuListPattern.hasMatch(trimmed)) {
      throw FormatException(
        'Expected a taskset CPU list: a single CPU ("2"), a comma-separated '
        'list ("0,2,4"), a range ("0-3"), or a strided range ("0-7:2").',
        spec,
      );
    }
    for (final part in trimmed.split(',')) {
      for (final token in part.split(RegExp('[-:]'))) {
        if (int.tryParse(token) == null) {
          throw FormatException('CPU index "$token" is too large.', spec);
        }
      }
      final bounds = part.split(':').first.split('-');
      if (bounds.length == 2 && int.parse(bounds[1]) < int.parse(bounds[0])) {
        throw FormatException(
          'CPU range "$part" runs backwards; expected low-high.',
          spec,
        );
      }
    }
    return CpuAffinity._(trimmed);
  }

  /// Sorted, deduplicated list of logical CPU indices expanded from [cpuList].
  List<int> get cpus => expandCpuList(cpuList);

  /// Wraps [executable] and [args] so the process runs pinned to [cpuList].
  (String executable, List<String> args) wrap(
    String executable,
    List<String> args,
  ) => ('taskset', <String>['-c', cpuList, executable, ...args]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CpuAffinity && other.cpuList == cpuList);

  @override
  int get hashCode => cpuList.hashCode;

  @override
  String toString() => 'CpuAffinity($cpuList)';
}

/// Expands a Linux CPU list string (such as `"0-3,8"` or `"0-7:2"`) into a
/// sorted, deduplicated list of CPU indices, ignoring malformed fragments.
List<int> expandCpuList(String spec) {
  final seen = <int>{};
  for (final rawPart in spec.split(',')) {
    final part = rawPart.trim();
    if (part.isEmpty) continue;
    _expandPartInto(part, seen);
  }
  return List<int>.unmodifiable(seen.toList()..sort());
}

void _expandPartInto(String part, Set<int> out) {
  final colonIdx = part.indexOf(':');
  final rangePart = colonIdx >= 0 ? part.substring(0, colonIdx) : part;
  final stride = colonIdx >= 0
      ? (int.tryParse(part.substring(colonIdx + 1)) ?? 1)
      : 1;
  if (stride <= 0) return;

  final dashIdx = rangePart.indexOf('-');
  if (dashIdx < 0) {
    final single = int.tryParse(rangePart);
    if (single != null && single >= 0) out.add(single);
    return;
  }
  final low = int.tryParse(rangePart.substring(0, dashIdx));
  final high = int.tryParse(rangePart.substring(dashIdx + 1));
  if (low == null || high == null || low < 0 || high < low) return;
  for (var cpu = low; cpu <= high; cpu += stride) {
    out.add(cpu);
  }
}

/// Explains why CPU pinning is unavailable on this host, or `null` when it is
/// available.
String? cpuPinningUnsupportedReason({String? os, bool Function()? hasTaskset}) {
  final host = os ?? Platform.operatingSystem;
  if (host != 'linux') {
    if (host == 'windows') {
      return 'CPU pinning is not supported on Windows. Windows does have '
          'processor affinity, but it is a bitmask rather than a CPU list, so '
          '--pin-cpu does not map onto it. Set affinity on the bench_press '
          'process yourself (the ProcessorAffinity property on a launched '
          'process) and run without --pin-cpu.';
    }
    if (host == 'macos') {
      return 'CPU pinning is unavailable on macOS: the Darwin kernel exposes '
          'no POSIX CPU affinity interface, so there is no equivalent of '
          'taskset, and no per-process workaround either. Reduce variance by '
          'closing other work and raising --trials instead.';
    }
    return 'CPU pinning is only implemented on Linux (host is "$host"), where '
        'it shells out to taskset.';
  }
  if (!(hasTaskset ?? _tasksetOnPath)()) {
    return 'CPU pinning needs "taskset" on PATH, which was not found. It ships '
        'in util-linux (Debian/Ubuntu: "apt install util-linux"; Fedora: '
        '"dnf install util-linux-core"). Minimal container images often omit '
        'it.';
  }
  return null;
}

bool _tasksetOnPath() {
  try {
    Process.runSync('taskset', const ['--version']);
    return true;
  } on ProcessException {
    return false;
  }
}
