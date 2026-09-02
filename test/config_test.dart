import 'dart:io';

import 'package:bench_press/src/config/bench_press_config.dart';
import 'package:test/test.dart';

void main() {
  group('BenchPressConfig', () {
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

    test('dry run argument flag logic tested in cli', () {});
  });
}
