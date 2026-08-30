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
      check(tpValid.formatRate(double.nan)).equals('-');
      check(tpValid.formatRate(double.infinity)).equals('-');
      check(tpValid.formatRate(double.negativeInfinity)).equals('-');
    });

    test('serializes to and from JSON', () {
      const tp = Throughput.bytes(2048);
      final json = tp.toJson();
      check(json).deepEquals({'type': 'bytes', 'amount': 2048});

      final rehydrated = Throughput.fromJson(json);
      check(rehydrated).isA<ByteThroughput>();
      check((rehydrated as ByteThroughput).bytes).equals(2048);
      check<Throughput>(rehydrated).equals(tp);
    });

    test('implements value equality and hashCode', () {
      const tp1 = Throughput.bytes(1024);
      const tp2 = ByteThroughput(1024);
      const tp3 = Throughput.bytes(2048);

      check(tp1).equals(tp2);
      check(tp1.hashCode).equals(tp2.hashCode);
      check(tp1 == tp3).isFalse();
    });

    test('implements toString', () {
      const tp = Throughput.bytes(1024);
      check(tp.toString()).equals('Throughput.bytes(1024)');
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
      // 1000 items in 100 µs (100,000 ns) = 10.0M items/s
      check(tp.formatRate(100000.0)).equals('10.0M items/s');
    });

    test('formats billions of elements (G)', () {
      const tp = Throughput.elements(1000, unit: 'items');
      // 1000 items in 1 µs (1000 ns) = 1.00G items/s
      check(tp.formatRate(1000.0)).equals('1.00G items/s');
    });

    test('handles edge cases gracefully', () {
      const tp = Throughput.elements(0);
      check(tp.formatRate(1e6)).equals('-');

      const tpValid = Throughput.elements(50);
      check(tpValid.formatRate(0.0)).equals('-');
      check(tpValid.formatRate(-1.0)).equals('-');
      check(tpValid.formatRate(double.nan)).equals('-');
      check(tpValid.formatRate(double.infinity)).equals('-');
      check(tpValid.formatRate(double.negativeInfinity)).equals('-');
    });

    test('serializes to and from JSON with custom unit', () {
      const tp = ElementThroughput(500, unit: 'AST nodes');
      final json = tp.toJson();
      check(json)
          .deepEquals({'type': 'elements', 'amount': 500, 'unit': 'AST nodes'});

      final rehydrated = Throughput.fromJson(json);
      check(rehydrated).isA<ElementThroughput>();
      final elem = rehydrated as ElementThroughput;
      check(elem.count).equals(500);
      check(elem.unit).equals('AST nodes');
      check(elem).equals(tp);
    });

    test('serializes to and from JSON with default unit', () {
      const tp = ElementThroughput(100);
      final json = tp.toJson();
      check(json)
          .deepEquals({'type': 'elements', 'amount': 100, 'unit': 'elements'});

      final rehydrated = Throughput.fromJson(json);
      check(rehydrated as ElementThroughput).equals(tp);

      // Also verify when 'unit' is omitted from input map
      final fromOmitted = Throughput.fromJson({
        'type': 'elements',
        'amount': 100,
      });
      check(fromOmitted as ElementThroughput).equals(tp);
    });

    test('implements value equality and hashCode', () {
      const tp1 = Throughput.elements(500, unit: 'tokens');
      const tp2 = ElementThroughput(500, unit: 'tokens');
      const tp3 = Throughput.elements(500, unit: 'records');
      const tp4 = Throughput.elements(600, unit: 'tokens');

      check(tp1).equals(tp2);
      check(tp1.hashCode).equals(tp2.hashCode);
      check(tp1 == tp3).isFalse();
      check(tp1 == tp4).isFalse();
    });

    test('implements toString', () {
      const tp = Throughput.elements(500, unit: 'tokens');
      check(tp.toString()).equals('Throughput.elements(500, unit: "tokens")');
    });
  });

  group('Throughput.fromJson validation', () {
    test('throws FormatException on unrecognized type', () {
      check(() => Throughput.fromJson({'type': 'invalid', 'amount': 100}))
          .throws<FormatException>();
    });

    test('throws FormatException on missing or null type', () {
      check(() => Throughput.fromJson({'amount': 100}))
          .throws<FormatException>();
    });

    test('throws FormatException on missing or null amount', () {
      check(() => Throughput.fromJson({'type': 'bytes'}))
          .throws<FormatException>();
    });

    test('throws FormatException on negative amount', () {
      check(() => Throughput.fromJson({'type': 'bytes', 'amount': -5}))
          .throws<FormatException>();
    });
  });
}
