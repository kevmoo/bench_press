import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'sdk.dart';

/// The result of compiling a benchmark source file for a specific target.
final class const CompilationResult({
  /// Whether the compilation exited successfully with code 0.
  required final bool success,

  /// The target runtime compiled for.
  required final TargetRuntime runtime,

  /// The original Dart source file path.
  required final String sourcePath,

  /// The primary output binary or bytecode artifact path (e.g. `.exe`, `.wasm`,
  /// `.js`), or the source file path for JIT.
  final String? artifactPath,

  /// The runner script path (e.g. `.mjs` for Wasm, `.js` for JavaScript), or
  /// `null` if the artifact is directly executable.
  final String? runnerScriptPath,

  /// Total time spent compiling.
  required final Duration compilationDuration,

  /// Subprocess standard output stream from the compiler.
  required final String stdout,

  /// Subprocess standard error stream from the compiler.
  required final String stderr,

  /// Subprocess exit code.
  required final int exitCode,

  /// Whether this result was served from the compilation cache.
  final bool cacheHit = false,
}) {
  @override
  String toString() =>
      'CompilationResult($runtime, success: $success, '
      'artifact: $artifactPath, '
      'cacheHit: $cacheHit, '
      'duration: ${compilationDuration.inMilliseconds}ms)';
}

/// Orchestrates compilation of Dart benchmark source files into native, Wasm,
/// and JavaScript artifacts.
final class const TargetCompiler({final DartSdk sdk = const DartSdk()}) {
  /// Compiles [sourceFile] for [runtime] into [outputDir].
  ///
  /// For [TargetRuntime.jit], no compilation is performed and an immediate
  /// success [CompilationResult] pointing to [sourceFile] is returned.
  Future<CompilationResult> compile({
    required File sourceFile,
    required TargetRuntime runtime,
    Directory? outputDir,
    List<String> compilerFlags = const [],
    String? workingDirectory,
    bool useCache = true,
  }) async {
    final normalizedSource = p.normalize(sourceFile.absolute.path);

    if (runtime == TargetRuntime.jit) {
      return CompilationResult(
        success: true,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: normalizedSource,
        runnerScriptPath: null,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: '',
        exitCode: 0,
      );
    }

    final targetDir =
        outputDir ??
        Directory(p.join('.dart_tool', 'bench_press', 'build', runtime.name));
    await targetDir.create(recursive: true);

    final dartExe = sdk.dartExecutable;
    if (dartExe == null) {
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: 'Error: Dart SDK executable not found on PATH or DART_SDK.',
        exitCode: 1,
      );
    }

    final baseName = p.basenameWithoutExtension(sourceFile.path);
    final (args, artifactPath, runnerPath) = _buildCompilerArgs(
      runtime: runtime,
      sourcePath: normalizedSource,
      outputDir: targetDir.path,
      baseName: baseName,
      extraFlags: compilerFlags,
    );

    final expectedRunnerPath = _expectedRunnerPath(
      runtime: runtime,
      outputDir: targetDir.path,
      baseName: baseName,
      runnerPath: runnerPath,
    );

    final cacheKey = _computeCacheKey(
      sourceFile: sourceFile,
      runtime: runtime,
      compilerFlags: compilerFlags,
      dartExe: dartExe,
      workingDirectory: workingDirectory,
    );
    final cacheDir = Directory(
      p.join(
        '.dart_tool',
        'bench_press',
        'cache',
        runtime.name,
        '${baseName}_$cacheKey',
      ),
    );

    if (useCache) {
      final cachedResult = _tryRestoreFromCache(
        cacheDir: cacheDir,
        targetDir: targetDir,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: artifactPath,
        runnerPath: runnerPath,
        runnerScriptPath: expectedRunnerPath,
      );
      if (cachedResult != null) {
        _writeRunnerIfNeeded(
          runtime: runtime,
          outputDir: targetDir.path,
          baseName: baseName,
          runnerPath: runnerPath,
        );
        return cachedResult;
      }
    }

