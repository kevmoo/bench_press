import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/io.dart';
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

const String benchPressVersion = '0.3.0';

/// The top-level command runner for `bench_press`.
final class BenchPressCommandRunner({
  final DartSdk sdk = const DartSdk(),
  TargetCompiler? compiler,
  BenchmarkProcessRunner? processRunner,
}) extends CommandRunner<int> {
  final TargetCompiler compiler = compiler ?? TargetCompiler(sdk: sdk);
  final BenchmarkProcessRunner processRunner =
      processRunner ?? BenchmarkProcessRunner(sdk: sdk);

  this
    : super(
        'bench_press',
        'A modern, statistically sound, compiler-aware multi-runtime '
            'benchmarking framework for Dart.',
      ) {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the current bench_press version.',
    );
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Enable verbose diagnostic logging.',
    );

    addCommand(
      RunCommand(
        sdk: sdk,
        compiler: this.compiler,
        processRunner: this.processRunner,
      ),
    );
    addCommand(
      ValidateCommand(
        sdk: sdk,
        compiler: this.compiler,
        processRunner: this.processRunner,
      ),
    );
    addCommand(ReportCommand());
    addCommand(DiffCommand());
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults.flag('version')) {
      stdout.writeln('bench_press version: $benchPressVersion');
      return ExitCode.success.code;
    }
    final code = await super.runCommand(topLevelResults);
    return code ?? ExitCode.success.code;
  }
}

