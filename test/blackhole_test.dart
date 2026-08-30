import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Blackhole', () {
    setUp(Blackhole.reset);

    test('consumes arbitrary objects and types without throwing', () {
      Blackhole.consume('hello');
      Blackhole.consume(42);
      Blackhole.consumeInt(100);
      Blackhole.consumeDouble(3.14159);
      Blackhole.consumeBool(true);

      final checksum = Blackhole.drain();
      check(checksum).not((it) => it.equals(0));
    });

    test('drain clears the sink buffer', () {
      Blackhole.consume('alpha');
      Blackhole.consume('beta');

      final firstDrain = Blackhole.drain();
      check(firstDrain).not((it) => it.equals(0));

      final secondDrain = Blackhole.drain();
      check(secondDrain).equals(0);
    });

    test('handles rolling buffer overflow gracefully', () {
      for (var i = 0; i < 100; i++) {
        Blackhole.consume('item_$i');
        Blackhole.consumeInt(i);
      }

      final checksum = Blackhole.drain();
      check(checksum).not((it) => it.equals(0));
    });
  });
}
