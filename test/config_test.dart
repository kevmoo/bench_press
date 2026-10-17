import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/config/bench_press_config.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';

void main() {
  group('BenchPressConfig', () {
    test('BenchmarkConfig.defaultTrials is 16 across config and defaults', () {
      expect(BenchmarkConfig.defaultTrials, equals(16));
      expect(const BenchmarkConfig().trials, equals(16));
      final parsed = BenchPressConfig.fromYaml(
        'matrix:\n  axes:\n    sdk: [stock]\n',
      ).defaults;
      expect(parsed.trials, equals(16));
      expect(parsed.processes, equals(1));
    });

    test('parses defaults.processes and defaults.forks alias', () {
      expect(
        BenchPressConfig.fromYaml('defaults:\n  processes: 5\n')
            .defaults
            .processes,
        equals(5),
      );
      expect(
        BenchPressConfig.fromYaml('defaults:\n  forks: 4\n').defaults.processes,
        equals(4),
      );
      expect(
        () => BenchPressConfig.fromYaml('defaults:\n  processes: 0\n'),
        throwsA(isA<SourceSpanException>()),
      );
    });

    test('parses defaults.threshold as fraction or percentage', () {
      expect(
        BenchPressConfig.fromYaml('defaults:\n  threshold: 0.02\n')
            .defaults
            .threshold,
        closeTo(0.02, 1e-9),
      );
      expect(
        BenchPressConfig.fromYaml('defaults:\n  threshold: 2%\n')
            .defaults
            .threshold,
        closeTo(0.02, 1e-9),
      );
      expect(DefaultsConfig.tryParseThreshold('0.05'), closeTo(0.05, 1e-9));
      expect(DefaultsConfig.tryParseThreshold('5%'), closeTo(0.05, 1e-9));
      expect(DefaultsConfig.tryParseThreshold('0'), equals(0.0));
      expect(DefaultsConfig.tryParseThreshold('-0.01'), isNull);
      expect(DefaultsConfig.tryParseThreshold('1.0'), isNull);
      expect(DefaultsConfig.tryParseThreshold('100%'), isNull);
      expect(DefaultsConfig.tryParseThreshold('abc'), isNull);
      expect(
        () => BenchPressConfig.fromYaml('defaults:\n  threshold: -0.1\n'),
        throwsA(isA<SourceSpanException>()),
      );
      expect(
        () => BenchPressConfig.fromYaml('defaults:\n  threshold: 1.2\n'),
        throwsA(isA<SourceSpanException>()),
      );
    });

    test('parses defaults and matrix axes', () {
      final yaml = '''
defaults:
  isolate_mode: true
  trials: 50
  targets:
    - jit
    - aot
matrix:
  axes:
    layout:
      flat: { flags: '' }
      nested: { flags: '--enable-asserts' }
    implementation:
      native: {}
      legacy: {}
''';
      final file = File('test_bench_press.yaml');
      file.writeAsStringSync(yaml);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      final config = BenchPressConfig.loadFrom('test_bench_press.yaml')!;
      expect(config.defaults.isolateMode, isTrue);
      expect(config.defaults.trials, equals(50));
      expect(config.defaults.targets, equals(['jit', 'aot']));
      expect(config.matrix.axes.length, equals(2));

      final coords = config.generateCoordinates();
      expect(coords.length, equals(4));

      expect(
        coords[0].coordinates,
        equals({'layout': 'flat', 'implementation': 'native'}),
      );
      expect(coords[0].isBaseline, isTrue); // first element in matrix
    });

    test('reads defaults.output, falling back to benchmark_results.json', () {
      expect(
        BenchPressConfig.fromYaml('defaults:\n  output: out/results.json\n')
            .defaults
            .output,
        equals('out/results.json'),
      );
      expect(
        BenchPressConfig.fromYaml('defaults:\n  trials: 5\n').defaults.output,
        equals('benchmark_results.json'),
      );
      expect(
        BenchPressConfig.fromYaml('matrix:\n  axes:\n    sdk: [stock]\n')
            .defaults
            .output,
        equals('benchmark_results.json'),
      );
    });

    test('rejects a defaults.output that is not a non-empty string', () {
      for (final value in ['', "''", '42']) {
        expect(
          () => BenchPressConfig.fromYaml('defaults:\n  output: $value\n'),
          throwsA(isA<SourceSpanException>()),
          reason: 'output: $value',
        );
      }
    });

    test('ignores a leftover matrix.entrypoints key', () {
      final config = BenchPressConfig.fromYaml('''
matrix:
  axes:
    sdk: [stock]
  entrypoints:
    a: a.dart
    b: b.dart
''');

      expect(
        config.generateCoordinates().map((c) => c.coordinates),
        equals([
          {'sdk': 'stock'},
        ]),
      );
    });

    test('dry run argument flag logic tested in cli', () {});
  });
}
