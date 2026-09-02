import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('BenchmarkDiscovery', () {
    test('discover traverses directories and finds matching suffixes', () {
      final tempDir = Directory.systemTemp.createTempSync('discovery_test_');
      try {
        final benchDir = Directory(p.join(tempDir.path, 'benchmark'))
          ..createSync();
        final hiddenDir = Directory(p.join(tempDir.path, '.dart_tool'))
          ..createSync();
        final buildDir = Directory(p.join(tempDir.path, 'build'))..createSync();

        final fileA = File(p.join(benchDir.path, 'a_benchmark.dart'))
          ..writeAsStringSync('void main() {}');
        final fileB = File(p.join(benchDir.path, 'b_bench.dart'))
          ..writeAsStringSync('void main() {}');
        final helperFile = File(p.join(benchDir.path, 'helper.dart'))
          ..writeAsStringSync('class Helper {}');
        File(p.join(hiddenDir.path, 'ignored_benchmark.dart'))
            .writeAsStringSync('void main() {}');
        File(p.join(buildDir.path, 'ignored_bench.dart'))
            .writeAsStringSync('void main() {}');
        File(p.join(benchDir.path, 'readme.txt'))
            .writeAsStringSync('not a dart file');

        final discovered = BenchmarkDiscovery.discover(tempDir.path);
        check(discovered.length).equals(2);

        check(discovered[0].path).equals(p.normalize(fileA.absolute.path));
        check(discovered[0].basename).equals('a_benchmark.dart');

        check(discovered[1].path).equals(p.normalize(fileB.absolute.path));
        check(discovered[1].basename).equals('b_bench.dart');

        // Helper file is ignored by filename convention
        check(discovered.map((d) => d.path))
            .not((it) => it.contains(p.normalize(helperFile.absolute.path)));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('discover allows targeting single dart file directly', () {
      final tempDir = Directory.systemTemp.createTempSync('single_test_');
      try {
        final file = File(p.join(tempDir.path, 'custom_target.dart'))
          ..writeAsStringSync('void main() {}');

        final discovered = BenchmarkDiscovery.discover(file.path);
        check(discovered.length).equals(1);
        check(discovered.first.path).equals(p.normalize(file.absolute.path));
        check(discovered.first.basename).equals('custom_target.dart');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('discover throws FormatException for non-Dart single file target', () {
      final tempDir = Directory.systemTemp.createTempSync('non_dart_test_');
      try {
        final txtFile = File(p.join(tempDir.path, 'benchmark.txt'))
          ..writeAsStringSync('hello');

        check(() => BenchmarkDiscovery.discover(txtFile.path))
            .throws<FormatException>();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('discover throws PathNotFoundException for non-existent target', () {
      check(() => BenchmarkDiscovery.discover('/non_existent_target_path_xyz'))
          .throws<PathNotFoundException>();
    });

    test(
      'discover ignores dot-prefixed ancestor directories above targetPath',
      () {
        final tempDir = Directory.systemTemp.createTempSync('discovery_dot_');
        try {
          final target = Directory(
            p.join(tempDir.path, '.hidden', 'pkg_b', 'benchmark'),
          )..createSync(recursive: true);
          final benchFile = File(p.join(target.path, 'my_benchmark.dart'))
            ..writeAsStringSync('void main() {}');

          final discovered = BenchmarkDiscovery.discover(target.path);
          check(discovered.length).equals(1);
          check(discovered.first.path)
              .equals(p.normalize(benchFile.absolute.path));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
