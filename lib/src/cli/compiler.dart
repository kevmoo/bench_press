import 'dart:io';

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
}) {
  @override
  String toString() =>
      'CompilationResult($runtime, success: $success, '
      'artifact: $artifactPath, '
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

    final stopwatch = Stopwatch()..start();
    try {
      final processResult = await Process.run(
        dartExe,
        args,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();

      final success = processResult.exitCode == 0;
      final resolvedRunnerPath = !success
          ? runnerPath
          : switch (runtime) {
              TargetRuntime.wasm => _writeWasmRunner(
                outputDir: targetDir.path,
                baseName: baseName,
                loaderPath: runnerPath!,
              ),
              TargetRuntime.js => _writeJsRunner(
                outputDir: targetDir.path,
                baseName: baseName,
                compiledPath: runnerPath!,
              ),
              _ => runnerPath,
            };
      return CompilationResult(
        success: success,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: success ? artifactPath : null,
        runnerScriptPath: success ? resolvedRunnerPath : null,
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
    File(runnerPath).writeAsStringSync('''
import { readFile } from 'node:fs/promises';

const init = await import(new URL('$loaderFileName', import.meta.url).href);
const bytes = await readFile(new URL('$wasmFileName', import.meta.url));
const compiledApp = await init.compile(bytes);
const instantiatedApp = await compiledApp.instantiate({});
instantiatedApp.invokeMain(...process.argv.slice(2));
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
  /// This writes a `.node.js` wrapper next to the compiled output that
  /// polyfills `self`, defines `dartMainRunner` to forward `process.argv`,
  /// and requires the compiled artifact — and returns its path for use as
  /// the actual runner script.
  String _writeJsRunner({
    required String outputDir,
    required String baseName,
    required String compiledPath,
  }) {
    final compiledFileName = p.basename(compiledPath);
    final runnerPath = p.normalize(p.join(outputDir, '$baseName.node.js'));
    File(runnerPath).writeAsStringSync('''
if (typeof self === 'undefined') {
  globalThis.self = globalThis;
}
globalThis.dartMainRunner = (main, _ignoredArgs) => {
  main(process.argv.slice(2));
};
require('./$compiledFileName');
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
