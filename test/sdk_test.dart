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
          .throws<ArgumentError>();
    });
  });

  group('DartSdk Discovery & Utilities', () {
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
  });
}
