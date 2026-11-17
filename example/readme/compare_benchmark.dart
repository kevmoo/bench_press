import 'package:bench_press/bench_press.dart';

Future<void> main(List<String> args) async {
  final group = Benchmark.compare(
    name: 'string_build',
    throughput: const Throughput.elements(100, unit: 'chars'),
    baseline: (
      'concat',
      () {
        var str = '';
        for (var i = 0; i < 100; i++) {
          str += 'x';
        }
        return str;
      },
    ),
    candidates: {
      'buffer': () {
        final sb = StringBuffer();
        for (var i = 0; i < 100; i++) {
          sb.write('x');
        }
        return sb.toString();
      },
    },
  );
  await mainBenchmarkGroup(group, args);
}
