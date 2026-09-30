import 'package:bench_press/src/cli/terminal.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Terminal & ANSI capability detection', () {
    test('useAnsi returns boolean without throwing', () {
      final value = useAnsi;
      check(value).isA<bool>();
    });
  });
}
