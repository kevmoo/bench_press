import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

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
    test('probes FLUTTER_ROOT when DART_SDK is absent', () async {
      await d.dir('bin/cache/dart-sdk', [
        d.file('version', '3.14.0\n'),
        d.dir('bin', [d.file('dart', '')]),
      ]).create();

      final sdk = DartSdk(environment: {'FLUTTER_ROOT': d.sandbox, 'PATH': ''});
      check(sdk.sdkPath).isNotNull();
      check(sdk.sdkPath!).contains('dart-sdk');
    });

    test('packageConfigPath resolves active config or fallback', () {
      const sdk = DartSdk();
      final configPath = sdk.packageConfigPath;
      if (configPath != null) {
        check(File(configPath).existsSync()).isTrue();
      }
    });

    test('runner getters detect node and d8 on PATH', () async {
      await d.file('node', '').create();
      await d.file('d8', '').create();

      final sdk = DartSdk(environment: {'PATH': d.sandbox});
      check(sdk.nodeExecutable).isNotNull();
      check(sdk.d8Executable).isNotNull();
      check(sdk.hasWasmRunner).isTrue();
      check(sdk.hasJsRunner).isTrue();
    });

    test('isValidSdkPath accurately validates directory structures', () async {
      check(DartSdk.isValidSdkPath(d.sandbox)).isFalse();

      await d.dir('bin').create();
      check(DartSdk.isValidSdkPath(d.sandbox)).isFalse();

      await d.file('bin/dart', '').create();
      check(DartSdk.isValidSdkPath(d.sandbox)).isFalse();

      await d.file('version', '3.14.0\n').create();
      check(DartSdk.isValidSdkPath(d.sandbox)).isTrue();
    });

    test('customSdkPath override takes precedence when valid', () async {
      await _createMockSdkInSandbox();

      final sdk = DartSdk(customSdkPath: d.sandbox);
      check(sdk.sdkPath)
          .equals(p.normalize(Directory(d.sandbox).absolute.path));
      check(sdk.dartExecutable).isNotNull();
    });

    test('environment map override probes DART_SDK and PATH', () async {
      await _createMockSdkInSandbox();

      final sdk = DartSdk(environment: {'DART_SDK': d.sandbox});
      check(sdk.sdkPath)
          .equals(p.normalize(Directory(d.sandbox).absolute.path));
    });

    test('findExecutable searches directories in PATH', () async {
      await d.file('custom_runner', '').create();
      final dummyExe = File(d.path('custom_runner'));

      final sdk = DartSdk(environment: {'PATH': d.sandbox});
      final found = sdk.findExecutable('custom_runner');
      check(found).equals(p.normalize(dummyExe.absolute.path));

      final notFound = sdk.findExecutable('non_existent_binary');
      check(notFound).isNull();
    });

    test('current environment resolves active Dart SDK', () {
      const sdk = DartSdk();
      check(sdk.dartExecutable).isNotNull();
      check(sdk.isRuntimeAvailable(TargetRuntime.jit)).isTrue();
      check(sdk.isRuntimeAvailable(TargetRuntime.aot)).isTrue();
    });

    test('customD8Path and customNodePath resolve when files exist', () async {
      await d.file('my_d8', '').create();
      await d.file('my_node', '').create();
      final d8File = File(d.path('my_d8'));
      final nodeFile = File(d.path('my_node'));

      final sdk = DartSdk(
        customD8Path: d8File.path,
        customNodePath: nodeFile.path,
        environment: {'PATH': ''},
      );

      check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
      check(sdk.nodeExecutable).equals(p.normalize(nodeFile.absolute.path));
      check(sdk.hasWasmRunner).isTrue();
      check(sdk.hasJsRunner).isTrue();
    });

    test(
      'customD8Path and customNodePath return null when file does not exist',
      () async {
        await d.dir('bin', [d.file('d8', ''), d.file('node', '')]).create();

        final sdk = DartSdk(
          customD8Path: d.path('ghost_d8'),
          customNodePath: d.path('ghost_node'),
          environment: {'PATH': d.path('bin')},
        );

        check(sdk.d8Executable).isNull();
        check(sdk.nodeExecutable).isNull();
        check(sdk.hasWasmRunner).isFalse();
        check(sdk.hasJsRunner).isFalse();
      },
    );

    test(
      'customD8Path and customNodePath take precedence over env and PATH',
      () async {
        await d.file('custom_d8', '').create();
        await d.file('env_d8', '').create();
        await d.file('custom_node', '').create();
        await d.file('env_node', '').create();
        await d.dir('path_bin', [
          d.file('d8', ''),
          d.file('node', ''),
        ]).create();

        final customD8 = File(d.path('custom_d8'));
        final customNode = File(d.path('custom_node'));

        final sdk = DartSdk(
          customD8Path: customD8.path,
          customNodePath: customNode.path,
          environment: {
            'D8_PATH': d.path('env_d8'),
            'NODE_PATH': d.path('env_node'),
            'PATH': d.path('path_bin'),
          },
        );

        check(sdk.d8Executable).equals(p.normalize(customD8.absolute.path));
        check(sdk.nodeExecutable).equals(p.normalize(customNode.absolute.path));
      },
    );

    test(
      'D8_PATH and NODE_PATH environment variables resolve when files exist',
      () async {
        await d.file('env_d8', '').create();
        await d.file('env_node', '').create();
        final d8File = File(d.path('env_d8'));
        final nodeFile = File(d.path('env_node'));

        final sdk = DartSdk(
          environment: {
            'D8_PATH': d8File.path,
            'NODE_PATH': nodeFile.path,
            'PATH': '',
          },
        );

        check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
        check(sdk.nodeExecutable).equals(p.normalize(nodeFile.absolute.path));
      },
    );

    test('D8_PATH and NODE_PATH fall back when files do not exist', () async {
      await d.dir('bin', [d.file('d8', ''), d.file('node', '')]).create();
      final pathD8 = File(d.path('bin/d8'));
      final pathNode = File(d.path('bin/node'));

      final sdk = DartSdk(
        environment: {
          'D8_PATH': d.path('nonexistent_d8'),
          'NODE_PATH': d.path('nonexistent_node'),
          'PATH': d.path('bin'),
        },
      );

      check(sdk.d8Executable).equals(p.normalize(pathD8.absolute.path));
      check(sdk.nodeExecutable).equals(p.normalize(pathNode.absolute.path));
    });

    test('auto-probes d8 at <sdkPath>/bin/resources/dart2wasm/d8', () async {
      await _createMockSdkInSandbox();
      final exeName = Platform.isWindows ? 'd8.exe' : 'd8';
      await d.dir('bin/resources/dart2wasm', [d.file(exeName, '')]).create();
      final d8File = File(d.path('bin/resources/dart2wasm/$exeName'));

      final sdk = DartSdk(customSdkPath: d.sandbox, environment: {'PATH': ''});

      check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
    });

    test('auto-probes d8 at <sdkPath>/out/ReleaseX64/d8', () async {
      await _createMockSdkInSandbox();
      final exeName = Platform.isWindows ? 'd8.exe' : 'd8';
      await d.dir('out/ReleaseX64', [d.file(exeName, '')]).create();
      final d8File = File(d.path('out/ReleaseX64/$exeName'));

      final sdk = DartSdk(customSdkPath: d.sandbox, environment: {'PATH': ''});

      check(sdk.d8Executable).equals(p.normalize(d8File.absolute.path));
    });
  });

  group('DartSdk Equality & HashCode', () {
    test(
      'instances with identical configuration are equal and share hashCode',
      () {
        const sdk1 = DartSdk();
        const sdk2 = DartSdk();
        check(sdk1 == sdk2).isTrue();
        check(sdk1.hashCode).equals(sdk2.hashCode);

        const custom1 = DartSdk(
          customSdkPath: '/sdk',
          customD8Path: '/d8',
          customNodePath: '/node',
          environment: {'KEY': 'val'},
        );
        const custom2 = DartSdk(
          customSdkPath: '/sdk',
          customD8Path: '/d8',
          customNodePath: '/node',
          environment: {'KEY': 'val'},
        );
        check(custom1 == custom2).isTrue();
        check(custom1.hashCode).equals(custom2.hashCode);
      },
    );

    test('instances with different properties are not equal', () {
      const base = DartSdk();
      check(base == base.copyWith(customSdkPath: '/other')).isFalse();
      check(base == base.copyWith(customD8Path: '/other_d8')).isFalse();
      check(base == base.copyWith(customNodePath: '/other_node')).isFalse();
      check(base == base.copyWith(environment: {'A': '1'})).isFalse();

      const env1 = DartSdk(environment: {'A': '1', 'B': '2'});
      const env2 = DartSdk(environment: {'A': '1', 'B': '3'});
      check(env1 == env2).isFalse();
    });
  });
}

Future<void> _createMockSdkInSandbox() async {
  await d.dir('bin', [d.file('dart', '')]).create();
  await d.file('version', '3.14.0\n').create();
}
