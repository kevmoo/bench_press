import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('BenchmarkDiscovery', () {
    test(
      'discover traverses directories and finds matching suffixes',
      () async {
        await d.dir('benchmark', [
          d.file('a_benchmark.dart', 'void main() {}'),
          d.file('b_bench.dart', 'void main() {}'),
          d.file('helper.dart', 'class Helper {}'),
          d.file('readme.txt', 'not a dart file'),
        ]).create();
        await d.dir('.dart_tool', [
          d.file('ignored_benchmark.dart', 'void main() {}'),
        ]).create();
        await d.dir('build', [
          d.file('ignored_bench.dart', 'void main() {}'),
        ]).create();

        final discovered = BenchmarkDiscovery.discover(d.sandbox);
        check(discovered.length).equals(2);

        check(discovered[0].path).equals(
          p.normalize(File(d.path('benchmark/a_benchmark.dart')).absolute.path),
        );
        check(discovered[0].basename).equals('a_benchmark.dart');

        check(discovered[1].path).equals(
          p.normalize(File(d.path('benchmark/b_bench.dart')).absolute.path),
        );
        check(discovered[1].basename).equals('b_bench.dart');

        check(discovered.map((item) => item.path)).not(
          (it) => it.contains(
            p.normalize(File(d.path('benchmark/helper.dart')).absolute.path),
          ),
        );
      },
    );

    test('discover allows targeting single dart file directly', () async {
      await d.file('custom_target.dart', 'void main() {}').create();
      final filePath = d.path('custom_target.dart');

      final discovered = BenchmarkDiscovery.discover(filePath);
      check(discovered.length).equals(1);
      check(discovered.first.path)
          .equals(p.normalize(File(filePath).absolute.path));
      check(discovered.first.basename).equals('custom_target.dart');
    });

    test(
      'discover throws FormatException for non-Dart single file target',
      () async {
        await d.file('benchmark.txt', 'hello').create();

        check(() => BenchmarkDiscovery.discover(d.path('benchmark.txt')))
            .throws<FormatException>();
      },
    );

    test('discover throws PathNotFoundException for non-existent target', () {
      check(() => BenchmarkDiscovery.discover('/non_existent_target_path_xyz'))
          .throws<PathNotFoundException>();
    });

    test(
      'discover ignores dot-prefixed ancestor directories above targetPath',
      () async {
        await d.dir('.hidden/pkg_b/benchmark', [
          d.file('my_benchmark.dart', 'void main() {}'),
        ]).create();

        final targetPath = d.path('.hidden/pkg_b/benchmark');
        final benchFile = File(p.join(targetPath, 'my_benchmark.dart'));

        final discovered = BenchmarkDiscovery.discover(targetPath);
        check(discovered.length).equals(1);
        check(discovered.first.path)
            .equals(p.normalize(benchFile.absolute.path));
      },
    );

    test(
      'discover with verbose: true logs skipped non-benchmark files',
      () async {
        await d.file('helper.dart', 'class Helper {}').create();
        await d.file('valid_benchmark.dart', 'void main() {}').create();

        final discovered = BenchmarkDiscovery.discover(
          d.sandbox,
          verbose: true,
        );
        check(discovered.length).equals(1);
        check(discovered.first.basename).equals('valid_benchmark.dart');
      },
    );
  });
}
