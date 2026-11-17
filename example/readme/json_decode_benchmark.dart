import 'dart:convert';

import 'package:bench_press/bench_press.dart';

final class JsonDecodeBenchmark(final String _payload) extends Benchmark {
  late List<int> _utf8Bytes;

  this
    : super(
        'json_decode',
        config: const BenchmarkConfig(trials: 16, maxTrials: 32),
      );

  @override
  Throughput get throughput => Throughput.bytes(_utf8Bytes.length);

  @override
  void setup() {
    _utf8Bytes = utf8.encode(_payload);
  }

  @override
  void run() {
    Blackhole.consume(jsonDecode(_payload));
  }
}

void main(List<String> args) =>
    mainBenchmark(JsonDecodeBenchmark('{"key": "value"}'), args);
