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
  static final RegExp _cpuListPattern = RegExp(
    r'^\d+(-\d+(:\d+)?)?(,\d+(-\d+(:\d+)?)?)*$',
  );

  /// Parses a `--pin-cpu` value in `taskset -c` list syntax.
  ///
  /// Accepts a single CPU (`2`), a comma-separated list (`0,2,4`), a range
  /// (`0-3`), a strided range (`0-7:2`), and any combination (`0-3,8`).
  ///
  /// Throws [FormatException] if [spec] is not that syntax, or if a range runs
  /// backwards. Validating here rather than letting `taskset` reject it keeps
  /// the error attached to the flag the user typed, and catches the mistake
  /// before a multi-minute suite has compiled anything.
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
      final bounds = part.split(':').first.split('-');
      if (bounds.length == 2) {
        final start = int.parse(bounds[0]);
        final end = int.parse(bounds[1]);
        if (end < start) {
          throw FormatException(
            'CPU range "$part" runs backwards; expected low-high.',
            spec,
          );
        }
      }
    }
    return CpuAffinity._(trimmed);
  }

  /// Wraps [executable] and [args] so the process runs pinned to [cpuList].
  ///
  /// This is unconditional: callers decide whether pinning is supported before
  /// wrapping, so that an unsupported host reports one clear warning instead of
  /// a `taskset` lookup failure per benchmark target.
  (String executable, List<String> args) wrap(
    String executable,
    List<String> args,
  ) => ('taskset', <String>['-c', cpuList, executable, ...args]);

  @override
  String toString() => 'CpuAffinity($cpuList)';
}

/// Explains why CPU pinning is unavailable on this host, or `null` when it is
/// available.
///
/// The returned message names the specific obstacle and what to do instead, so
/// a suite that silently ran unpinned is distinguishable in the logs from one
/// that was pinned as asked.
///
/// [isLinux] and [hasTaskset] exist so this is testable without depending on
/// what the host running the tests happens to have installed.
String? cpuPinningUnsupportedReason({
  bool? isLinux,
  bool Function()? hasTaskset,
}) {
  if (!(isLinux ?? Platform.isLinux)) {
    final os = Platform.operatingSystem;
    if (Platform.isMacOS) {
      return 'CPU pinning is unavailable on macOS: the Darwin kernel exposes '
          'no POSIX CPU affinity interface, so there is no equivalent of '
          'taskset. Reduce variance by closing other work and raising '
          '--trials instead.';
    }
    return 'CPU pinning is only implemented on Linux (host is "$os"), where it '
        'shells out to taskset.';
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
    return Process.runSync('taskset', const ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
