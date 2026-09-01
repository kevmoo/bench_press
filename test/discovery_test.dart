import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('BenchmarkDiscovery & Content Classification', () {
    test('classifyContent identifies standalone main vs benchmarks list', () {
      const mainContent = '''
import 'package:bench_press/bench_press.dart';
void main(List<String> args) {
  print('hello');
}
''';
      check(BenchmarkDiscovery.classifyContent(mainContent))
          .equals(BenchmarkFileKind.standaloneMain);

      const asyncMainContent = '''
Future<void> main() async {}
''';
      check(BenchmarkDiscovery.classifyContent(asyncMainContent))
          .equals(BenchmarkFileKind.standaloneMain);

      const listContent = '''
import 'package:bench_press/bench_press.dart';
final benchmarks = [
  MyBenchmark(),
];
''';
      check(BenchmarkDiscovery.classifyContent(listContent))
          .equals(BenchmarkFileKind.benchmarksList);

      const unknownContent = '''
class Helper {}
''';
      check(BenchmarkDiscovery.classifyContent(unknownContent))
          .equals(BenchmarkFileKind.unknown);
    });

    test('discover traverses directories and skips ignored folders', () {
      final tempDir = Directory.systemTemp.createTempSync('discovery_test_');
      try {
        final benchDir = Directory(p.join(tempDir.path, 'benchmark'))
          ..createSync();
        final hiddenDir = Directory(p.join(tempDir.path, '.dart_tool'))
          ..createSync();
        final buildDir = Directory(p.join(tempDir.path, 'build'))..createSync();

        final fileA = File(p.join(benchDir.path, 'a_bench.dart'))
          ..writeAsStringSync('void main() {}');
        final fileB = File(p.join(benchDir.path, 'b_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');
        File(p.join(hiddenDir.path, 'ignored.dart'))
            .writeAsStringSync('void main() {}');
        File(p.join(buildDir.path, 'ignored.dart'))
            .writeAsStringSync('void main() {}');
        File(p.join(benchDir.path, 'readme.txt'))
            .writeAsStringSync('not a dart file');

        final discovered = BenchmarkDiscovery.discover(tempDir.path);
        check(discovered.length).equals(2);

        check(discovered[0].path).equals(p.normalize(fileA.absolute.path));
        check(discovered[0].kind).equals(BenchmarkFileKind.standaloneMain);

        check(discovered[1].path).equals(p.normalize(fileB.absolute.path));
        check(discovered[1].kind).equals(BenchmarkFileKind.benchmarksList);

        // Discover on single file
        final single = BenchmarkDiscovery.discover(fileA.path);
        check(single.length).equals(1);
        check(single.first.kind).equals(BenchmarkFileKind.standaloneMain);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('generateWrapper creates executable wrapper importing target', () {
      final tempDir = Directory.systemTemp.createTempSync('wrapper_test_');
      try {
        final sourceFile = File(p.join(tempDir.path, 'source_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');

        final outputDir = Directory(p.join(tempDir.path, 'generated'));
        final wrapper = BenchmarkDiscovery.generateWrapper(
          benchmarkFile: sourceFile,
          outputDir: outputDir,
        );

        check(wrapper.existsSync()).isTrue();
        final content = wrapper.readAsStringSync();
        check(
          content,
        ).contains('import \'package:bench_press/src/cli/suite_runner.dart\';');
        check(content).contains('mainBenchmarkSuite(target.benchmarks, args);');
        check(content).contains(p.normalize(sourceFile.absolute.path));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('classifyContent ignores commented-out void main()', () {
      const commentedLineMain = '''
// void main() {}
final benchmarks = [];
''';
      check(BenchmarkDiscovery.classifyContent(commentedLineMain))
          .equals(BenchmarkFileKind.benchmarksList);

      const commentedBlockMain = '''
/*
void main() {
  print('commented');
}
*/
final benchmarks = [];
''';
      check(BenchmarkDiscovery.classifyContent(commentedBlockMain))
          .equals(BenchmarkFileKind.benchmarksList);
    });

    test('generateWrapper produces unique filenames across subdirectories', () {
      final tempDir = Directory.systemTemp.createTempSync('wrapper_unique_');
      try {
        final sub1 = Directory(p.join(tempDir.path, 'sub1'))..createSync();
        final sub2 = Directory(p.join(tempDir.path, 'sub2'))..createSync();

        final file1 = File(p.join(sub1.path, 'foo_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');
        final file2 = File(p.join(sub2.path, 'foo_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');

        final outputDir = Directory(p.join(tempDir.path, 'generated'));
        final wrapper1 = BenchmarkDiscovery.generateWrapper(
          benchmarkFile: file1,
          outputDir: outputDir,
        );
        final wrapper2 = BenchmarkDiscovery.generateWrapper(
          benchmarkFile: file2,
          outputDir: outputDir,
        );

        check(wrapper1.path).not((it) => it.equals(wrapper2.path));
        check(wrapper1.existsSync()).isTrue();
        check(wrapper2.existsSync()).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
