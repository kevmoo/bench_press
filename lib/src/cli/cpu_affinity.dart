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

  /// Parses a `--pin-cpu` value in `taskset -c` list syntax.
  ///
  /// Accepts a single CPU (`2`), a comma-separated list (`0,2,4`), a range
  /// (`0-3`), a strided range (`0-7:2`), and any combination (`0-3,8`).
  ///
  /// Throws [FormatException] if [spec] is not that syntax, if a range runs
  /// backwards, or if a CPU index does not fit in an `int`. Validating here
  /// keeps a malformed value attached to the flag the user typed instead of
  /// surfacing later as a `taskset` error.
  ///
  /// This checks *syntax* only. Whether the named CPUs exist on this host is
  /// left to `taskset`, because the process may be confined to a cpuset
  /// narrower than the machine, so a bound taken from
  /// `Platform.numberOfProcessors` would reject sets that are in fact valid.
  /// A nonexistent CPU therefore still fails after compilation, with
  /// `taskset: failed to set pid's affinity: Invalid argument`.
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
      // Bound every numeric token, including the stride and a bare CPU index.
      // Checking only range endpoints lets a value wider than an int through to
      // taskset, and lets Dart's own overflow wording leak into the flag error.
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
/// [os] (a [Platform.operatingSystem] value) and [hasTaskset] exist so every
/// branch is testable from any host, rather than only the one the tests happen
/// to run on.
String? cpuPinningUnsupportedReason({String? os, bool Function()? hasTaskset}) {
  final host = os ?? Platform.operatingSystem;
  if (host != 'linux') {
    if (host == 'windows') {
      // Windows is the common Dart/Flutter development host, and unlike macOS
      // it does have affinity control — it is simply not wired up here, since
      // the mask is a hex bitmap rather than a taskset CPU list.
      return 'CPU pinning is not supported on Windows. Windows does have '
          'processor affinity, but it takes a hex bitmask rather than a CPU '
          'list, so --pin-cpu does not map onto it. Pin the whole command '
          'instead: "start /affinity 4 dart run bench_press run ..." pins to '
          'CPU 2 (bit 2 = 0x4), or in PowerShell set ProcessorAffinity on the '
          'process returned by Start-Process -PassThru.';
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
    // Only whether the binary launched matters, never its exit status.
    // BusyBox's taskset supports `-c` but has no `--version` and exits 1, so
    // testing the exit code reports a working taskset as missing — and does it
    // precisely in the minimal container images where pinning is most wanted.
    Process.runSync('taskset', const ['--version']);
    return true;
  } on ProcessException {
    return false;
  }
}
