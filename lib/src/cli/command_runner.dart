import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;

import '../config/bench_press_config.dart';
import '../telemetry/git_diff.dart';
import '../telemetry/markdown_reporter.dart';
import '../telemetry/schema.dart';
import 'compiler.dart';
import 'discovery.dart';
import 'process_runner.dart';
import 'run_command.dart';
import 'sdk.dart';

export 'run_command.dart' show RunCommand;

const String benchPressVersion = '0.3.2-wip';

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

/// The `validate` subcommand providing fast 2-second smoke verification.
final class ValidateCommand({
  required final DartSdk sdk,
  required final TargetCompiler compiler,
  required final BenchmarkProcessRunner processRunner,
}) extends Command<int> {
  @override
  String get name => 'validate';

  @override
  String get description =>
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
    final targetPath = resolveTargetPath(argResults!.rest);
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
    final effectiveCompiler = effectiveSdk == sdk
        ? compiler
        : TargetCompiler(sdk: effectiveSdk);
    final effectiveProcessRunner = effectiveSdk == sdk
        ? processRunner
        : BenchmarkProcessRunner(sdk: effectiveSdk);
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
        final passed = await _validateCoordinate(
          discovered: discovered,
          coord: coord,
          targets: targets,
          compilerFlags: compilerFlags,
          effectiveSdk: effectiveSdk,
        );
        if (!passed) allPassed = false;
      }
    }
    return allPassed;
  }

  Future<bool> _validateCoordinate({
    required DiscoveredBenchmarkFile discovered,
    required MatrixCoordinate coord,
    required List<TargetRuntime> targets,
    required List<String> compilerFlags,
    required DartSdk effectiveSdk,
  }) async {
    final currentSdk = resolveSdkFromCoordinate(coord, effectiveSdk);
    final (compiler, runner) = _resolveCompilerAndRunner(currentSdk);
    final runtimes = _resolveTargetsFromCoordinate(coord, targets);
    var allPassed = true;
    for (final runtime in runtimes) {
      final passed = await _validateTarget(
        discovered: discovered,
        runtime: runtime,
        compilerFlags: compilerFlags,
        currentSdk: currentSdk,
        currentCompiler: compiler,
        currentProcessRunner: runner,
      );
      if (!passed) allPassed = false;
    }
    return allPassed;
  }

  (TargetCompiler, BenchmarkProcessRunner) _resolveCompilerAndRunner(
    DartSdk currentSdk,
  ) {
    if (currentSdk == sdk) {
      return (compiler, processRunner);
    }
    return (
      TargetCompiler(sdk: currentSdk),
      BenchmarkProcessRunner(sdk: currentSdk),
    );
  }

  List<TargetRuntime> _resolveTargetsFromCoordinate(
    MatrixCoordinate coord,
    List<TargetRuntime> defaultTargets,
  ) {
    final target =
        coord.resolvedValues[BenchmarkCoordinates.runtimeKey] ??
        coord.resolvedValues[BenchmarkCoordinates.targetKey];
    if (target != null && target.isNotEmpty) {
      return TargetRuntime.parseTargets([target]);
    }
    return defaultTargets;
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
      if (execResult.suiteResult!.benchmarks.isEmpty) {
        stdout.writeln(
          '❌ [$runtime] ${discovered.basename} (zero benchmarks produced)',
        );
        stderr.writeln('Target execution produced zero results.');
        return false;
      }
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
  String get name => 'report';

  @override
  String get description =>
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
  String get name => 'diff';

  @override
  String get description =>
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
