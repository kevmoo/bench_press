import 'dart:io';

import 'package:bench_press/host.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('CpuAffinity extensions', () {
    test('expands single cores, ranges, strides, and deduplicates', () {
      check(CpuAffinity.singleCore(7).cpus).deepEquals([7]);
      check(CpuAffinity.parse('0-3,8').cpus).deepEquals([0, 1, 2, 3, 8]);
      check(CpuAffinity.parse('0-7:2,9').cpus).deepEquals([0, 2, 4, 6, 9]);
      check(CpuAffinity.parse('4,2,2-4').cpus).deepEquals([2, 3, 4]);
      check(CpuAffinity.parse('2,4')).equals(CpuAffinity.parse(' 2,4 '));
      check(CpuAffinity.parse('2,4').hashCode)
          .equals(CpuAffinity.parse('2,4').hashCode);
      check(() => CpuAffinity.singleCore(-1)).throws<RangeError>();
    });
  });

  group('HostEnvironment validation and preflight checks', () {
    test(
      'validateCore and validateAffinity detect missing and offline CPUs',
      () {
        final files = <String, String>{
          '/sys/devices/system/cpu/present': '0-7',
          '/sys/devices/system/cpu/cpu2/topology/thread_siblings_list': '2,6',
          '/sys/devices/system/cpu/cpu2/online': '1',
          '/sys/devices/system/cpu/cpu3/topology/thread_siblings_list': '3,7',
          '/sys/devices/system/cpu/cpu3/online': '0',
        };

        check(
          HostEnvironment.validateCore(
            2,
            os: 'linux',
            readFile: (p) => files[p],
          ),
        ).isNull;
        check(
          HostEnvironment.validateCore(
            3,
            os: 'linux',
            readFile: (p) => files[p],
          ),
        ).isNotNull().contains('offline');
        check(
          HostEnvironment.validateCore(
            99,
            os: 'linux',
            readFile: (p) => files[p],
          ),
        ).isNotNull().contains('0-7');
        check(
          HostEnvironment.validateAffinity(
            CpuAffinity.parse('2,3'),
            os: 'linux',
            readFile: (p) => files[p],
          ),
        ).isNotNull().contains('CPU 3');
        // Non-Linux returns null without reading /sys.
        check(HostEnvironment.validateCore(99, os: 'macos')).isNull;
      },
    );

    test(
      'detects all 8 HostWarningKind conditions from synthetic /proc and /sys',
      () async {
        var statCall = 0;
        final procStatBefore = '''
cpu  1000 0 0 9000 0 0 0 0 0 0
cpu2 100 0 0 900 0 0 0 0 0 0
cpu6 100 0 0 900 0 0 0 0 0 0
''';
        // Over 100 ticks: cpu2 busy = 20 (20% > 5%), steal = 5 (5% > 1%);
        // cpu6 idle = +100 (0% busy, 0% steal).
        final procStatAfter = '''
cpu  1020 0 0 9075 0 0 0 5 0 0
cpu2 120 0 0 975 0 0 0 5 0 0
cpu6 100 0 0 1000 0 0 0 0 0 0
''';

        final files = <String, String>{
          '/proc/cpuinfo': 'flags\t\t: fpu sse2 hypervisor avx2\n',
          '/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor':
              'powersave\n',
          '/sys/devices/system/cpu/cpu6/cpufreq/scaling_governor':
              'performance\n',
          '/sys/devices/system/cpu/intel_pstate/no_turbo': '0\n',
          '/sys/kernel/mm/transparent_hugepage/enabled':
              '[always] madvise never\n',
          '/proc/loadavg': '2.50 1.80 1.20 3/500 1234\n',
          '/sys/devices/system/cpu/cpu2/topology/thread_siblings_list': '2,6\n',
          '/sys/devices/system/cpu/cpu6/topology/thread_siblings_list': '2,6\n',
        };

        String? fakeReader(String path) {
          if (path == '/proc/stat') {
            return (statCall++ == 0) ? procStatBefore : procStatAfter;
          }
          return files[path];
        }

        final result = await HostEnvironment.check(
          affinity: CpuAffinity.parse('2,6'),
          sampleDuration: const Duration(milliseconds: 50),
          os: 'linux',
          readFile: fakeReader,
          delay: (_) async {},
        );

        check(result.isSupported).isTrue;
        check(result.isClean).isFalse;
        check(result.isVirtualMachine).equals(true);
        check(result.turboBoostEnabled).equals(true);
        check(result.transparentHugePages).equals('always');
        check(result.loadAverage1m).equals(2.50);
        check(result.smtSiblings[2]!).deepEquals([2, 6]);
        check(result.cpuBusyFraction[2]!).isCloseTo(0.20, 1e-9);
        check(result.cpuStealFraction[2]!).isCloseTo(0.05, 1e-9);

        final kinds = {for (final w in result.warnings) w.kind};
        check(kinds).deepEquals(HostWarningKind.values.toSet());

        final rt = HostCheckResult.fromJson(result.toJson());
        check(rt.warnings.length).equals(result.warnings.length);
        check(rt.cpuGovernors[2]).equals('powersave');
      },
    );

    test(
      'returns clean HostCheckResult on quiet bare-metal Linux configuration',
      () {
        final stat =
            'cpu2 100 0 0 900 0 0 0 0 0 0\ncpu6 100 0 0 900 0 0 0 0 0 0\n';
        final files = <String, String>{
          '/proc/cpuinfo': 'flags\t\t: fpu sse2 avx2\n',
          '/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor':
              'performance\n',
          '/sys/devices/system/cpu/intel_pstate/no_turbo': '1\n',
          '/sys/kernel/mm/transparent_hugepage/enabled':
              'always [madvise] never\n',
          '/proc/loadavg': '0.15 0.10 0.05 1/200 42\n',
          '/sys/devices/system/cpu/cpu2/topology/thread_siblings_list': '2,6\n',
          '/proc/stat': stat,
        };

        final res = HostEnvironment.checkSync(
          affinity: CpuAffinity.singleCore(2),
          os: 'linux',
          readFile: (p) => files[p],
          sleepFor: (_) {},
        );
        check(res.isSupported).isTrue;
        check(res.isClean).isTrue;
      },
    );

    test('degrades gracefully on macOS and Windows and works live on host', () {
      final mac = HostEnvironment.checkSync(os: 'macos');
      check(mac.os).equals('macos');
      check(mac.isSupported).isFalse;
      check(mac.isClean).isTrue;

      // Mocking only no_turbo or only THP (without /proc/*) still reports
      // isSupported: true.
      final turboOnly = HostEnvironment.checkSync(
        os: 'linux',
        readFile: (p) =>
            p == '/sys/devices/system/cpu/intel_pstate/no_turbo' ? '0\n' : null,
        sleepFor: (_) {},
      );
      check(turboOnly.isSupported).isTrue;
      check(turboOnly.turboBoostEnabled).equals(true);

      final thpOnly = HostEnvironment.checkSync(
        os: 'linux',
        readFile: (p) => p == '/sys/kernel/mm/transparent_hugepage/enabled'
            ? '[always] madvise never\n'
            : null,
        sleepFor: (_) {},
      );
      check(thpOnly.isSupported).isTrue;
      check(thpOnly.transparentHugePages).equals('always');

      final live = HostEnvironment.checkSync(sampleDuration: Duration.zero);
      check(live.os).equals(Platform.operatingSystem);
      if (Platform.isLinux) {
        check(live.isSupported).isTrue;
      }
    });
  });
}
