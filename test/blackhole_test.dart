import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Blackhole', () {
    setUp(Blackhole.reset);

    test('consumes arbitrary objects and primitive types without throwing', () {
      Blackhole.consume('hello');
      Blackhole.consume(42);
      Blackhole.consume(100);
      Blackhole.consume(3.14159);
      Blackhole.consume(true);
      Blackhole.consume(null);
      Blackhole.consume(Object());

      final checksum = Blackhole.drain();
      check(checksum).not((it) => it.equals(0));
    });

    test('drain clears the sink buffer and produces stable checksum', () {
      Blackhole.consume('alpha');
      Blackhole.consume('beta');

      final firstDrain = Blackhole.drain();
      check(firstDrain).not((it) => it.equals(0));

      final secondDrain = Blackhole.drain();
      check(secondDrain).equals(0);
    });

    test('slot position influences drain checksum (position-dependent)', () {
      // Sequence 1: 'a' then 'b'
      Blackhole.consume('a');
      Blackhole.consume('b');
      final checksum1 = Blackhole.drain();

      // Sequence 2: 'b' then 'a'
      Blackhole.consume('b');
      Blackhole.consume('a');
      final checksum2 = Blackhole.drain();

      check(checksum1).not((it) => it.equals(checksum2));
    });

    test('handles rolling buffer overflow with cyclic Gray coding', () {
      for (var i = 0; i < 100; i++) {
        Blackhole.consume('item_$i');
        Blackhole.consume(i);
      }

      final checksum = Blackhole.drain();
      check(checksum).not((it) => it.equals(0));
    });
  });
}
