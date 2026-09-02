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

    test('discover excludes BenchmarkFileKind.unknown helper files', () {
      final tempDir = Directory.systemTemp.createTempSync('discovery_unknown_');
      try {
        final benchDir = Directory(p.join(tempDir.path, 'benchmark'))
          ..createSync();

        final fileA = File(p.join(benchDir.path, 'a_bench.dart'))
          ..writeAsStringSync('void main() {}');
        final fileB = File(p.join(benchDir.path, 'b_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');
        final helperFile = File(p.join(benchDir.path, 'helper.dart'))
          ..writeAsStringSync('class Helper {}');

        final discovered = BenchmarkDiscovery.discover(tempDir.path);
        check(discovered.length).equals(2);
        check(discovered.map((d) => d.path))
          ..contains(p.normalize(fileA.absolute.path))
          ..contains(p.normalize(fileB.absolute.path))
          ..not((it) => it.contains(p.normalize(helperFile.absolute.path)));

        final singleUnknown = BenchmarkDiscovery.discover(helperFile.path);
        check(singleUnknown.length).equals(1);
        check(singleUnknown.first.kind).equals(BenchmarkFileKind.unknown);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'classifyContent preserves string literals with URLs and comment tokens',
      () {
        const urlInString = '''
final url = 'https://x.dev/foo'; void main() {}
''';
        check(BenchmarkDiscovery.classifyContent(urlInString))
            .equals(BenchmarkFileKind.standaloneMain);

        const blockTokensInString = '''
final open = '/*';
void main() {}
final close = '*/';
''';
        check(BenchmarkDiscovery.classifyContent(blockTokensInString))
            .equals(BenchmarkFileKind.standaloneMain);

        const lineTokenInString = '''
final slash = '//';
final benchmarks = [];
''';
        check(BenchmarkDiscovery.classifyContent(lineTokenInString))
            .equals(BenchmarkFileKind.benchmarksList);

        const codeLookalikeInString = '''
final str = '/* void main() {} */';
class Helper {}
''';
        check(BenchmarkDiscovery.classifyContent(codeLookalikeInString))
            .equals(BenchmarkFileKind.unknown);
      },
    );

    test('classifyContent supports omitted return type async main', () {
      const asyncBlockMain = '''
main() async {
  print('async main');
}
''';
      check(BenchmarkDiscovery.classifyContent(asyncBlockMain))
          .equals(BenchmarkFileKind.standaloneMain);

      const asyncArrowMain = '''
main(args) async => print(args);
''';
      check(BenchmarkDiscovery.classifyContent(asyncArrowMain))
          .equals(BenchmarkFileKind.standaloneMain);
    });

    test('discover handles relative paths with parent traversal (..)', () {
      final tempDir = Directory.systemTemp.createTempSync('discovery_rel_');
      try {
        final pkgA = Directory(p.join(tempDir.path, 'pkg_a'))..createSync();
        final pkgB = Directory(p.join(tempDir.path, 'pkg_b', 'benchmark'))
          ..createSync(recursive: true);
        File(p.join(pkgB.path, 'my_bench.dart'))
            .writeAsStringSync('void main() {}');

        final relTarget = p.join(pkgA.path, '..', 'pkg_b', 'benchmark');
        final discovered = BenchmarkDiscovery.discover(relTarget);
        check(discovered.length).equals(1);
        check(discovered.first.kind).equals(BenchmarkFileKind.standaloneMain);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('generateWrapper produces CWD-invariant wrapper filenames', () {
      final tempDir = Directory.systemTemp.createTempSync('wrapper_cwd_');
      try {
        final subDir = Directory(p.join(tempDir.path, 'sub'))
          ..createSync(recursive: true);
        final benchFile = File(p.join(subDir.path, 'my_bench.dart'))
          ..writeAsStringSync('final benchmarks = [];');
        final outputDir = Directory(p.join(tempDir.path, 'generated'));

        final wrapperFromAbs = BenchmarkDiscovery.generateWrapper(
          benchmarkFile: File(benchFile.absolute.path),
          outputDir: outputDir,
        );

        final wrapperFromRel = IOOverrides.runZoned(
          () => BenchmarkDiscovery.generateWrapper(
            benchmarkFile: File('my_bench.dart'),
            outputDir: outputDir,
          ),
          getCurrentDirectory: () => subDir,
        );

        check(wrapperFromAbs.path).equals(wrapperFromRel.path);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