/// The `run` subcommand orchestrating multi-runtime benchmark execution.
final class RunCommand({
  required final DartSdk sdk,
  required final TargetCompiler compiler,
  required final BenchmarkProcessRunner processRunner,
}) extends Command<int> {
  @override
  final String name = 'run';

  @override
  final String description =
      'Run benchmarks across one or more target runtimes (JIT, AOT, Wasm, JS).';

  this {
    argParser
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
    final targetPath = _resolveTargetPath(argResults!.rest);
    final verbose = globalResults?.flag('verbose') ?? false;
    try {
      final files = BenchmarkDiscovery.discover(targetPath, verbose: verbose);
      if (files.isEmpty) {
        stderr.writeln('No benchmark files found at "$targetPath".');
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
    final accumulated = await _executeMatrix(
      files,
      coords,
      config,
      targets,
      effectiveSdk,
    );
    if (accumulated == null || accumulated.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return ExitCode.software.code;
    }

    return _finishSuiteExecution(accumulated);
  }

  int _finishSuiteExecution(BenchmarkSuiteResult suite) {
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
    );

    if (argResults!.flag('fail-on-unstable') &&
        _hasUnstableBenchmark(finalSuite)) {
      stderr.writeln(
        'Failure: One or more benchmarks failed steady-state warmup.',
      );
      return 2;
    }
    return ExitCode.success.code;
  }

  Future<BenchmarkSuiteResult?> _executeMatrix(
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

    for (final discovered in files) {
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
        if (result != null) {
          accumulated = accumulated == null
              ? result
              : accumulated.deepMerge(result);
        }
      }
    }
    return accumulated;
  }

  Future<BenchmarkSuiteResult?> _executeMatrixCoordinate({
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
      if (result != null) {
        coordAccumulated = coordAccumulated == null
            ? result
            : coordAccumulated.deepMerge(result);
      }
    }
    return coordAccumulated;
  }

  Future<BenchmarkSuiteResult?> _executeMatrixEntry({
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
    final currentSdk = _resolveSdkFromCoordinate(coord, effectiveSdk);
    final execFlags = _resolveFlagsFromCoordinate(coord, compilerFlags);

    return await _executeMatrixSingleTarget(
      discovered: discovered,
      runtime: runtime,
      trials: trials,
      maxTrials: maxTrials,
      forceRun: forceRun,
      isolateMode: isolateMode,
      compilerFlags: execFlags,
      vmFlags: vmFlags,
      compiler: TargetCompiler(sdk: currentSdk),
      processRunner: BenchmarkProcessRunner(sdk: currentSdk),
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

  Future<BenchmarkSuiteResult?> _executeMatrixSingleTarget({
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
      return null;
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
      return null;
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
      return null;
    }

    final suiteResult = execResult.suiteResult!;
    final taggedBenchmarks = suiteResult.benchmarks.map((b) {
      if (coordinate.coordinates.isEmpty) return b;
      return b.copyWith(
        coordinates: {...b.coordinates, ...coordinate.coordinates},
        isBaseline: coordinate.isBaseline,
      );
    }).toList();
    return BenchmarkSuiteResult(
      version: suiteResult.version,
      timestamp: suiteResult.timestamp,
      environment: suiteResult.environment,
      benchmarks: taggedBenchmarks,
    );
  }

  bool _hasUnstableBenchmark(BenchmarkSuiteResult suite) =>
      suite.benchmarks.any((b) => !b.metrics.isStable);

  void _outputSuiteReport({
    required BenchmarkSuiteResult suite,
    required String format,
    String? title,
    String? diffRef,
    required String outputPath,
  }) {
    if (format == 'json') {
      stdout.writeln(suite.toFormattedJson());
      return;
    }

    if (diffRef != null && diffRef.isNotEmpty) {
      _outputDiffReport(suite, diffRef, title, outputPath);
      return;
    }

    final report = MarkdownReporter.renderSuite(suite, title: title);
    stdout.writeln(report);
  }

  void _outputDiffReport(
    BenchmarkSuiteResult suite,
    String diffRef,
    String? title,
    String outputPath,
  ) {
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
    );
    stdout.writeln(report);
  }
}

/// The `validate` subcommand providing fast 2-second smoke verification.
final class ValidateCommand({
  required final DartSdk sdk,
  required final TargetCompiler compiler,
  required final BenchmarkProcessRunner processRunner,
}) extends Command<int> {
  @override
  final String name = 'validate';

  @override
  final String description =
      'Quick smoke test across compilers to verify syntax and runtime '
      'health in ~2s.';

  this {
    argParser
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Path to bench_press.yaml configuration file.',
      )
      ..addMultiOption(
        'target',
        abbr: 't',
        defaultsTo: ['jit'],
        help: 'Target runtime(s) to validate (jit, aot, wasm, js, all).',
      )
      ..addMultiOption(
        'compiler-flag',
        help: 'Extra flags forwarded directly to dart compile.',
      )
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

    final configPath = argResults!.option('config') ?? 'bench_press.yaml';
    final config = BenchPressConfig.loadFrom(configPath);

    final targets = _resolveValidateTargets(config);
    if (targets == null) return ExitCode.usage.code;

    final (:files, :exitCode) = _discoverValidateFiles();
    if (exitCode != null) return exitCode;

    final compilerFlags = argResults!.multiOption('compiler-flag');
    stdout.writeln('Validating benchmarks across ${targets.join(", ")}...');

    final allPassed = await _runValidation(
      config: config,
      files: files!,
      targets: targets,
      compilerFlags: compilerFlags,
      effectiveSdk: effectiveSdk,
    );

    return allPassed ? ExitCode.success.code : ExitCode.software.code;
  }

  List<TargetRuntime>? _resolveValidateTargets(BenchPressConfig? config) {
    if (argResults!.wasParsed('target') || config == null) {
      try {
        return TargetRuntime.parseTargets(argResults!.multiOption('target'));
      } on FormatException catch (e) {
        stderr.writeln(e.message);
        return null;
      }
    }
    return TargetRuntime.parseTargets(config.defaults.targets);
  }

  ({List<DiscoveredBenchmarkFile>? files, int? exitCode})
  _discoverValidateFiles() {
    final targetPath = _resolveTargetPath(argResults!.rest);
    final verbose = globalResults?.flag('verbose') ?? false;
    try {
      final files = BenchmarkDiscovery.discover(targetPath, verbose: verbose);
      if (files.isEmpty) {
        stderr.writeln('No benchmark files found at "$targetPath".');
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

  Future<bool> _runValidation({
    required BenchPressConfig? config,
    required List<DiscoveredBenchmarkFile> files,
    required List<TargetRuntime> targets,
    required List<String> compilerFlags,
    required DartSdk effectiveSdk,
  }) {
    if (config == null) {
      return _validateSimpleTargets(
        files,
        targets,
        compilerFlags,
        effectiveSdk,
      );
    }
    return _validateMatrixTargets(
      files,
      config,
      targets,
      compilerFlags,
      effectiveSdk,
    );
  }

  Future<bool> _validateSimpleTargets(
    List<DiscoveredBenchmarkFile> files,
    List<TargetRuntime> targets,
    List<String> compilerFlags,
    DartSdk effectiveSdk,
  ) async {
    final effectiveCompiler = TargetCompiler(sdk: effectiveSdk);
    final effectiveProcessRunner = BenchmarkProcessRunner(sdk: effectiveSdk);
    var allPassed = true;
    for (final discovered in files) {
      for (final runtime in targets) {
        final passed = await _validateTarget(
          discovered: discovered,
          runtime: runtime,
          compilerFlags: compilerFlags,
          currentSdk: effectiveSdk,
          currentCompiler: effectiveCompiler,
          currentProcessRunner: effectiveProcessRunner,
        );
        if (!passed) allPassed = false;
      }
    }
    return allPassed;
  }

  Future<bool> _validateMatrixTargets(
    List<DiscoveredBenchmarkFile> files,
    BenchPressConfig config,
    List<TargetRuntime> targets,
    List<String> compilerFlags,
    DartSdk effectiveSdk,
  ) async {
    var allPassed = true;
    final coords = config.generateCoordinates();
    for (final discovered in files) {
      for (final coord in coords) {
        final currentSdk = _resolveSdkFromCoordinate(coord, effectiveSdk);
        final currentCompiler = TargetCompiler(sdk: currentSdk);
        final currentProcessRunner = BenchmarkProcessRunner(sdk: currentSdk);
        final runtimeTarget = coord.resolvedValues['runtime'];
        final runtime = (runtimeTarget != null && runtimeTarget.isNotEmpty)
            ? TargetRuntime.parseTargets([runtimeTarget]).first
            : targets.first;
        final passed = await _validateTarget(
          discovered: discovered,
          runtime: runtime,
          compilerFlags: compilerFlags,
          currentSdk: currentSdk,
          currentCompiler: currentCompiler,
          currentProcessRunner: currentProcessRunner,
        );
        if (!passed) allPassed = false;
      }
    }
    return allPassed;
  }

  Future<bool> _validateTarget({
    required DiscoveredBenchmarkFile discovered,
    required TargetRuntime runtime,
    required List<String> compilerFlags,
    DartSdk? currentSdk,
    TargetCompiler? currentCompiler,
    BenchmarkProcessRunner? currentProcessRunner,
  }) async {
    final activeSdk = currentSdk ?? sdk;
    final activeCompiler = currentCompiler ?? compiler;
    final activeProcessRunner = currentProcessRunner ?? processRunner;

    if (!activeSdk.isRuntimeAvailable(runtime)) {
      stdout.writeln(
        '⏭️  [$runtime] ${discovered.basename} (skipped: unavailable)',
      );
      return true;
    }

    final compilation = await activeCompiler.compile(
      sourceFile: discovered.file,
      runtime: runtime,
      compilerFlags: compilerFlags,
      useCache: argResults!['cache'] as bool,
    );

    if (!compilation.success) {
      stdout.writeln('❌ [$runtime] ${discovered.basename} (compilation error)');
      stderr.writeln(compilation.stderr.trim());
      return false;
    }

    final execResult = await activeProcessRunner.execute(
      compilationResult: compilation,
      validate: true,
      forceRun: true,
    );

    if (execResult.success && execResult.suiteResult != null) {
      final ms = execResult.executionDuration.inMilliseconds;
      stdout.writeln('✅ [$runtime] ${discovered.basename} (${ms}ms)');
      return true;
    } else {
      stdout.writeln('❌ [$runtime] ${discovered.basename} (runtime error)');
      stderr.writeln(execResult.errorMessage ?? execResult.stderr.trim());
      return false;
    }
  }
}

/// The `report` subcommand rendering markdown reports from stored telemetry.
final class ReportCommand() extends Command<int> {
  @override
  final String name = 'report';

  @override
  final String description =
      'Render a formatted Markdown report from stored JSON telemetry.';

  this {
    argParser
      ..addOption(
        'from-json',
        abbr: 'f',
        defaultsTo: defaultTelemetryFileName,
        help: 'Path to telemetry JSON file.',
      )
      ..addOption('title', help: 'Custom heading title for the report.')
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Optional file path to write Markdown report to.',
      );
  }

  @override
  Future<int> run() async {
    final inputPath = argResults!.rest.isNotEmpty
        ? argResults!.rest.first
        : (argResults!.option('from-json')!);

    final file = File(inputPath);
    if (!file.existsSync()) {
      stderr.writeln('Telemetry file "$inputPath" does not exist.');
      return ExitCode.noInput.code;
    }

    final title = argResults!.option('title');
    final outputPath = argResults!.option('output');

    try {
      final report = MarkdownReporter.renderFromFile(file, title: title);
      if (outputPath != null && outputPath.isNotEmpty) {
        final outFile = File(outputPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsStringSync('$report\n');
      } else {
        stdout.writeln(report);
      }
      return ExitCode.success.code;
    } on Object catch (e) {
      stderr.writeln('Failed to render report: $e');
      return ExitCode.software.code;
    }
  }
}

/// The `diff` subcommand computing isolated Before-vs-After delta tables.
final class DiffCommand() extends Command<int> {
  @override
  final String name = 'diff';

  @override
  final String description =
      'Diff two JSON telemetry files or diff current telemetry against '
      'a Git ref.';

  @override
  String get invocation =>
      '${runner!.executableName} $name [arguments] <baseline> [current]';

  this {
    argParser
      ..addOption(
        'baseline',
        abbr: 'b',
        help: 'Baseline JSON file path OR Git ref (e.g. HEAD~1, main).',
      )
      ..addOption(
        'current',
        abbr: 'c',
        defaultsTo: defaultTelemetryFileName,
        help: 'Current JSON file path.',
      )
      ..addOption(
        'target-file',
        defaultsTo: defaultTelemetryFileName,
        help:
            'Path to telemetry file in Git commit when diffing against '
            'Git ref.',
      )
      ..addOption('title', help: 'Custom title for the diff report.')
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Optional file path to write Markdown diff report to.',
      );
  }

  ({String baseline, String current}) _resolveDiffArgs() {
    final hasBaselineFlag = argResults!.wasParsed('baseline');
    final hasCurrentFlag = argResults!.wasParsed('current');
    final rest = argResults!.rest;

    _validateDiffArgCounts(
      hasBaselineFlag: hasBaselineFlag,
      hasCurrentFlag: hasCurrentFlag,
      restCount: rest.length,
    );

    final baseline = hasBaselineFlag
        ? argResults!.option('baseline')
        : (rest.isNotEmpty ? rest[0] : null);

    if (baseline == null) {
      throw UsageException(
        'Missing baseline file path. Specify via --baseline (-b) or '
        'positional argument <baseline>.',
        usage,
      );
    }

    final String current;
    if (hasCurrentFlag) {
      current = argResults!.option('current')!;
    } else if (hasBaselineFlag && rest.isNotEmpty) {
      current = rest[0];
    } else if (!hasBaselineFlag && rest.length >= 2) {
      current = rest[1];
    } else {
      current = defaultTelemetryFileName;
    }

    return (baseline: baseline, current: current);
  }

  void _validateDiffArgCounts({
    required bool hasBaselineFlag,
    required bool hasCurrentFlag,
    required int restCount,
  }) {
    final maxPositional = switch ((hasBaselineFlag, hasCurrentFlag)) {
      (true, true) => 0,
      (true, false) => 1,
      (false, true) => 1,
      (false, false) => 2,
    };
    if (restCount > maxPositional) {
      throw UsageException(
        'Too many positional arguments for the specified options.',
        usage,
      );
    }
  }

  @override
  Future<int> run() async {
    final (:baseline, :current) = _resolveDiffArgs();
    final targetFileArg = argResults!.option('target-file')!;
    final title = argResults!.option('title');
    final outputPath = argResults!.option('output');

    final currentFile = File(current);
    if (!currentFile.existsSync()) {
      stderr.writeln('Current telemetry file "$current" does not exist.');
      return ExitCode.noInput.code;
    }

    String report;
    final baselineFile = File(baseline);
    if (baselineFile.existsSync()) {
      report = MarkdownReporter.renderDeltaFromFiles(
        baselineFile: baselineFile,
        currentFile: currentFile,
        title: title,
      );
    } else {
      final currentSuite = BenchmarkSuiteResult.loadFromFile(currentFile);
      report = GitDiffReporter.renderGitDiffReport(
        gitRef: baseline,
        filePath: targetFileArg,
        current: currentSuite,
        title: title,
      );
    }

    if (outputPath != null && outputPath.isNotEmpty) {
      final outFile = File(outputPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsStringSync('$report\n');
    } else {
      stdout.writeln(report);
    }
    return ExitCode.success.code;
  }
}

String _resolveTargetPath(List<String> rest) {
  if (rest.isNotEmpty) return rest.first;
  for (final dir in const ['benchmark', 'benchmarks', 'bench']) {
    if (Directory(dir).existsSync()) return dir;
  }
  return 'benchmark';
}

DartSdk _resolveSdkFromCoordinate(MatrixCoordinate coord, DartSdk baseSdk) {
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
