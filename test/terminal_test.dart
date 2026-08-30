import 'package:bench_press/bench_press.dart';
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
