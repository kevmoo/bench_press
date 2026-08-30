import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../telemetry/schema.dart';
import 'compiler.dart';
import 'sdk.dart';
import 'suite_runner.dart';

/// The result of executing a benchmark target in a subprocess or isolate.
final class ProcessExecutionResult {
  /// Whether the process/isolate executed and returned valid telemetry.
  final bool success;

  /// The target runtime executed.
  final TargetRuntime runtime;

  /// Process exit code (0 for success).
  final int exitCode;

  /// Parsed telemetry suite result, or `null` if execution failed.
  final BenchmarkSuiteResult? suiteResult;

  /// Execution duration.
  final Duration executionDuration;

  /// Subprocess standard output stream.
  final String stdout;

  /// Subprocess standard error stream.
  final String stderr;

  /// Optional error or failure diagnostic message.
  final String? errorMessage;

  const ProcessExecutionResult({
    required this.success,
    required this.runtime,
    required this.exitCode,
    this.suiteResult,
    required this.executionDuration,
    required this.stdout,
    required this.stderr,
    this.errorMessage,
  });

  @override
  String toString() =>
      'ProcessExecutionResult($runtime, success: $success, '
      'benchmarks: ${suiteResult?.benchmarks.length ?? 0}, '
      'duration: ${executionDuration.inMilliseconds}ms)';
}

/// Spawns and supervises benchmark target subprocesses across VM JIT, AOT,
/// Node.js, and D8, streaming telemetry back to the orchestrator.
final class BenchmarkProcessRunner {
  final DartSdk sdk;

  const BenchmarkProcessRunner({this.sdk = const DartSdk()});

