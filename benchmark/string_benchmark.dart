import 'package:bench_press/bench_press.dart';

const int _itemCount = 64;
final List<String> _words = List<String>.generate(
  _itemCount,
  (i) => 'token_$i',
  growable: false,
);

/// String concatenation using the '+' operator.
final class StringPlusConcatBenchmark extends Benchmark {
  StringPlusConcatBenchmark() : super('string/plus_concat');

  @override
  void run() {
    var result = '';
    for (var i = 0; i < _itemCount; i++) {
      result += _words[i];
    }
    Blackhole.consume(result);
  }
}

/// String concatenation using [StringBuffer].
final class StringBufferBenchmark extends Benchmark {
  StringBufferBenchmark() : super('string/string_buffer');

  @override
  void run() {
    final sb = StringBuffer();
    for (var i = 0; i < _itemCount; i++) {
      sb.write(_words[i]);
    }
    Blackhole.consume(sb.toString());
  }
}

/// String construction using string interpolation.
final class StringInterpolationBenchmark extends Benchmark {
  StringInterpolationBenchmark() : super('string/interpolation');

  @override
  void run() {
    var result = '';
    for (var i = 0; i < _itemCount; i++) {
      result = '$result${_words[i]}';
    }
    Blackhole.consume(result);
  }
}

/// String construction using [Iterable.join].
final class StringJoinBenchmark extends Benchmark {
  StringJoinBenchmark() : super('string/join');

  @override
  void run() {
    final result = _words.join();
    Blackhole.consume(result);
  }
}

/// Discovered benchmark collection for `bench_press run` / `validate`.
final List<Object> benchmarks = [
  StringPlusConcatBenchmark(),
  StringBufferBenchmark(),
  StringInterpolationBenchmark(),
  StringJoinBenchmark(),
];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
