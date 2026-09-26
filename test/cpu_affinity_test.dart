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
      // `taskset -c 3-1` fails with "failed to parse CPU list" on util-linux
      // 2.41.5, so rejecting here only moves the error earlier and attaches it
      // to the flag.
      check(() => CpuAffinity.parse('3-1'))
          .throws<FormatException>()
          .has((e) => e.message, 'message')
          .contains('backwards');
    });

    test('rejects a zero stride', () {
      // `:0` is a plausible mistype of `:1`, and taskset rejects it.
      check(() => CpuAffinity.parse('0-7:0')).throws<FormatException>();
      check(CpuAffinity.parse('0-7:1').cpuList).equals('0-7:1');
    });

    test('rejects a CPU index too large for an int', () {
      // taskset rejects these too. Without an explicit bound the failure
      // surfaced as Dart's own "Positive input exceeds the limit of integer".
      for (final spec in [
        '99999999999999999999',
        '18446744073709551616',
        '1-99999999999999999999',
        '0-7:99999999999999999999',
      ]) {
        check(because: 'should reject "$spec"', () => CpuAffinity.parse(spec))
            .throws<FormatException>()
            .has((e) => e.message, 'message')
            .contains('too large');
      }
    });

    test('accepts forms taskset accepts that look odd', () {
      // Verified against taskset from util-linux 2.41.5: out-of-order lists,
      // duplicates, leading zeros, degenerate ranges, and a stride wider than
      // the range are all valid, so the parser must not tighten past taskset.
      for (final spec in [
        '1,0',
        '0-3,0-3',
        '007',
        '0-03',
        '0-0',
        '1-1',
        '0-7:99',
      ]) {
        check(
          because: 'should accept "$spec"',
          CpuAffinity.parse(spec).cpuList,
        ).equals(spec);
      }
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
      check(cpuPinningUnsupportedReason(os: 'linux', hasTaskset: () => true))
          .isNull();
    });

    test('names taskset and how to install it when missing', () {
      final reason = cpuPinningUnsupportedReason(
        os: 'linux',
        hasTaskset: () => false,
      );
      check(reason).isNotNull();
      check(reason!).contains('taskset');
      check(reason).contains('util-linux');
    });

    test('offers Windows the affinity workaround it actually has', () {
      // Windows is the common Dart/Flutter host, so this branch matters more
      // than its rarity in CI suggests. It must not be lumped in with macOS:
      // Windows has affinity, it just is not a CPU list.
      final reason = cpuPinningUnsupportedReason(
        os: 'windows',
        hasTaskset: () => true,
      );
      check(reason).isNotNull();
      check(reason!).contains('Windows');
      check(reason).contains('start /affinity');
      check(
        because: 'a Windows user must not be told to install util-linux',
        reason,
      ).not((s) => s.contains('util-linux'));
    });

    test('tells macOS there is no workaround, not a taskset hint', () {
      final reason = cpuPinningUnsupportedReason(
        os: 'macos',
        hasTaskset: () => true,
      );
      check(reason).isNotNull();
      check(reason!).contains('macOS');
      check(reason).contains('--trials');
      check(
        because: 'Darwin has no affinity interface, so offer no false hope',
        reason,
      ).not((s) => s.contains('start /affinity'));
    });

    test('names an unrecognized platform rather than guessing', () {
      final reason = cpuPinningUnsupportedReason(
        os: 'fuchsia',
        hasTaskset: () => true,
      );
      check(reason).isNotNull();
      check(reason!).contains('fuchsia');
    });

    test('reports available when the real host has taskset', () {
      // The probe is the one part that must agree with reality, so assert
      // against the host rather than skipping the check: resolve taskset
      // independently of the code under test and require the same answer.
      if (!Platform.isLinux) {
        check(cpuPinningUnsupportedReason()).isNotNull();
        return;
      }
      final found = Platform.environment['PATH']!
          .split(':')
          .any((dir) => File('$dir/taskset').existsSync());
      final reason = cpuPinningUnsupportedReason();
      if (found) {
        check(
          because: 'taskset is on PATH, so pinning must report available',
          reason,
        ).isNull();
      } else {
        check(
          because: 'taskset is absent, so pinning must say so',
          reason,
        ).isNotNull();
      }
    });
  });
}
