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
      return CompilationResult(
        success: success,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: success ? artifactPath : null,
        runnerScriptPath: success ? runnerPath : null,
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
          '--omit-type-checks',
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
