import 'package:bench_press/bench_press.dart';

const int _itemCount = 64;
final List<String> _words = List<String>.generate(
  _itemCount,
  (i) => 'token_$i',
  growable: false,
);

/// Model 1: Grouped String Construction Variants
final BenchmarkGroup stringConstructionGroup = BenchmarkGroup(
  'String Construction',
  [
    BenchmarkVariant(
      'plus_concat',
      () {
        var result = '';
        for (var i = 0; i < _itemCount; i++) {
          result += _words[i];
        }
        Blackhole.consume(result);
      },
      isBaseline: true,
      throughput: const Throughput.elements(_itemCount, unit: 'tokens'),
    ),
    BenchmarkVariant('string_buffer', () {
      final sb = StringBuffer();
      for (var i = 0; i < _itemCount; i++) {
        sb.write(_words[i]);
      }
      Blackhole.consume(sb.toString());
    }, throughput: const Throughput.elements(_itemCount, unit: 'tokens')),
    BenchmarkVariant('interpolation', () {
      var result = '';
      for (var i = 0; i < _itemCount; i++) {
        result = '$result${_words[i]}';
      }
      Blackhole.consume(result);
    }, throughput: const Throughput.elements(_itemCount, unit: 'tokens')),
    BenchmarkVariant('join', () {
      final result = _words.join();
      Blackhole.consume(result);
    }, throughput: const Throughput.elements(_itemCount, unit: 'tokens')),
  ],
);

/// Discovered benchmark collection for `bench_press run` / `validate`.
final List<Object> benchmarks = [stringConstructionGroup];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
