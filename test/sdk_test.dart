import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  group('TargetRuntime & Parsing', () {
    test('tryParse parses standard target names case-insensitively', () {
      check(TargetRuntime.tryParse('jit')).equals(TargetRuntime.jit);
      check(TargetRuntime.tryParse('JIT')).equals(TargetRuntime.jit);
      check(TargetRuntime.tryParse('aot')).equals(TargetRuntime.aot);
      check(TargetRuntime.tryParse('wasm')).equals(TargetRuntime.wasm);
      check(TargetRuntime.tryParse('js')).equals(TargetRuntime.js);
      check(TargetRuntime.tryParse('unknown')).isNull();
    });

    test('parseTargets parses comma-separated tokens and all keyword', () {
      final targets = TargetRuntime.parseTargets(['jit', 'aot,wasm', 'js']);
      check(targets).deepEquals([
        TargetRuntime.jit,
        TargetRuntime.aot,
        TargetRuntime.wasm,
        TargetRuntime.js,
      ]);

      final allTargets = TargetRuntime.parseTargets(['all']);
      check(allTargets).deepEquals(TargetRuntime.values);

      final defaultTargets = TargetRuntime.parseTargets([]);
      check(defaultTargets).deepEquals([TargetRuntime.jit]);

      check(() => TargetRuntime.parseTargets(['invalid_target']))
          .throws<FormatException>();
    });
    test('TargetRuntime toString returns canonical name', () {
      check(TargetRuntime.jit.toString()).equals('jit');
      check(TargetRuntime.aot.toString()).equals('aot');
      check(TargetRuntime.wasm.toString()).equals('wasm');
      check(TargetRuntime.js.toString()).equals('js');
    });

    test('parseTargets handles empty parts and whitespace', () {
      final targets = TargetRuntime.parseTargets([' jit , , aot ']);
      check(targets).deepEquals([TargetRuntime.jit, TargetRuntime.aot]);
    });
  });

  group('DartSdk Discovery & Utilities', () {
    test('probes FLUTTER_ROOT when DART_SDK is absent', () {
      final tempDir = Directory.systemTemp.createTempSync('flutter_sdk_');
      try {
        final dartSdkDir = Directory(
          p.join(tempDir.path, 'bin', 'cache', 'dart-sdk', 'bin'),
        )..createSync(recursive: true);
        File(p.join(dartSdkDir.path, 'dart')).writeAsStringSync('');
        File(p.join(tempDir.path, 'bin', 'cache', 'dart-sdk', 'version'))
            .writeAsStringSync('3.14.0\n');

        final sdk = DartSdk(
          environment: {'FLUTTER_ROOT': tempDir.path, 'PATH': ''},
        );
        check(sdk.sdkPath).isNotNull();
        check(sdk.sdkPath!).contains('dart-sdk');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('packageConfigPath resolves active config or fallback', () {
      const sdk = DartSdk();
      final configPath = sdk.packageConfigPath;
      if (configPath != null) {
        check(File(configPath).existsSync()).isTrue();
      }
    });

    test('runner getters detect node and d8 on PATH', () {
      final tempDir = Directory.systemTemp.createTempSync('runners_bin_');
      try {
        File(p.join(tempDir.path, 'node')).writeAsStringSync('');
        File(p.join(tempDir.path, 'd8')).writeAsStringSync('');

        final sdk = DartSdk(environment: {'PATH': tempDir.path});
        check(sdk.nodeExecutable).isNotNull();
        check(sdk.d8Executable).isNotNull();
        check(sdk.hasWasmRunner).isTrue();
        check(sdk.hasJsRunner).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('isValidSdkPath accurately validates directory structures', () {
      final tempDir = Directory.systemTemp.createTempSync('sdk_test_');
      try {
        check(DartSdk.isValidSdkPath(tempDir.path)).isFalse();

        final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        check(DartSdk.isValidSdkPath(tempDir.path)).isFalse();

        File(p.join(binDir.path, 'dart')).writeAsStringSync('');
        check(DartSdk.isValidSdkPath(tempDir.path)).isFalse();

        File(p.join(tempDir.path, 'version')).writeAsStringSync('3.14.0\n');
        check(DartSdk.isValidSdkPath(tempDir.path)).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('customSdkPath override takes precedence when valid', () {
      final tempDir = Directory.systemTemp.createTempSync('mock_sdk_');
      try {
        final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        File(p.join(binDir.path, 'dart')).writeAsStringSync('');
        File(p.join(tempDir.path, 'version')).writeAsStringSync('3.14.0\n');

        final sdk = DartSdk(customSdkPath: tempDir.path);
        check(sdk.sdkPath).equals(p.normalize(tempDir.absolute.path));
        check(sdk.dartExecutable).isNotNull();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('environment map override probes DART_SDK and PATH', () {
      final tempDir = Directory.systemTemp.createTempSync('env_sdk_');
      try {
        final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        File(p.join(binDir.path, 'dart')).writeAsStringSync('');
        File(p.join(tempDir.path, 'version')).writeAsStringSync('3.14.0\n');

        final sdk = DartSdk(environment: {'DART_SDK': tempDir.path});
        check(sdk.sdkPath).equals(p.normalize(tempDir.absolute.path));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('findExecutable searches directories in PATH', () {
      final tempDir = Directory.systemTemp.createTempSync('bin_path_');
      try {
        final dummyExe = File(p.join(tempDir.path, 'custom_runner'))
          ..writeAsStringSync('');

        final sdk = DartSdk(environment: {'PATH': tempDir.path});
        final found = sdk.findExecutable('custom_runner');
        check(found).equals(p.normalize(dummyExe.absolute.path));

        final notFound = sdk.findExecutable('non_existent_binary');
        check(notFound).isNull();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('current environment resolves active Dart SDK', () {
      const sdk = DartSdk();
      check(sdk.dartExecutable).isNotNull();
      check(sdk.isRuntimeAvailable(TargetRuntime.jit)).isTrue();
      check(sdk.isRuntimeAvailable(TargetRuntime.aot)).isTrue();
    });

    test('customD8Path and customNodePath resolve when files exist', () {
      final tempDir = Directory.systemTemp.createTempSync('custom_runners_');
      try {
        final d8File = File(p.join(tempDir.path, 'my_d8'))
          ..writeAsStringSync('');
        final nodeFile = File(p.join(tempDir.path, 'my_node'))
          ..writeAsStringSync('');

        final sdk = DartSdk(
          customD8Path: d8File.path,
          customNodePath: nodeFile.path,
          environment: {'PATH': ''},
        );

        check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
        check(sdk.nodeExecutable).equals(p.normalize(nodeFile.absolute.path));
        check(sdk.hasWasmRunner).isTrue();
        check(sdk.hasJsRunner).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'customD8Path and customNodePath return null when file does not exist',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'nonexistent_runners_',
        );
        try {
          final dummyPath = Directory(p.join(tempDir.path, 'bin'))
            ..createSync();
          File(p.join(dummyPath.path, 'd8')).writeAsStringSync('');
          File(p.join(dummyPath.path, 'node')).writeAsStringSync('');

          final sdk = DartSdk(
            customD8Path: p.join(tempDir.path, 'ghost_d8'),
            customNodePath: p.join(tempDir.path, 'ghost_node'),
            environment: {'PATH': dummyPath.path},
          );

          check(sdk.d8Executable).isNull();
          check(sdk.nodeExecutable).isNull();
          check(sdk.hasWasmRunner).isFalse();
          check(sdk.hasJsRunner).isFalse();
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'customD8Path and customNodePath take precedence over env and PATH',
      () {
        final tempDir = Directory.systemTemp.createTempSync('precedence_test_');
        try {
          final customD8 = File(p.join(tempDir.path, 'custom_d8'))
            ..writeAsStringSync('');
          final envD8 = File(p.join(tempDir.path, 'env_d8'))
            ..writeAsStringSync('');
          final pathDir = Directory(p.join(tempDir.path, 'path_bin'))
            ..createSync();
          File(p.join(pathDir.path, 'd8')).writeAsStringSync('');

          final customNode = File(p.join(tempDir.path, 'custom_node'))
            ..writeAsStringSync('');
          final envNode = File(p.join(tempDir.path, 'env_node'))
            ..writeAsStringSync('');
          File(p.join(pathDir.path, 'node')).writeAsStringSync('');

          final sdk = DartSdk(
            customD8Path: customD8.path,
            customNodePath: customNode.path,
            environment: {
              'D8_PATH': envD8.path,
              'NODE_PATH': envNode.path,
              'PATH': pathDir.path,
            },
          );

          check(sdk.d8Executable).equals(p.normalize(customD8.absolute.path));
          check(sdk.nodeExecutable)
              .equals(p.normalize(customNode.absolute.path));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'D8_PATH and NODE_PATH environment variables resolve when files exist',
      () {
        final tempDir = Directory.systemTemp.createTempSync('env_runners_');
        try {
          final d8File = File(p.join(tempDir.path, 'env_d8'))
            ..writeAsStringSync('');
          final nodeFile = File(p.join(tempDir.path, 'env_node'))
            ..writeAsStringSync('');

          final sdk = DartSdk(
            environment: {
              'D8_PATH': d8File.path,
              'NODE_PATH': nodeFile.path,
              'PATH': '',
            },
          );

          check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
          check(sdk.nodeExecutable).equals(p.normalize(nodeFile.absolute.path));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test('D8_PATH and NODE_PATH fall back when files do not exist', () {
      final tempDir = Directory.systemTemp.createTempSync('env_fallback_');
      try {
        final pathDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        final pathD8 = File(p.join(pathDir.path, 'd8'))..writeAsStringSync('');
        final pathNode = File(p.join(pathDir.path, 'node'))
          ..writeAsStringSync('');

        final sdk = DartSdk(
          environment: {
            'D8_PATH': p.join(tempDir.path, 'nonexistent_d8'),
            'NODE_PATH': p.join(tempDir.path, 'nonexistent_node'),
            'PATH': pathDir.path,
          },
        );

        check(sdk.d8Executable).equals(p.normalize(pathD8.absolute.path));
        check(sdk.nodeExecutable).equals(p.normalize(pathNode.absolute.path));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('auto-probes d8 at <sdkPath>/bin/resources/dart2wasm/d8', () {
      final tempDir = Directory.systemTemp.createTempSync('sdk_probe_');
      try {
        final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        File(p.join(binDir.path, 'dart')).writeAsStringSync('');
        File(p.join(tempDir.path, 'version')).writeAsStringSync('3.14.0\n');

        final exeName = Platform.isWindows ? 'd8.exe' : 'd8';
        final d8Dir = Directory(
          p.join(tempDir.path, 'bin', 'resources', 'dart2wasm'),
        )..createSync(recursive: true);
        final d8File = File(p.join(d8Dir.path, exeName))..writeAsStringSync('');

        final sdk = DartSdk(
          customSdkPath: tempDir.path,
          environment: {'PATH': ''},
        );

        check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('auto-probes d8 at <sdkPath>/out/ReleaseX64/d8', () {
      final tempDir = Directory.systemTemp.createTempSync('sdk_probe_out_');
      try {
        final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
        File(p.join(binDir.path, 'dart')).writeAsStringSync('');
        File(p.join(tempDir.path, 'version')).writeAsStringSync('3.14.0\n');

        final exeName = Platform.isWindows ? 'd8.exe' : 'd8';
        final d8Dir = Directory(p.join(tempDir.path, 'out', 'ReleaseX64'))
          ..createSync(recursive: true);
        final d8File = File(p.join(d8Dir.path, exeName))..writeAsStringSync('');

        final sdk = DartSdk(
          customSdkPath: tempDir.path,
          environment: {'PATH': ''},
        );

        check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
