import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../telemetry/schema.dart';
import 'compiler.dart';
import 'sdk.dart';
import 'suite_runner.dart';

/// The result of executing a benchmark target in a subprocess or isolate.
final class const ProcessExecutionResult({
  /// Whether the process/isolate executed and returned valid telemetry.
  required final bool success,

  /// The target runtime executed.
  required final TargetRuntime runtime,

  /// Process exit code (0 for success).
  required final int exitCode,

  /// Parsed telemetry suite result, or `null` if execution failed.
  final BenchmarkSuiteResult? suiteResult,

  /// Execution duration.
  required final Duration executionDuration,

  /// Subprocess standard output stream.
  required final String stdout,

  /// Subprocess standard error stream.
  required final String stderr,

  /// Optional error or failure diagnostic message.
  final String? errorMessage,
}) {
  @override
  String toString() =>
      'ProcessExecutionResult($runtime, success: $success, '
      'benchmarks: ${suiteResult?.benchmarks.length ?? 0}, '
      'duration: ${executionDuration.inMilliseconds}ms)';
}

/// Spawns and supervises benchmark target subprocesses across VM JIT, AOT,
/// Node.js, and D8, streaming telemetry back to the orchestrator.
final class const BenchmarkProcessRunner({
  final DartSdk sdk = const DartSdk(),
}) {
  /// Executes a compiled or JIT benchmark [compilationResult].
  Future<ProcessExecutionResult> execute({
    required CompilationResult compilationResult,
    bool isolateMode = false,
    int? trials,
    int? maxTrials,
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
      if (maxTrials != null) ...['--max-trials', '$maxTrials'],
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
        return _resolveWasmCommand(
          artifactPath: artifactPath,
          runnerScriptPath: runnerScriptPath,
          vmFlags: vmFlags,
          benchArgs: benchArgs,
        );

      case TargetRuntime.js:
        return _resolveJsCommand(
          artifactPath: artifactPath,
          runnerScriptPath: runnerScriptPath,
          vmFlags: vmFlags,
          benchArgs: benchArgs,
        );
    }
  }

  (String executable, List<String> processArgs) _resolveWasmCommand({
    required String artifactPath,
    required String? runnerScriptPath,
    required List<String> vmFlags,
    required List<String> benchArgs,
  }) {
    final useD8 =
        sdk.d8Executable != null && (_preferD8 || sdk.nodeExecutable == null);
    if (useD8) {
      final d8Script = p.setExtension(artifactPath, '.mjs');
      final script = File(d8Script).existsSync() ? d8Script : artifactPath;
      final args = <String>[
        '--experimental-wasm-gc',
        ...vmFlags,
        script,
        '--',
        ...benchArgs,
      ];
      return (sdk.d8Executable!, args);
    } else if (sdk.nodeExecutable != null) {
      final script = runnerScriptPath ?? artifactPath;
      final args = <String>[...vmFlags, script, ...benchArgs];
      return (sdk.nodeExecutable!, args);
    }
    throw StateError('No Wasm runner (Node.js or D8) found on PATH.');
  }

  (String executable, List<String> processArgs) _resolveJsCommand({
    required String artifactPath,
    required String? runnerScriptPath,
    required List<String> vmFlags,
    required List<String> benchArgs,
  }) {
    final useD8 =
        sdk.d8Executable != null && (_preferD8 || sdk.nodeExecutable == null);
    if (useD8) {
      final args = <String>[...vmFlags, artifactPath, '--', ...benchArgs];
      return (sdk.d8Executable!, args);
    } else if (sdk.nodeExecutable != null) {
      final script = runnerScriptPath ?? artifactPath;
      final args = <String>[...vmFlags, script, ...benchArgs];
      return (sdk.nodeExecutable!, args);
    }
    throw StateError('No JavaScript runner (Node.js or D8) found on PATH.');
  }

  bool get _preferD8 => sdk.customD8Path != null && sdk.customNodePath == null;

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
        // Drain any queued isolate error port messages before inspecting
        // errorCompleter.
        await Future<void>.delayed(Duration.zero);
      } finally {
        isolate.kill(priority: Isolate.immediate);
      }
      stopwatch.stop();

      final isolateErrorStr = errorCompleter.isCompleted
          ? _formatIsolateError(await errorCompleter.future)
          : null;
      final suite = _loadSuiteResultSafe(tempJsonFile);
      final success = suite != null && isolateErrorStr == null;

      return ProcessExecutionResult(
        success: success,
        runtime: runtime,
        exitCode: success ? 0 : 1,
        suiteResult: suite,
        executionDuration: stopwatch.elapsed,
        stdout: '',
        stderr: isolateErrorStr ?? '',
        errorMessage:
            isolateErrorStr ??
            (success ? null : 'Failed to collect isolate telemetry.'),
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

  static String _formatIsolateError(Object? err) {
    if (err is List && err.isNotEmpty) {
      final exceptionStr = err[0]?.toString() ?? 'Unknown exception';
      final stackStr = err.length > 1 ? err[1]?.toString() : null;
      return stackStr != null && stackStr.isNotEmpty
          ? 'Unhandled isolate exception: $exceptionStr\n$stackStr'
          : 'Unhandled isolate exception: $exceptionStr';
    }
    return 'Unhandled isolate exception: $err';
  }

  static BenchmarkSuiteResult? _loadSuiteResultSafe(File tempJsonFile) {
    if (!tempJsonFile.existsSync()) return null;
    try {
      return BenchmarkSuiteResult.loadFromFile(tempJsonFile);
    } on Object {
      return null;
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
