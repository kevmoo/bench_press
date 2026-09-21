import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../config/bench_press_config.dart';
import '../config/validator.dart';
import '../telemetry/git_diff.dart';
import '../telemetry/markdown_reporter.dart';
import '../telemetry/schema.dart';
import 'compiler.dart';
import 'discovery.dart';
import 'process_runner.dart';
import 'sdk.dart';

/// The `run` subcommand orchestrating multi-runtime benchmark execution.
final class RunCommand({
  required final DartSdk sdk,
  required final TargetCompiler compiler,
  required final BenchmarkProcessRunner processRunner,
}) extends Command<int> {
  @override
  String get name => 'run';

  @override
  String get description =>
      'Run benchmarks across one or more target runtimes (JIT, AOT, Wasm, JS).';

  this {
    argParser
      ..addFlag(
        'gate',
        defaultsTo: true,
        help:
            'Withhold speedup ratios whose confidence interval is unbounded '
            'or whose samples are not robustly stable. Pass --no-gate to '
            'publish them anyway (exploration only).',
      )
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Path to bench_press.yaml configuration file.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the resolved Cartesian matrix execution plan and exit.',
      )
      ..addMultiOption(
        'target',
        abbr: 't',
        defaultsTo: ['jit'],
        help: 'Target runtime(s) to compile and run (jit, aot, wasm, js, all).',
      )
      ..addOption(
        'output',
        abbr: 'o',
        defaultsTo: defaultTelemetryFileName,
        help: 'File path to save/merge benchmark suite results JSON.',
      )
      ..addOption(
        'save',
        abbr: 's',
        help: 'File path to save/merge benchmark suite results JSON.',
      )
      ..addFlag(
        'no-save',
        negatable: false,
        help: 'Do not save/merge JSON results to disk.',
      )
      ..addOption(
        'trials',
        help: 'Number of measurement trials per benchmark (default: 15).',
      )
      ..addOption(
        'max-trials',
        help:
            'Maximum measurement trials ceiling for adaptive scaling '
            '(scales up if variance/outliers detected).',
      )
      ..addFlag(
        'force-run',
        negatable: false,
        help:
            'Bypass calibration safety aborts on zero-elapsed-time timer '
            'quantization.',
      )
      ..addFlag(
        'isolate-mode',
        negatable: false,
        help: 'Execute JIT benchmarks within spawned Dart isolates.',
      )
      ..addOption(
        'diff',
        help:
            'Baseline JSON file path OR Git ref (e.g. HEAD~1, main) to diff '
            'results against.',
      )
      ..addFlag(
        'fail-on-unstable',
        negatable: false,
        help: 'Exit with non-zero code if any benchmark fails steady-state.',
      )
      ..addMultiOption(
        'compiler-flag',
        help: 'Extra flags forwarded directly to dart compile.',
      )
      ..addMultiOption(
        'vm-flag',
        help: 'Extra flags forwarded to Dart VM or Node/D8 runner.',
      )
      ..addOption(
        'format',
        defaultsTo: 'markdown',
        allowed: ['markdown', 'table', 'json'],
        help: 'Output formatting for stdout.',
      )
      ..addOption('title', help: 'Custom heading title for the report.')
      ..addOption('d8-path', help: 'Custom path to the D8 executable.')
      ..addOption('node-path', help: 'Custom path to the Node.js executable.')
      ..addFlag(
        'cache',
        negatable: true,
        defaultsTo: true,
        help: 'Cache compiled benchmark artifacts across runs.',
      );
  }

  @override
  Future<int> run() async {
    final d8Path = argResults!.option('d8-path');
    if (d8Path != null && !File(d8Path).existsSync()) {
      stderr.writeln('Custom D8 executable "$d8Path" does not exist.');
      return ExitCode.usage.code;
    }

    final nodePath = argResults!.option('node-path');
    if (nodePath != null && !File(nodePath).existsSync()) {
      stderr.writeln('Custom Node.js executable "$nodePath" does not exist.');
      return ExitCode.usage.code;
    }

    final effectiveSdk = DartSdk(
      customSdkPath: sdk.customSdkPath,
      customD8Path: d8Path != null
          ? p.normalize(p.absolute(d8Path))
          : sdk.customD8Path,
      customNodePath: nodePath != null
          ? p.normalize(p.absolute(nodePath))
          : sdk.customNodePath,
      environment: sdk.environment,
    );

    final config = _resolveRunConfig();

    final targets = _resolveRunTargets(config);
    if (targets == null) return ExitCode.usage.code;

    final (:files, :exitCode) = _discoverRunFiles();
    if (exitCode != null) return exitCode;

    if (argResults!.flag('dry-run')) {
      _printDryRunPlan(config.generateCoordinates(), files!);
      return ExitCode.success.code;
    }

    return await _executeMatrixSuite(
      files: files!,
      config: config,
      targets: targets,
      effectiveSdk: effectiveSdk,
    );
  }

  BenchPressConfig _resolveRunConfig() {
    final configPath = argResults!.option('config') ?? 'bench_press.yaml';
    return BenchPressConfig.loadFrom(configPath) ??
        BenchPressConfig(
          defaults: DefaultsConfig(
            targets: ['jit'],
            trials: 15,
            maxTrials: null,
            output: '',
            isolateMode: false,
          ),
          matrix: MatrixConfig(explicitBaseline: {}, axes: {}),
        );
  }

  List<TargetRuntime>? _resolveRunTargets(BenchPressConfig config) {
    if (argResults!.wasParsed('target')) {
      try {
        return TargetRuntime.parseTargets(argResults!.multiOption('target'));
      } on FormatException catch (e) {
        stderr.writeln(e.message);
        return null;
      }
    }
    try {
      return TargetRuntime.parseTargets(config.defaults.targets);
    } catch (e) {
      stderr.writeln('Invalid targets in configuration: $e');
      return null;
    }
  }

  ({List<DiscoveredBenchmarkFile>? files, int? exitCode}) _discoverRunFiles() {
    final targetPaths = resolveTargetPaths(argResults!.rest);
    final verbose = globalResults?.flag('verbose') ?? false;
    try {
      final files = BenchmarkDiscovery.discoverAll(
        targetPaths,
        verbose: verbose,
      );
      if (files.isEmpty) {
        stderr.writeln(
          'No benchmark files found at "${targetPaths.join(', ')}".',
        );
        return (files: null, exitCode: ExitCode.noInput.code);
      }
      return (files: files, exitCode: null);
    } on FormatException catch (e) {
      stderr.writeln(e.message);
      return (files: null, exitCode: ExitCode.usage.code);
    } on FileSystemException catch (e) {
      stderr.writeln(e.message);
      return (files: null, exitCode: ExitCode.noInput.code);
    }
  }

  void _printDryRunPlan(
    List<MatrixCoordinate> coords,
    List<DiscoveredBenchmarkFile> files,
  ) {
    stdout.writeln(
      'Resolved Matrix Plan (${coords.length * files.length} total '
      'executions across ${files.length} benchmark file(s)):',
    );
    for (var i = 0; i < coords.length; i++) {
      final c = coords[i];
      final baseLabel = c.isBaseline ? ' (BASELINE REFERENCE)' : '';
      final str = c.coordinates.entries
          .map((e) => '${e.key}=${e.value}')
          .join(' | ');
      stdout.writeln('  [${i + 1}] $str$baseLabel');
    }
  }

  Future<int> _executeMatrixSuite({
    required List<DiscoveredBenchmarkFile> files,
    required BenchPressConfig config,
    required List<TargetRuntime> targets,
    required DartSdk effectiveSdk,
  }) async {
    try {
      ConfigValidator.validateConfig(config);
    } catch (e) {
      stderr.writeln(e.toString());
      return ExitCode.config.code;
    }

    final coords = config.generateCoordinates();
    final (:suite, :hasFailures) = await _executeMatrix(
      files,
      coords,
      config,
      targets,
      effectiveSdk,
    );
    if (suite == null || suite.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return ExitCode.software.code;
    }

    return _finishSuiteExecution(suite, hasFailures: hasFailures);
  }

  int _finishSuiteExecution(
    BenchmarkSuiteResult suite, {
    required bool hasFailures,
  }) {
    final noSave = argResults!.flag('no-save');
    final outputPath =
        argResults!.option('save') ?? argResults!.option('output')!;
    final finalSuite = !noSave ? suite.mergeAndSave(File(outputPath)) : suite;

    _outputSuiteReport(
      suite: finalSuite,
      format: argResults!.option('format')!,
      title: argResults!.option('title'),
      diffRef: argResults!.option('diff'),
      outputPath: outputPath,
      gate: argResults!.flag('gate'),
    );

    if (hasFailures) {
      stderr.writeln(
        'Failure: One or more benchmark targets failed to build or execute.',
      );
      return ExitCode.software.code;
    }

    if (argResults!.flag('fail-on-unstable') &&
        _hasUnstableBenchmark(finalSuite)) {
      stderr.writeln(
        'Failure: One or more benchmarks failed steady-state warmup.',
      );
      return 2;
    }
    return ExitCode.success.code;
  }

  Future<({BenchmarkSuiteResult? suite, bool hasFailures})> _executeMatrix(
    List<DiscoveredBenchmarkFile> files,
    List<MatrixCoordinate> coords,
    BenchPressConfig config,
    List<TargetRuntime> defaultTargets,
    DartSdk effectiveSdk,
  ) async {
    final trialsStr = argResults!.option('trials');
    final trials = trialsStr != null
        ? int.tryParse(trialsStr)
        : config.defaults.trials;
    final maxTrialsStr = argResults!.option('max-trials');
    final maxTrials = maxTrialsStr != null
        ? int.tryParse(maxTrialsStr)
        : config.defaults.maxTrials;
    final forceRun = argResults!.flag('force-run');
    final isolateMode =
        argResults!.flag('isolate-mode') || config.defaults.isolateMode;
    final compilerFlags = argResults!.multiOption('compiler-flag');
    final vmFlags = argResults!.multiOption('vm-flag');

    BenchmarkSuiteResult? accumulated;
    var hasFailures = false;

    for (final discovered in files) {
      final result = await _executeFileCoordinates(
        discovered: discovered,
        coords: coords,
        defaultTargets: defaultTargets,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        isolateMode: isolateMode,
        compilerFlags: compilerFlags,
        vmFlags: vmFlags,
        effectiveSdk: effectiveSdk,
      );
      if (result.hasFailures) {
        hasFailures = true;
      }
      if (result.suite != null) {
        accumulated = _mergeResults(accumulated, result.suite!);
      }
    }
    return (suite: accumulated, hasFailures: hasFailures);
  }

  Future<({BenchmarkSuiteResult? suite, bool hasFailures})>
  _executeFileCoordinates({
    required DiscoveredBenchmarkFile discovered,
    required List<MatrixCoordinate> coords,
    required List<TargetRuntime> defaultTargets,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required DartSdk effectiveSdk,
  }) async {
    BenchmarkSuiteResult? fileAccumulated;
    var hasFailures = false;

    for (final coord in coords) {
      final result = await _executeMatrixCoordinate(
        discovered: discovered,
        coord: coord,
        defaultTargets: defaultTargets,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        isolateMode: isolateMode,
        compilerFlags: compilerFlags,
        vmFlags: vmFlags,
        effectiveSdk: effectiveSdk,
      );
      if (result.hasFailures) {
        hasFailures = true;
      }
      if (result.suite != null) {
        fileAccumulated = _mergeResults(fileAccumulated, result.suite!);
      }
    }
    return (suite: fileAccumulated, hasFailures: hasFailures);
  }

  static BenchmarkSuiteResult _mergeResults(
    BenchmarkSuiteResult? current,
    BenchmarkSuiteResult incoming,
  ) => current == null ? incoming : current.deepMerge(incoming);

  Future<({BenchmarkSuiteResult? suite, bool hasFailures})>
  _executeMatrixCoordinate({
    required DiscoveredBenchmarkFile discovered,
    required MatrixCoordinate coord,
    required List<TargetRuntime> defaultTargets,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required DartSdk effectiveSdk,
  }) async {
    final coordRuntime =
        coord.resolvedValues[BenchmarkCoordinates.runtimeKey] ??
        coord.resolvedValues[BenchmarkCoordinates.targetKey];
    final runtimes = (coordRuntime != null && coordRuntime.isNotEmpty)
        ? TargetRuntime.parseTargets([coordRuntime])
        : defaultTargets;

    BenchmarkSuiteResult? coordAccumulated;
    var hasFailures = false;
    for (final runtime in runtimes) {
      final result = await _executeMatrixEntry(
        discovered: discovered,
        coord: coord,
        runtime: runtime,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        isolateMode: isolateMode,
        compilerFlags: compilerFlags,
        vmFlags: vmFlags,
        effectiveSdk: effectiveSdk,
      );
      if (result.hasFailures) {
        hasFailures = true;
      }
      if (result.suite != null) {
        coordAccumulated = _mergeResults(coordAccumulated, result.suite!);
      }
    }
    return (suite: coordAccumulated, hasFailures: hasFailures);
  }

  Future<({BenchmarkSuiteResult? suite, bool hasFailures})>
  _executeMatrixEntry({
    required DiscoveredBenchmarkFile discovered,
    required MatrixCoordinate coord,
    required TargetRuntime runtime,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required DartSdk effectiveSdk,
  }) async {
    final currentSdk = resolveSdkFromCoordinate(coord, effectiveSdk);
    final execFlags = _resolveFlagsFromCoordinate(coord, compilerFlags);

    final currentCompiler = currentSdk == sdk
        ? compiler
        : TargetCompiler(sdk: currentSdk);
    final currentProcessRunner = currentSdk == sdk
        ? processRunner
        : BenchmarkProcessRunner(sdk: currentSdk);

    return await _executeMatrixSingleTarget(
      discovered: discovered,
      runtime: runtime,
      trials: trials,
      maxTrials: maxTrials,
      forceRun: forceRun,
      isolateMode: isolateMode,
      compilerFlags: execFlags,
      vmFlags: vmFlags,
      compiler: currentCompiler,
      processRunner: currentProcessRunner,
      coordinate: coord,
    );
  }

  List<String> _resolveFlagsFromCoordinate(
    MatrixCoordinate coord,
    List<String> compilerFlags,
  ) {
    final execFlags = [...compilerFlags];
    final flagVal = coord.resolvedValues['flags'];
    if (flagVal != null && flagVal.isNotEmpty) {
      execFlags.addAll(flagVal.split(' '));
    }
    return execFlags;
  }

  Future<({BenchmarkSuiteResult? suite, bool hasFailures})>
  _executeMatrixSingleTarget({
    required DiscoveredBenchmarkFile discovered,
    required TargetRuntime runtime,
    required int? trials,
    required int? maxTrials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required TargetCompiler compiler,
    required BenchmarkProcessRunner processRunner,
    required MatrixCoordinate coordinate,
  }) async {
    if (!compiler.sdk.isRuntimeAvailable(runtime)) {
      stderr.writeln('Warning: Runtime "$runtime" is not available.');
      return (suite: null, hasFailures: false);
    }

    final compilation = await compiler.compile(
      sourceFile: discovered.file,
      runtime: runtime,
      compilerFlags: compilerFlags,
      useCache: argResults!['cache'] as bool,
    );

    if (!compilation.success) {
      stderr.writeln(
        'Compilation failed for ${discovered.basename} ($runtime):',
      );
      stderr.writeln(compilation.stderr);
      return (suite: null, hasFailures: true);
    }

    final execResult = await processRunner.execute(
      compilationResult: compilation,
      isolateMode: isolateMode,
      trials: trials,
      maxTrials: maxTrials,
      forceRun: forceRun,
      vmFlags: vmFlags,
    );

    if (!execResult.success || execResult.suiteResult == null) {
      stderr.writeln('Execution failed for ${discovered.basename} ($runtime):');
      stderr.writeln(execResult.errorMessage ?? execResult.stderr);
      return (suite: null, hasFailures: true);
    }

    final suiteResult = execResult.suiteResult!;
    if (suiteResult.benchmarks.isEmpty) {
      stderr.writeln(
        'Benchmark target ${discovered.basename} ($runtime) produced zero '
        'results.',
      );
      return (suite: null, hasFailures: true);
    }

    final taggedBenchmarks = suiteResult.benchmarks.map((b) {
      if (coordinate.coordinates.isEmpty) return b;
      final hasGroup =
          b.coordinates.group != null && b.coordinates.group!.isNotEmpty;
      return b.copyWith(
        coordinates: {...b.coordinates, ...coordinate.coordinates},
        isBaseline: hasGroup
            ? (b.isBaseline && coordinate.isBaseline)
            : coordinate.isBaseline,
      );
    }).toList();
    final resultSuite = BenchmarkSuiteResult(
      version: suiteResult.version,
      timestamp: suiteResult.timestamp,
      environment: suiteResult.environment,
      benchmarks: taggedBenchmarks,
    );
    return (suite: resultSuite, hasFailures: false);
  }

  bool _hasUnstableBenchmark(BenchmarkSuiteResult suite) =>
      suite.benchmarks.any((b) => !b.metrics.isStable);

  void _outputSuiteReport({
    required BenchmarkSuiteResult suite,
    required String format,
    String? title,
    String? diffRef,
    required String outputPath,
    bool gate = true,
  }) {
    if (format == 'json') {
      stdout.writeln(suite.toFormattedJson());
      return;
    }

    if (diffRef != null && diffRef.isNotEmpty) {
      _outputDiffReport(suite, diffRef, title, outputPath, gate: gate);
      return;
    }

    final report = MarkdownReporter.renderSuite(
      suite,
      title: title,
      gate: gate,
    );
    stdout.writeln(report);
  }

  void _outputDiffReport(
    BenchmarkSuiteResult suite,
    String diffRef,
    String? title,
    String outputPath, {
    bool gate = true,
  }) {
    final diffFile = File(diffRef);
    if (diffFile.existsSync()) {
      try {
        final baselineSuite = BenchmarkSuiteResult.loadFromFile(diffFile);
        final report = MarkdownReporter.renderDeltaTable(
          baseline: baselineSuite,
          current: suite,
          title: title ?? 'Baseline Delta: `$diffRef`',
          baselineLabel: 'Baseline ($diffRef)',
          currentLabel: 'Current',
          gate: gate,
        );
        stdout.writeln(report);
        return;
      } on Object catch (e) {
        stderr.writeln('Warning: Failed to load baseline from "$diffRef": $e');
      }
    }
    final report = GitDiffReporter.renderGitDiffReport(
      gitRef: diffRef,
      filePath: outputPath,
      current: suite,
      title: title,
      gate: gate,
    );
    stdout.writeln(report);
  }
}

@internal
String resolveTargetPath(List<String> rest) {
  if (rest.isNotEmpty) return rest.first;
  for (final dir in const ['benchmark', 'benchmarks', 'bench']) {
    if (Directory(dir).existsSync()) return dir;
  }
  return 'benchmark';
}

@internal
List<String> resolveTargetPaths(List<String> rest) =>
    rest.isNotEmpty ? rest : [resolveTargetPath(rest)];

@internal
DartSdk resolveSdkFromCoordinate(MatrixCoordinate coord, DartSdk baseSdk) {
  final sdkPath = coord.resolvedValues[BenchmarkCoordinates.sdkKey];
  var cleanedPath = sdkPath ?? '';
  if (cleanedPath == 'stock') cleanedPath = '';
  if (cleanedPath.startsWith('~')) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) {
      cleanedPath = cleanedPath.replaceFirst('~', home);
    }
  }
  return cleanedPath.isNotEmpty
      ? baseSdk.copyWith(customSdkPath: cleanedPath)
      : baseSdk;
}
