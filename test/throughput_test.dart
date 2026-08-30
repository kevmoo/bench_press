import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('Throughput.bytes', () {
    test('formats bytes per second', () {
      const tp = Throughput.bytes(100);
      // 100 bytes in 1 second (1e9 ns) = 100 B/s
      check(tp.formatRate(1e9)).equals('100 B/s');
    });

    test('formats kilobytes per second', () {
      const tp = Throughput.bytes(1024 * 10);
      // 10 KB in 1 second = 10.0 KB/s
      check(tp.formatRate(1e9)).equals('10.0 KB/s');
    });

    test('formats megabytes per second', () {
      const tp = Throughput.bytes(1024 * 1024 * 50);
      // 50 MB in 100 ms (1e8 ns) = 500.0 MB/s
      check(tp.formatRate(1e8)).equals('500.0 MB/s');
    });

    test('formats gigabytes per second', () {
      const tp = Throughput.bytes(1024 * 1024 * 1024);
      // 1 GB in 500 ms (5e8 ns) = 2.00 GB/s
      check(tp.formatRate(5e8)).equals('2.00 GB/s');
    });

    test('handles edge cases gracefully', () {
      const tp = Throughput.bytes(0);
      check(tp.formatRate(1e6)).equals('-');

      const tpValid = Throughput.bytes(100);
      check(tpValid.formatRate(0.0)).equals('-');
      check(tpValid.formatRate(-100.0)).equals('-');
    });

    test('serializes to and from JSON', () {
      const tp = Throughput.bytes(2048);
      final json = tp.toJson();
      check(json).deepEquals({'type': 'bytes', 'amount': 2048});

      final rehydrated = Throughput.fromJson(json);
      check(rehydrated).isA<ByteThroughput>();
      check((rehydrated as ByteThroughput).bytes).equals(2048);
    });
  });

  group('Throughput.elements', () {
    test('formats small element counts', () {
      const tp = Throughput.elements(50, unit: 'tokens');
      // 50 tokens in 1 second = 50 tokens/s
      check(tp.formatRate(1e9)).equals('50 tokens/s');
    });

    test('formats thousands of elements (k)', () {
      const tp = Throughput.elements(5000, unit: 'records');
      // 5000 records in 100 ms = 50.0k records/s
      check(tp.formatRate(1e8)).equals('50.0k records/s');
    });

    test('formats millions of elements (M)', () {
      const tp = Throughput.elements(1000, unit: 'items');
      // 1000 items in 1 µs (1000 ns) = 1.0B items/s
      check(tp.formatRate(1000.0)).equals('1.00B items/s');

      // 1000 items in 100 µs (100,000 ns) = 10.0M items/s
      check(tp.formatRate(100000.0)).equals('10.0M items/s');
    });

    test('handles edge cases gracefully', () {
      const tp = Throughput.elements(0);
      check(tp.formatRate(1e6)).equals('-');

      const tpValid = Throughput.elements(50);
      check(tpValid.formatRate(0.0)).equals('-');
      check(tpValid.formatRate(-1.0)).equals('-');
    });

    test('serializes to and from JSON', () {
      const tp = Throughput.elements(500, unit: 'AST nodes');
      final json = tp.toJson();
      check(json)
          .deepEquals({'type': 'elements', 'amount': 500, 'unit': 'AST nodes'});

      final rehydrated = Throughput.fromJson(json);
      check(rehydrated).isA<ElementThroughput>();
      final elem = rehydrated as ElementThroughput;
      check(elem.count).equals(500);
      check(elem.unit).equals('AST nodes');
    });
  });
}