    final stopwatch = Stopwatch()..start();
    try {
      final processResult = await Process.run(
        dartExe,
        args,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();

      final success = processResult.exitCode == 0;
      if (success) {
        _writeRunnerIfNeeded(
          runtime: runtime,
          outputDir: targetDir.path,
          baseName: baseName,
          runnerPath: runnerPath,
        );
        _saveToCache(
          targetDir: targetDir,
          cacheDir: cacheDir,
          baseName: baseName,
        );
      }

      return CompilationResult(
        success: success,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: success ? artifactPath : null,
        runnerScriptPath: success ? expectedRunnerPath : null,
        compilationDuration: stopwatch.elapsed,
        stdout: processResult.stdout.toString(),
        stderr: processResult.stderr.toString(),
        exitCode: processResult.exitCode,
      );
    } on Object catch (e) {
      stopwatch.stop();
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: stopwatch.elapsed,
        stdout: '',
        stderr: 'Compiler execution failed: $e',
        exitCode: 1,
      );
    }
  }

  String? _expectedRunnerPath({
    required TargetRuntime runtime,
    required String outputDir,
    required String baseName,
    required String? runnerPath,
  }) => switch (runtime) {
    TargetRuntime.wasm => p.normalize(p.join(outputDir, '$baseName.run.mjs')),
    TargetRuntime.js => p.normalize(p.join(outputDir, '$baseName.node.cjs')),
    _ => runnerPath,
  };

  void _writeRunnerIfNeeded({
    required TargetRuntime runtime,
    required String outputDir,
    required String baseName,
    required String? runnerPath,
  }) {
    if (runtime == TargetRuntime.wasm) {
      _writeWasmRunner(
        outputDir: outputDir,
        baseName: baseName,
        loaderPath: runnerPath!,
      );
    } else if (runtime == TargetRuntime.js) {
      _writeJsRunner(
        outputDir: outputDir,
        baseName: baseName,
        compiledPath: runnerPath!,
      );
    }
  }

  CompilationResult? _tryRestoreFromCache({
    required Directory cacheDir,
    required Directory targetDir,
    required TargetRuntime runtime,
    required String sourcePath,
    required String artifactPath,
    required String? runnerPath,
    required String? runnerScriptPath,
  }) {
    if (!cacheDir.existsSync()) return null;
    final cachedArtifact = File(
      p.join(cacheDir.path, p.basename(artifactPath)),
    );
    if (!cachedArtifact.existsSync()) return null;
    if (runnerPath != null) {
      final cachedLoader = File(p.join(cacheDir.path, p.basename(runnerPath)));
      if (!cachedLoader.existsSync()) return null;
    }

    for (final entity in cacheDir.listSync().whereType<File>()) {
      entity.copySync(p.join(targetDir.path, p.basename(entity.path)));
    }

    return CompilationResult(
      success: true,
      runtime: runtime,
      sourcePath: sourcePath,
      artifactPath: artifactPath,
      runnerScriptPath: runnerScriptPath,
      compilationDuration: Duration.zero,
      stdout: '',
      stderr: '',
      exitCode: 0,
      cacheHit: true,
    );
  }

  void _saveToCache({
    required Directory targetDir,
    required Directory cacheDir,
    required String baseName,
  }) {
    if (cacheDir.existsSync()) {
      cacheDir.deleteSync(recursive: true);
    }
    cacheDir.createSync(recursive: true);
    for (final entity in targetDir.listSync().whereType<File>()) {
      final fileName = p.basename(entity.path);
      if (fileName == baseName || fileName.startsWith('$baseName.')) {
        entity.copySync(p.join(cacheDir.path, fileName));
      }
    }
  }

  String _computeCacheKey({
    required File sourceFile,
    required TargetRuntime runtime,
    required List<String> compilerFlags,
    required String dartExe,
    String? workingDirectory,
  }) {
    final builder = BytesBuilder(copy: false);
    void addString(String value) {
      builder
        ..add(utf8.encode(value))
        ..addByte(0);
    }

    addString(runtime.name);
    addString(dartExe);
    try {
      final stat = File(dartExe).statSync();
      addString('${stat.modified.millisecondsSinceEpoch}:${stat.size}');
    } on FileSystemException {
      // Ignore stat errors for mock or non-existent binaries.
    }
    for (final flag in compilerFlags) {
      addString(flag);
    }

    final baseDir = workingDirectory ?? Directory.current.path;
    final pkgConfigPath =
        sdk.packageConfigPath ??
        p.join(baseDir, '.dart_tool', 'package_config.json');
    final pkgConfigFile = File(pkgConfigPath);
    if (pkgConfigFile.existsSync()) {
      builder.add(pkgConfigFile.readAsBytesSync());
    }

    final dartFiles = <String, File>{
      p.normalize(sourceFile.absolute.path): sourceFile,
    };
    _collectDartFiles(Directory(p.join(baseDir, 'lib')), dartFiles);
    _collectDartFiles(sourceFile.parent, dartFiles);

    final sortedPaths = dartFiles.keys.toList()..sort();
    for (final path in sortedPaths) {
      addString(path);
      final file = dartFiles[path]!;
      if (file.existsSync()) {
        builder.add(file.readAsBytesSync());
      }
    }

    return sha256.convert(builder.takeBytes()).toString();
  }

  void _collectDartFiles(Directory dir, Map<String, File> out) {
    if (!dir.existsSync()) return;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          out[p.normalize(entity.absolute.path)] = entity;
        }
      }
    } on FileSystemException {
      // Ignore inaccessible directories.
    }
  }

  /// `dart compile wasm` emits a bare loader module (`compile`/
  /// `compileStreaming` exports) — running it directly with Node does
  /// nothing, since nothing in it calls `instantiate`/`invokeMain`. Node.js
  /// benchmarks need that boilerplate wired up explicitly, so this writes a
  /// small `.run.mjs` next to the loader that does the compile → instantiate
  /// → invokeMain dance and forwards CLI args, and returns its path for use
  /// as the actual runner script.
  String _writeWasmRunner({
    required String outputDir,
    required String baseName,
    required String loaderPath,
  }) {
    final wasmFileName = '$baseName.wasm';
    final loaderFileName = p.basename(loaderPath);
    final runnerPath = p.normalize(p.join(outputDir, '$baseName.run.mjs'));
    final encodedLoaderFile = jsonEncode(loaderFileName);
    final encodedWasmFile = jsonEncode(wasmFileName);
    File(runnerPath).writeAsStringSync('''
import { readFile } from 'node:fs/promises';

process.on('unhandledRejection', (err) => {
  console.error(err);
  process.exit(1);
});

try {
  const init = await import(new URL($encodedLoaderFile, import.meta.url).href);
  const bytes = await readFile(new URL($encodedWasmFile, import.meta.url));
  const compiledApp = await init.compile(bytes);
  const instantiatedApp = await compiledApp.instantiate({});
  await instantiatedApp.invokeMain(...process.argv.slice(2));
} catch (err) {
  console.error(err);
  process.exit(1);
}
''');
    return runnerPath;
  }

  /// `dart compile js` output assumes a browser (or worker) global scope and
  /// feature-detects microtask/timer scheduling off the bare `self` global —
  /// present in browsers/workers, absent in Node.js. Any benchmark that
  /// genuinely suspends on `await` (not just trampolines through synchronous
  /// work) hits that scheduler, throws `ReferenceError: self is not
  /// defined,` and the resulting rejected Future is dropped silently (no
  /// crash, no telemetry).
  ///
  /// Separately, the compiled output invokes `main` with a *hardcoded empty
  /// arguments array* (`dartMainRunner(s,[])`) — CLI args like `--target js`
  /// or `--trials N` never reach Dart's `main(args)` no matter what's passed
  /// on the command line. `dartMainRunner` is dart2js's documented embedder
  /// hook for exactly this: if defined as a global before the compiled
  /// script runs, dart2js calls it instead of invoking `main` directly,
  /// letting us supply the real args ourselves.
  ///
  /// This writes a `.node.cjs` wrapper next to the compiled output that
  /// polyfills `self`, defines `dartMainRunner` to forward `process.argv`,
  /// and requires the compiled artifact — and returns its path for use as
  /// the actual runner script. `.node.cjs` is used instead of `.node.js` so
  /// Node.js treats the script unconditionally as CommonJS, even inside
  /// packages configured with `"type": "module"`.
  String _writeJsRunner({
    required String outputDir,
    required String baseName,
    required String compiledPath,
  }) {
    final compiledFileName = p.basename(compiledPath);
    final runnerPath = p.normalize(p.join(outputDir, '$baseName.node.cjs'));
    final encodedCompiledFile = jsonEncode('./$compiledFileName');
    File(runnerPath).writeAsStringSync('''
process.on('unhandledRejection', (err) => {
  console.error(err);
  process.exit(1);
});

if (typeof self === 'undefined') {
  globalThis.self = globalThis;
}
globalThis.dartMainRunner = (main, _ignoredArgs) => {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
};
require($encodedCompiledFile);
''');
    return runnerPath;
  }

  (List<String> args, String artifactPath, String? runnerPath)
  _buildCompilerArgs({
    required TargetRuntime runtime,
    required String sourcePath,
    required String outputDir,
    required String baseName,
    required List<String> extraFlags,
  }) {
    final pkgConfig = sdk.packageConfigPath;
    final pkgFlag = pkgConfig != null ? ['--packages=$pkgConfig'] : <String>[];

    switch (runtime) {
      case TargetRuntime.jit:
        return (<String>[], sourcePath, null);

      case TargetRuntime.aot:
        final exeExt = Platform.isWindows ? '.exe' : '';
        final outPath = p.normalize(p.join(outputDir, '$baseName$exeExt'));
        final args = <String>[
          'compile',
          'exe',
          ...pkgFlag,
          ...extraFlags,
          sourcePath,
          '-o',
          outPath,
        ];
        return (args, outPath, null);

      case TargetRuntime.wasm:
        final wasmPath = p.normalize(p.join(outputDir, '$baseName.wasm'));
        final mjsPath = p.normalize(p.join(outputDir, '$baseName.mjs'));
        final args = <String>[
          'compile',
          'wasm',
          ...pkgFlag,
          ...extraFlags,
          sourcePath,
          '-o',
          wasmPath,
        ];
        return (args, wasmPath, mjsPath);

      case TargetRuntime.js:
        final jsPath = p.normalize(p.join(outputDir, '$baseName.js'));
        final args = <String>[
          'compile',
          'js',
          ...pkgFlag,
          '-O4',
          ...extraFlags,
          sourcePath,
          '-o',
          jsPath,
        ];
        return (args, jsPath, jsPath);
    }
  }
}
