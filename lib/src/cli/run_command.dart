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
import 'cpu_affinity.dart';
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
            'or whose samples are not stable. Pass --no-gate to '
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
        help:
            'File path to save/merge benchmark suite results JSON. Falls back '
            'to defaults.output in bench_press.yaml, then '
            '$defaultTelemetryFileName.',
      )
      ..addOption(
        'save',
        abbr: 's',
        help: 'Same as --output; takes precedence over it.',
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
        'pin-cpu',
        valueHelp: 'cpu-list',
        help:
            'Pin benchmark processes to these CPUs via taskset. Linux only: '
            'on Windows and macOS this warns and runs unpinned. Accepts '
            'taskset -c syntax: "2", "0,2,4", "0-3", "0-7:2". Use '
            '"lscpu -e=CPU,CORE" to find CPUs that are not SMT siblings.',
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

    // A malformed CPU list is a usage error, not a host limitation: fail here
    // rather than warning and measuring unpinned, which would hand back numbers
    // that look pinned. Matches --d8-path and --node-path above.
    final pinCpuSpec = argResults!.option('pin-cpu');
    CpuAffinity? pinCpu;
    if (pinCpuSpec != null) {
      try {
        pinCpu = CpuAffinity.parse(pinCpuSpec);
      } on FormatException catch (e) {
        stderr.writeln('Invalid --pin-cpu value "$pinCpuSpec": ${e.message}');
        return ExitCode.usage.code;
      }
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
    final explicitTargets = argResults!.wasParsed('target') ? targets : null;

    final (:files, :exitCode) = _discoverRunFiles();
    if (exitCode != null) return exitCode;

    if (argResults!.flag('dry-run')) {
      final coords = _selectCoordinates(config, explicitTargets);
      if (coords == null) return ExitCode.usage.code;
      _printDryRunPlan(coords, files!);
      return ExitCode.success.code;
    }

    return await _executeMatrixSuite(
      files: files!,
      config: config,
      targets: targets,
      explicitTargets: explicitTargets,
      effectiveSdk: effectiveSdk,
      pinCpu: pinCpu,
    );
  }

  /// The matrix coordinates this run executes: every coordinate the config
  /// generates, narrowed to [explicitTargets] when `--target` was passed.
  ///
  /// A coordinate that pins a runtime axis runs only when that runtime was
  /// requested; a coordinate without one runs every requested target and is
  /// always kept. Returns `null` after reporting a usage error when the
  /// selection would leave nothing to run, because a `--target` that silently
  /// runs the whole matrix hands back numbers that look like the ones asked
  /// for.
  List<MatrixCoordinate>? _selectCoordinates(
    BenchPressConfig config,
    List<TargetRuntime>? explicitTargets,
  ) {
    final all = config.generateCoordinates();
    if (explicitTargets == null) return all;
    final wanted = explicitTargets.toSet();
    final selected = all.where((coord) {
      final pinned = _coordinateRuntime(coord);
      return pinned == null || wanted.contains(pinned);
    }).toList();
    if (selected.isEmpty && all.isNotEmpty) {
      final available = all
          .map(_coordinateRuntime)
          .nonNulls
          .map((t) => t.name)
          .toSet()
          .join(', ');
      stderr.writeln(
        '--target ${explicitTargets.map((t) => t.name).join(',')} matches '
        'none of the runtime coordinates in the matrix ($available).',
      );
      return null;
    }
    return selected;
  }

  /// Narrows an already-parsed [pinCpu] to what this host and run can actually
  /// honour, returning `null` to run unpinned.
  ///
  /// A malformed value is rejected earlier, in [run], as a usage error. What
  /// remains here are host and mode limitations, which warn and continue — and
  /// every one of them says so on stderr, because a suite that was asked to pin
  /// and quietly did not is worse than one that never asked: the resulting
  /// numbers look like pinned numbers.
  CpuAffinity? _applyCpuPinningLimits(
    CpuAffinity? pinCpu, {
    required bool isolateMode,
    required List<TargetRuntime> targets,
  }) {
    if (pinCpu == null) return null;

    final reason = cpuPinningUnsupportedReason();
    if (reason != null) {
      stderr.writeln('Warning: --pin-cpu ignored. $reason');
      return null;
    }

    if (isolateMode) {
      // Only claim the other targets are pinned when there are some. `--target`
      // defaults to jit alone, so the common invocation pins nothing.
      final hasSpawnedTargets = targets.any((t) => t != TargetRuntime.jit);
      final scope = hasSpawnedTargets
          ? 'Non-JIT targets in this run are still pinned.'
          : 'This run has no other targets, so nothing is pinned.';
      stderr.writeln(
        'Warning: --pin-cpu does not apply to --isolate-mode, which runs JIT '
        'benchmarks in-process rather than spawning a command taskset could '
        'wrap. $scope To pin isolate mode, pin bench_press itself: '
        'taskset -c ${pinCpu.cpuList} dart run bench_press run ...',
      );
      if (!hasSpawnedTargets) return null;
    }

    return pinCpu;
  }

  BenchPressConfig _resolveRunConfig() {
    final configPath = argResults!.option('config') ?? 'bench_press.yaml';
    return BenchPressConfig.loadFrom(configPath) ??
        BenchPressConfig(
          defaults: DefaultsConfig(
            targets: ['jit'],
            trials: 15,
            maxTrials: null,
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
    required List<TargetRuntime>? explicitTargets,
    required DartSdk effectiveSdk,
    required CpuAffinity? pinCpu,
  }) async {
    try {
      ConfigValidator.validateConfig(config);
    } catch (e) {
      stderr.writeln(e.toString());
      return ExitCode.config.code;
    }

    final coords = _selectCoordinates(config, explicitTargets);
    if (coords == null) return ExitCode.usage.code;
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
    final cpuAffinity = _applyCpuPinningLimits(
      pinCpu,
      isolateMode: isolateMode,
      targets: _effectiveMatrixTargets(coords, targets),
    );

    BenchmarkSuiteResult? suite;
    var hasFailures = false;

    for (final discovered in files) {
      final result = await _executeFileCoordinates(
        discovered: discovered,
        coords: coords,
        defaultTargets: targets,
        trials: trials,
        maxTrials: maxTrials,
        forceRun: forceRun,
        isolateMode: isolateMode,
        compilerFlags: compilerFlags,
        vmFlags: vmFlags,
        cpuAffinity: cpuAffinity,
        effectiveSdk: effectiveSdk,
      );
      if (result.hasFailures) {
        hasFailures = true;
      }
      if (result.suite != null) {
        suite = _mergeResults(suite, result.suite!);
      }
    }

    if (suite == null || suite.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return ExitCode.software.code;
    }

    return _finishSuiteExecution(
      suite,
      hasFailures: hasFailures,
      configuredOutput: config.defaults.output,
    );
  }

  int _finishSuiteExecution(
    BenchmarkSuiteResult suite, {
    required bool hasFailures,
    required String configuredOutput,
  }) {
    final noSave = argResults!.flag('no-save');
    final outputPath =
        argResults!.option('save') ??
        argResults!.option('output') ??
        expandHomeDirectory(configuredOutput);
    final finalSuite = !noSave ? suite.mergeAndSave(File(outputPath)) : suite;

    final format = argResults!.option('format')!;
    final title = argResults!.option('title');
    final diffRef = argResults!.option('diff') ?? '';
    final gate = argResults!.flag('gate');

    String? report;
    if (format == 'json') {
      report = finalSuite.toFormattedJson();
    } else if (diffRef.isEmpty) {
      report = MarkdownReporter.renderSuite(
        finalSuite,
        title: title,
        gate: gate,
      );
    } else if (File(diffRef).existsSync()) {
      try {
        final baselineSuite = BenchmarkSuiteResult.loadFromFile(File(diffRef));
        report = MarkdownReporter.renderDeltaTable(
          baseline: baselineSuite,
          current: finalSuite,
          title: title ?? 'Baseline Delta: `$diffRef`',
          baselineLabel: 'Baseline ($diffRef)',
          currentLabel: 'Current',
          gate: gate,
        );
      } on Object catch (e) {
        stderr.writeln('Warning: Failed to load baseline from "$diffRef": $e');
      }
    }
    stdout.writeln(
      report ??
          GitDiffReporter.renderGitDiffReport(
            gitRef: diffRef,
            filePath: outputPath,
            current: finalSuite,
            title: title,
            gate: gate,
          ),
    );

    if (hasFailures) {
      stderr.writeln(
        'Failure: One or more benchmark targets failed to build or execute.',
      );
      return ExitCode.software.code;
    }

    if (argResults!.flag('fail-on-unstable') &&
        finalSuite.benchmarks.any((b) => !b.metrics.isStable)) {
      stderr.writeln(
        'Failure: One or more benchmarks failed steady-state warmup.',
      );
      return 2;
    }
    return ExitCode.success.code;
  }

  static List<TargetRuntime> _resolveCoordinateTargets(
    MatrixCoordinate coord,
    List<TargetRuntime> defaultTargets,
  ) {
    final pinned = _coordinateRuntime(coord);
    return pinned == null ? defaultTargets : [pinned];
  }

  /// The runtime a coordinate pins through its `runtime` (or legacy `target`)
  /// axis, or `null` when the coordinate leaves the runtime to `--target`.
  static TargetRuntime? _coordinateRuntime(MatrixCoordinate coord) {
    final value =
        coord.resolvedValues[BenchmarkCoordinates.runtimeKey] ??
        coord.resolvedValues[BenchmarkCoordinates.targetKey];
    if (value == null || value.isEmpty) return null;
    return TargetRuntime.tryParse(value);
  }

  static List<TargetRuntime> _effectiveMatrixTargets(
    List<MatrixCoordinate> coords,
    List<TargetRuntime> defaultTargets,
  ) {
    if (coords.isEmpty) return defaultTargets;
    return {
      for (final coord in coords)
        ..._resolveCoordinateTargets(coord, defaultTargets),
    }.toList();
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
    required CpuAffinity? cpuAffinity,
    required DartSdk effectiveSdk,
  }) async {
    BenchmarkSuiteResult? fileAccumulated;
    var hasFailures = false;

    for (final coord in coords) {
      final runtimes = _resolveCoordinateTargets(coord, defaultTargets);
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
          cpuAffinity: cpuAffinity,
          effectiveSdk: effectiveSdk,
        );
        if (result.hasFailures) {
          hasFailures = true;
        }
        if (result.suite != null) {
          fileAccumulated = _mergeResults(fileAccumulated, result.suite!);
        }
      }
    }
    return (suite: fileAccumulated, hasFailures: hasFailures);
  }

  static BenchmarkSuiteResult _mergeResults(
    BenchmarkSuiteResult? current,
    BenchmarkSuiteResult incoming,
  ) => current == null ? incoming : current.deepMerge(incoming);

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
    required CpuAffinity? cpuAffinity,
    required DartSdk effectiveSdk,
  }) async {
    final currentSdk = resolveSdkFromCoordinate(coord, effectiveSdk);
    final execFlags = _resolveFlagsFromCoordinate(coord, compilerFlags);

    final currentCompiler = currentSdk == sdk
        ? compiler
        : TargetCompiler(sdk: currentSdk);
    final currentProcessRunner =
        currentSdk == sdk && cpuAffinity == processRunner.cpuAffinity
        ? processRunner
        : BenchmarkProcessRunner(sdk: currentSdk, cpuAffinity: cpuAffinity);

    if (currentCompiler.sdk.explicitSdkError == null &&
        !currentCompiler.sdk.isRuntimeAvailable(runtime)) {
      stderr.writeln('Warning: Runtime "$runtime" is not available.');
      return (suite: null, hasFailures: false);
    }

    final compilation = await currentCompiler.compile(
      sourceFile: discovered.file,
      runtime: runtime,
      compilerFlags: execFlags,
      useCache: argResults!['cache'] as bool,
    );

    if (!compilation.success) {
      stderr.writeln(
        'Compilation failed for ${discovered.basename} ($runtime):',
      );
      stderr.writeln(compilation.stderr);
      return (suite: null, hasFailures: true);
    }

    final execResult = await currentProcessRunner.execute(
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
      if (coord.coordinates.isEmpty) return b;
      final hasGroup =
          b.coordinates.group != null && b.coordinates.group!.isNotEmpty;
      return b.copyWith(
        coordinates: {...b.coordinates, ...coord.coordinates},
        isBaseline: hasGroup
            ? (b.isBaseline && coord.isBaseline)
            : coord.isBaseline,
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
  cleanedPath = expandHomeDirectory(cleanedPath);
  return cleanedPath.isNotEmpty
      ? baseSdk.copyWith(customSdkPath: cleanedPath)
      : baseSdk;
}

/// Replaces a leading `~` in [path] with the user's home directory, as a shell
/// does for an unquoted argument.
///
/// Returns [path] unchanged when it has no leading `~` or when neither `HOME`
/// nor `USERPROFILE` is set.
@internal
String expandHomeDirectory(String path) {
  if (!path.startsWith('~')) return path;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  return home == null ? path : path.replaceFirst('~', home);
}
