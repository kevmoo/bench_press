import 'package:bench_press/bench_press.dart';

Future<void> main(List<String> args) async {
  final matrix = Benchmark.matrix<int>(
    cases: [16, 256, 4096],
    name: (n) => 'string_length:$n',
    throughput: Throughput.bytes,
    baseline: (
      'concat',
      (n) {
        var str = '';
        for (var i = 0; i < n; i++) {
          str += 'x';
        }
        return str;
      },
    ),
    candidates: {
      'buffer': (n) {
        final sb = StringBuffer();
        for (var i = 0; i < n; i++) {
          sb.write('x');
        }
        return sb.toString();
      },
    },
  );
  await mainBenchmarkMatrix(matrix, args);
}
