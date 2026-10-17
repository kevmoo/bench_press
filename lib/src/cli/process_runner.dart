import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../telemetry/schema.dart';
import 'compiler.dart';
import 'cpu_affinity.dart';
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
  final CpuAffinity? cpuAffinity,
}) {
  /// Executes a compiled or JIT benchmark [compilationResult].
  ///
  /// When [processes] > 1 (and [validate] is false), executes the
  /// already-compiled artifact `P =` [processes] independent times without
  /// recompiling and aggregates the per-process telemetry using hierarchical
  /// process-mean aggregation. (`RunCommand` coordinates multi-process rounds
  /// externally so process launches interleave across matrix coordinates in
  /// `ABBA BAAB` order, while `processes > 1` here is a sequential helper for
  /// single-target callers.)
  Future<ProcessExecutionResult> execute({
    required CompilationResult compilationResult,
    bool isolateMode = false,
    int? trials,
    int? maxTrials,
    int processes = 1,
    bool forceRun = false,
    bool validate = false,
    List<String> vmFlags = const [],
    CpuAffinity? cpuAffinity,
    String? workingDirectory,
  }) async {
    if (processes < 1) {
      throw ArgumentError.value(processes, 'processes', 'Must be >= 1.');
    }
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

    final effectiveProcesses = validate ? 1 : processes;
    final tempDir = Directory.systemTemp.createTempSync('bench_press_exec_');

    try {
      if (effectiveProcesses == 1) {
        final tempJsonFile = File(p.join(tempDir.path, 'telemetry.json'));
        return await _executeSingleProcess(
          runtime: runtime,
          artifactPath: artifactPath,
          runnerScriptPath: runnerScriptPath,
          tempJsonFile: tempJsonFile,
          isolateMode: isolateMode,
          trials: trials,
          maxTrials: maxTrials,
          forceRun: forceRun,
          validate: validate,
          vmFlags: vmFlags,
          cpuAffinity: cpuAffinity,
          workingDirectory: workingDirectory,
        );
      }

      return await _executeMultipleProcesses(
        processes: effectiveProcesses,
        tempDir: tempDir,
        runtime: runtime,
        artifactPath: artifactPath,
        runnerScriptPath: runnerScriptPath,
        isolateMode: isolateMode,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        vmFlags: vmFlags,
        cpuAffinity: cpuAffinity,
        workingDirectory: workingDirectory,
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } on Object {
        // Ignore temp cleanup errors
      }
    }
  }

  Future<ProcessExecutionResult> _executeMultipleProcesses({
    required int processes,
    required Directory tempDir,
    required TargetRuntime runtime,
    required String artifactPath,
    required String? runnerScriptPath,
    required bool isolateMode,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required List<String> vmFlags,
    required CpuAffinity? cpuAffinity,
    required String? workingDirectory,
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final processSuites = <BenchmarkSuiteResult>[];
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    for (var procIdx = 0; procIdx < processes; procIdx++) {
      final tempJsonFile = File(
        p.join(tempDir.path, 'telemetry_process_$procIdx.json'),
      );
      final procResult = await _executeSingleProcess(
        runtime: runtime,
        artifactPath: artifactPath,
        runnerScriptPath: runnerScriptPath,
        tempJsonFile: tempJsonFile,
        isolateMode: isolateMode,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        validate: false,
        vmFlags: vmFlags,
        cpuAffinity: cpuAffinity,
        workingDirectory: workingDirectory,
      );
      if (procResult.stdout.isNotEmpty) stdoutBuf.write(procResult.stdout);
      if (procResult.stderr.isNotEmpty) stderrBuf.write(procResult.stderr);

      if (!procResult.success || procResult.suiteResult == null) {
        totalStopwatch.stop();
        return ProcessExecutionResult(
          success: false,
          runtime: runtime,
          exitCode: procResult.exitCode == 0 ? 1 : procResult.exitCode,
          executionDuration: totalStopwatch.elapsed,
          stdout: stdoutBuf.toString(),
          stderr: stderrBuf.toString(),
          errorMessage: procResult.errorMessage,
        );
      }
      processSuites.add(procResult.suiteResult!);
    }
    totalStopwatch.stop();

    final aggregated = BenchmarkSuiteResult.aggregateProcesses(processSuites);
    return ProcessExecutionResult(
      success: true,
      runtime: runtime,
      exitCode: 0,
      suiteResult: aggregated,
      executionDuration: totalStopwatch.elapsed,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  Future<ProcessExecutionResult> _executeSingleProcess({
    required TargetRuntime runtime,
    required String artifactPath,
    required String? runnerScriptPath,
    required File tempJsonFile,
    required bool isolateMode,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required bool validate,
    required List<String> vmFlags,
    required CpuAffinity? cpuAffinity,
    required String? workingDirectory,
  }) async {
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

      final (String commandExe, List<String> commandArgs) = switch (runtime) {
        TargetRuntime.jit => (
          sdk.dartExecutable ??
              (throw StateError(
                sdk.explicitSdkError ??
                    'Dart SDK executable not found on PATH or DART_SDK.',
              )),
          <String>[
            'run',
            if (sdk.packageConfigPath case final pkgConfig?)
              '--packages=$pkgConfig',
            ...vmFlags,
            artifactPath,
            ...benchArgs,
          ],
        ),
        TargetRuntime.aot => (artifactPath, benchArgs),
        TargetRuntime.wasm => _resolveWasmCommand(
          artifactPath: artifactPath,
          runnerScriptPath: runnerScriptPath,
          vmFlags: vmFlags,
          benchArgs: benchArgs,
        ),
        TargetRuntime.js => _resolveJsCommand(
          artifactPath: artifactPath,
          runnerScriptPath: runnerScriptPath,
          vmFlags: vmFlags,
          benchArgs: benchArgs,
        ),
      };

      // Pinning wraps the fully resolved command, so it applies identically to
      // the Dart VM, an AOT executable, Node.js, and D8.
      final effectiveAffinity = cpuAffinity ?? this.cpuAffinity;
      final (executable, processArgs) =
          effectiveAffinity?.wrap(commandExe, commandArgs) ??
          (commandExe, commandArgs);

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
