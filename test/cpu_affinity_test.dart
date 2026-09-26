import 'dart:io';

import 'package:bench_press/src/cli/cpu_affinity.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('CpuAffinity.parse', () {
    test('accepts every taskset -c list form', () {
      const specs = ['0', '2', '0,2,4', '0-3', '0-7:2', '0-3,8', '0-3:2,9'];
      for (final spec in specs) {
        check(
          because: 'should accept "$spec"',
          CpuAffinity.parse(spec).cpuList,
        ).equals(spec);
      }
    });

    test('trims surrounding whitespace', () {
      check(CpuAffinity.parse('  0-3  ').cpuList).equals('0-3');
    });

    test('rejects values taskset would reject', () {
      for (final spec in [
        '',
        '   ',
        'all',
        '-1',
        '0-',
        '-3',
        '0,',
        ',0',
        '0..3',
        '0 3',
        '0-3-5',
        '1e2',
        '0x2',
      ]) {
        check(
          because: 'should reject "$spec"',
          () => CpuAffinity.parse(spec),
        ).throws<FormatException>();
      }
    });

    test('rejects a backwards range', () {
      // taskset accepts this silently as an empty set on some versions, which
      // would pin to nothing rather than reporting the typo.
      check(() => CpuAffinity.parse('3-1'))
          .throws<FormatException>()
          .has((e) => e.message, 'message')
          .contains('backwards');
    });
  });

  group('CpuAffinity.wrap', () {
    test('prefixes taskset -c ahead of the command', () {
      final affinity = CpuAffinity.parse('0-3');
      final (exe, args) = affinity.wrap('/usr/bin/dart', ['run', 'bench.dart']);
      check(exe).equals('taskset');
      check(args)
          .deepEquals(['-c', '0-3', '/usr/bin/dart', 'run', 'bench.dart']);
    });

    test('preserves argument order and an empty argument list', () {
      final affinity = CpuAffinity.parse('2');
      // An AOT executable is invoked with no leading runner arguments.
      check(affinity.wrap('./bench.exe', const []).$2)
          .deepEquals(['-c', '2', './bench.exe']);
    });

    test('does not quote or reorder arguments containing spaces', () {
      // Process.run passes argv directly, so an argument with a space must
      // survive as one element rather than being split or escaped.
      final affinity = CpuAffinity.parse('0');
      check(affinity.wrap('node', const ['--title=my bench', 'x.mjs']).$2)
          .deepEquals(['-c', '0', 'node', '--title=my bench', 'x.mjs']);
    });
  });

  group('cpuPinningUnsupportedReason', () {
    test('is null on Linux with taskset present', () {
      check(cpuPinningUnsupportedReason(isLinux: true, hasTaskset: () => true))
          .isNull();
    });

    test('names taskset and how to install it when missing', () {
      final reason = cpuPinningUnsupportedReason(
        isLinux: true,
        hasTaskset: () => false,
      );
      check(reason).isNotNull();
      check(reason!).contains('taskset');
      check(reason).contains('util-linux');
    });

    test('explains the platform when not Linux', () {
      final reason = cpuPinningUnsupportedReason(
        isLinux: false,
        hasTaskset: () => true,
      );
      check(reason).isNotNull();
      // The macOS branch reads Platform directly, so assert only the part that
      // holds for whichever non-Linux message this host produces.
      check(reason!.toLowerCase()).contains('cpu pinning');
    });

    test('agrees with the real host when given no overrides', () {
      final reason = cpuPinningUnsupportedReason();
      if (!Platform.isLinux) {
        check(reason).isNotNull();
      }
      // On Linux the answer depends on whether taskset is installed, which is
      // exactly what the probe is for; asserting either way would be asserting
      // the test machine's package list.
    });
  });
}