  /// Executes a compiled or JIT benchmark [compilationResult].
  Future<ProcessExecutionResult> execute({
    required CompilationResult compilationResult,
    bool isolateMode = false,
    int? trials,
    bool forceRun = false,
    bool validate = false,
    List<String> vmFlags = const [],
    String? workingDirectory,
  }) async {
    final runtime = compilationResult.runtime;
    final artifactPath = compilationResult.artifactPath;
    final runnerScriptPath = compilationResult.runnerScriptPath;

    if (!compilationResult.success || artifactPath == null) {
      return ProcessExecutionResult(
        success: false,
        runtime: runtime,
        exitCode: compilationResult.exitCode,
        executionDuration: Duration.zero,
        stdout: compilationResult.stdout,
        stderr: compilationResult.stderr,
        errorMessage: 'Cannot execute uncompiled or failed target.',
      );
    }

    final tempDir = Directory.systemTemp.createTempSync('bench_press_exec_');
    final tempJsonFile = File(p.join(tempDir.path, 'telemetry.json'));

    final benchArgs = <String>[
      '--json-output',
      tempJsonFile.path,
      '--target',
      runtime.name,
      if (trials != null) ...['--trials', '$trials'],
      if (forceRun) '--force-run',
      if (validate) '--validate',
    ];

    final stopwatch = Stopwatch()..start();
    try {
      if (runtime == TargetRuntime.jit && isolateMode) {
        return await _executeIsolate(
          scriptPath: artifactPath,
          args: benchArgs,
          runtime: runtime,
          tempJsonFile: tempJsonFile,
          stopwatch: stopwatch,
        );
      }

      final (executable, processArgs) = _resolveExecutionCommand(
        runtime: runtime,
        artifactPath: artifactPath,
        runnerScriptPath: runnerScriptPath,
        vmFlags: vmFlags,
        benchArgs: benchArgs,
      );

      final processResult = await Process.run(
        executable,
        processArgs,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();

      return _processExecutionOutput(
        runtime: runtime,
        processResult: processResult,
        tempJsonFile: tempJsonFile,
        duration: stopwatch.elapsed,
      );
    } on Object catch (e) {
      stopwatch.stop();
      return ProcessExecutionResult(
        success: false,
        runtime: runtime,
        exitCode: 1,
        executionDuration: stopwatch.elapsed,
        stdout: '',
        stderr: 'Execution exception: $e',
        errorMessage: e.toString(),
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } on Object {
        // Ignore temp cleanup errors
      }
    }
  }

  (String executable, List<String> processArgs) _resolveExecutionCommand({
    required TargetRuntime runtime,
    required String artifactPath,
    required String? runnerScriptPath,
    required List<String> vmFlags,
    required List<String> benchArgs,
  }) {
    switch (runtime) {
      case TargetRuntime.jit:
        final dartExe = sdk.dartExecutable ?? 'dart';
        final pkgConfig = sdk.packageConfigPath;
        final args = <String>[
          'run',
          if (pkgConfig != null) '--packages=$pkgConfig',
          ...vmFlags,
          artifactPath,
          ...benchArgs,
        ];
        return (dartExe, args);

      case TargetRuntime.aot:
        return (artifactPath, benchArgs);

      case TargetRuntime.wasm:
        final script = runnerScriptPath ?? artifactPath;
        if (sdk.nodeExecutable != null) {
          final args = <String>[
            '--experimental-wasm-gc',
            ...vmFlags,
            script,
            ...benchArgs,
          ];
          return (sdk.nodeExecutable!, args);
        } else if (sdk.d8Executable != null) {
          final args = <String>[
            '--experimental-wasm-gc',
            ...vmFlags,
            script,
            '--',
            ...benchArgs,
          ];
          return (sdk.d8Executable!, args);
        }
        throw StateError('No Wasm runner (Node.js or D8) found on PATH.');

      case TargetRuntime.js:
        final script = runnerScriptPath ?? artifactPath;
        if (sdk.nodeExecutable != null) {
          final args = <String>[...vmFlags, script, ...benchArgs];
          return (sdk.nodeExecutable!, args);
        } else if (sdk.d8Executable != null) {
          final args = <String>[...vmFlags, script, '--', ...benchArgs];
          return (sdk.d8Executable!, args);
        }
        throw StateError('No JavaScript runner (Node.js or D8) found on PATH.');
    }
  }

  Future<ProcessExecutionResult> _executeIsolate({
    required String scriptPath,
    required List<String> args,
    required TargetRuntime runtime,
    required File tempJsonFile,
    required Stopwatch stopwatch,
  }) async {
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();

    try {
      final uri = Uri.file(p.normalize(p.absolute(scriptPath)));
      final pkgConfig = sdk.packageConfigPath;
      final packageConfigUri = pkgConfig != null ? Uri.file(pkgConfig) : null;

      final isolate = await Isolate.spawnUri(
        uri,
        args,
        null,
        packageConfig: packageConfigUri,
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
      );

      final errorCompleter = Completer<Object?>();
      errorPort.listen((message) {
        if (!errorCompleter.isCompleted) {
          errorCompleter.complete(message);
        }
      });

      try {
        await Future.any([exitPort.first, errorCompleter.future]);
      } finally {
        isolate.kill(priority: Isolate.immediate);
      }
      stopwatch.stop();

      BenchmarkSuiteResult? suite;
      if (tempJsonFile.existsSync()) {
        try {
          suite = BenchmarkSuiteResult.loadFromFile(tempJsonFile);
        } on Object {
          suite = null;
        }
      }

      final success = suite != null;
      return ProcessExecutionResult(
        success: success,
        runtime: runtime,
        exitCode: success ? 0 : 1,
        suiteResult: suite,
        executionDuration: stopwatch.elapsed,
        stdout: '',
        stderr: '',
        errorMessage: success ? null : 'Failed to collect isolate telemetry.',
      );
    } on Object catch (e) {
      stopwatch.stop();
      return ProcessExecutionResult(
        success: false,
        runtime: runtime,
        exitCode: 1,
        executionDuration: stopwatch.elapsed,
        stdout: '',
        stderr: 'Isolate execution failed: $e',
        errorMessage: e.toString(),
      );
    } finally {
      exitPort.close();
      errorPort.close();
    }
  }

  ProcessExecutionResult _processExecutionOutput({
    required TargetRuntime runtime,
    required ProcessResult processResult,
    required File tempJsonFile,
    required Duration duration,
  }) {
    final stdoutStr = processResult.stdout.toString();
    final stderrStr = processResult.stderr.toString();
    final exitCode = processResult.exitCode;
    final suite = _extractSuiteResult(tempJsonFile, stdoutStr);
    final success = exitCode == 0 && suite != null;
    final errorMsg = _resolveErrorMessage(success, exitCode, stderrStr);

    return ProcessExecutionResult(
      success: success,
      runtime: runtime,
      exitCode: exitCode,
      suiteResult: suite,
      executionDuration: duration,
      stdout: stdoutStr,
      stderr: stderrStr,
      errorMessage: errorMsg,
    );
  }

  BenchmarkSuiteResult? _extractSuiteResult(
    File tempJsonFile,
    String stdoutStr,
  ) {
    if (tempJsonFile.existsSync() && tempJsonFile.lengthSync() > 0) {
      try {
        return BenchmarkSuiteResult.loadFromFile(tempJsonFile);
      } on Object {
        // Fall back to stdout parsing
      }
    }

    final jsonExtracted = extractJsonFromStdout(stdoutStr);
    if (jsonExtracted != null) {
      try {
        return BenchmarkSuiteResult.fromJsonString(jsonExtracted);
      } on Object {
        return null;
      }
    }
    return null;
  }

  String? _resolveErrorMessage(bool success, int exitCode, String stderrStr) {
    if (success) return null;
    if (stderrStr.isNotEmpty) return stderrStr.trim();
    if (exitCode != 0) return 'Subprocess exited with code $exitCode';
    return 'Failed to extract benchmark telemetry from output';
  }
}
