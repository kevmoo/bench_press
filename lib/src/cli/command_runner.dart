import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;

import '../telemetry/git_diff.dart';
import '../telemetry/markdown_reporter.dart';
import '../telemetry/schema.dart';
import 'compiler.dart';
import 'discovery.dart';
import 'process_runner.dart';
import 'sdk.dart';

const String benchPressVersion = '0.1.0';

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
      ..addMultiOption(
        'compare-sdk',
        help: 'Compare additional Dart SDKs (format: Label=Path).',
      )
      ..addOption(
        'format',
        defaultsTo: 'markdown',
        allowed: ['markdown', 'table', 'json'],
        help: 'Output formatting for stdout.',
      )
      ..addOption('title', help: 'Custom heading title for the report.');
  }

  @override
  Future<int> run() async {
    final List<TargetRuntime> targets;
    try {
      targets = TargetRuntime.parseTargets(argResults!.multiOption('target'));
    } on FormatException catch (e) {
      stderr.writeln(e.message);
      return ExitCode.usage.code;
    }
    final targetPath = _resolveTargetPath(argResults!.rest);
    final verbose = globalResults?.flag('verbose') ?? false;
    final files = BenchmarkDiscovery.discover(targetPath, verbose: verbose);

    if (files.isEmpty) {
      stderr.writeln('No benchmark files found at "$targetPath".');
      return ExitCode.noInput.code;
    }

    final compareSdks = argResults!.multiOption('compare-sdk');
    final toolchains = _setupToolchains(compareSdks);
    if (toolchains == null) {
      return ExitCode.usage.code;
    }

    final accumulated = await _executeDiscoveredFiles(
      files,
      targets,
      toolchains.compilers,
      toolchains.processRunners,
    );
    if (accumulated == null || accumulated.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return ExitCode.software.code;
    }

    final noSave = argResults!.flag('no-save');
    final saveOption = argResults!.option('save');
    final outputPath = saveOption ?? argResults!.option('output')!;
    final shouldSave = !noSave;
    final format = argResults!.option('format')!;
    final title = argResults!.option('title');
    final diffRef = argResults!.option('diff');
    final failOnUnstable = argResults!.flag('fail-on-unstable');

    final finalSuite = shouldSave
        ? accumulated.mergeAndSave(File(outputPath))
        : accumulated;

    _outputSuiteReport(
      suite: finalSuite,
      format: format,
      title: title,
      diffRef: diffRef,
      outputPath: outputPath,
      isComparison: compareSdks.isNotEmpty,
    );

    if (failOnUnstable && _hasUnstableBenchmark(finalSuite)) {
      stderr.writeln(
        'Failure: One or more benchmarks failed steady-state warmup.',
      );
      return 2;
    }

    return ExitCode.success.code;
  }

  ({
    Map<String, TargetCompiler> compilers,
    Map<String, BenchmarkProcessRunner> processRunners,
  })?
  _setupToolchains(List<String> compareSdks) {
    final sdkMap = <String, DartSdk>{};
    if (compareSdks.isEmpty || compareSdks.length == 1) {
      sdkMap['Default'] = sdk;
    }
    for (final opt in compareSdks) {
      final parts = opt.split('=');
      if (parts.length != 2) {
        stderr.writeln(
          'Invalid --compare-sdk format: "$opt". Expected Label=Path.',
        );
        return null;
      }
      sdkMap[parts[0]] = DartSdk(customSdkPath: parts[1]);
    }

    final processRunners = <String, BenchmarkProcessRunner>{};
    final compilers = <String, TargetCompiler>{};
    for (final entry in sdkMap.entries) {
      if (identical(entry.value, sdk)) {
        compilers[entry.key] = compiler;
        processRunners[entry.key] = processRunner;
      } else {
        compilers[entry.key] = TargetCompiler(sdk: entry.value);
        processRunners[entry.key] = BenchmarkProcessRunner(sdk: entry.value);
      }
    }
    return (compilers: compilers, processRunners: processRunners);
  }

  Future<BenchmarkSuiteResult?> _executeDiscoveredFiles(
    List<DiscoveredBenchmarkFile> files,
    List<TargetRuntime> targets,
    Map<String, TargetCompiler> compilers,
    Map<String, BenchmarkProcessRunner> processRunners,
  ) async {
    final trials = int.tryParse(argResults!.option('trials') ?? '');
    final forceRun = argResults!.flag('force-run');
    final isolateMode = argResults!.flag('isolate-mode');
    final compilerFlags = argResults!.multiOption('compiler-flag');
    final vmFlags = argResults!.multiOption('vm-flag');
    final isComparison = argResults!.multiOption('compare-sdk').isNotEmpty;

    BenchmarkSuiteResult? accumulated;

    for (final discovered in files) {
      for (final runtime in targets) {
        final result = await _executeTargetAcrossSdks(
          discovered: discovered,
          runtime: runtime,
          compilers: compilers,
          processRunners: processRunners,
          trials: trials,
          forceRun: forceRun,
          isolateMode: isolateMode,
          compilerFlags: compilerFlags,
          vmFlags: vmFlags,
          isComparison: isComparison,
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

  Future<BenchmarkSuiteResult?> _executeTargetAcrossSdks({
    required DiscoveredBenchmarkFile discovered,
    required TargetRuntime runtime,
    required Map<String, TargetCompiler> compilers,
    required Map<String, BenchmarkProcessRunner> processRunners,
    required int? trials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required bool isComparison,
  }) async {
    BenchmarkSuiteResult? accumulated;
    for (final entry in compilers.entries) {
      final label = entry.key;
      final buildDir = Directory(
        p.join('.dart_tool', 'bench_press', 'generated', label),
      );
      final executionFile = _resolveExecutionFile(discovered, buildDir);
      final result = await _executeSingleTarget(
        discovered: discovered,
        executionFile: executionFile,
        runtime: runtime,
        trials: trials,
        forceRun: forceRun,
        isolateMode: isolateMode,
        compilerFlags: compilerFlags,
        vmFlags: vmFlags,
        compiler: entry.value,
        processRunner: processRunners[label]!,
        sdkLabel: isComparison ? label : null,
      );
      if (result != null) {
        accumulated = accumulated == null
            ? result
            : accumulated.deepMerge(result);
      }
    }
    return accumulated;
  }

  Future<BenchmarkSuiteResult?> _executeSingleTarget({
    required DiscoveredBenchmarkFile discovered,
    required File executionFile,
    required TargetRuntime runtime,
    required int? trials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
    required TargetCompiler compiler,
    required BenchmarkProcessRunner processRunner,
    required String? sdkLabel,
  }) async {
    if (!compiler.sdk.isRuntimeAvailable(runtime)) {
      stderr.writeln('Warning: Runtime "$runtime" is not available.');
      return null;
    }

    final compilation = await compiler.compile(
      sourceFile: executionFile,
      runtime: runtime,
      compilerFlags: compilerFlags,
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
      forceRun: forceRun,
      vmFlags: vmFlags,
    );

    if (!execResult.success || execResult.suiteResult == null) {
      stderr.writeln('Execution failed for ${discovered.basename} ($runtime):');
      stderr.writeln(execResult.errorMessage ?? execResult.stderr);
      return null;
    }

    var suiteResult = execResult.suiteResult!;
    if (sdkLabel != null) {
      final taggedBenchmarks = suiteResult.benchmarks
          .map((b) => b.copyWith(group: sdkLabel))
          .toList();
      suiteResult = BenchmarkSuiteResult(
        version: suiteResult.version,
        timestamp: suiteResult.timestamp,
        environment: suiteResult.environment,
        benchmarks: taggedBenchmarks,
      );
    }
    return suiteResult;
  }

  bool _hasUnstableBenchmark(BenchmarkSuiteResult suite) =>
      suite.benchmarks.any((b) => !b.metrics.isStable);

  File _resolveExecutionFile(
    DiscoveredBenchmarkFile discovered,
    Directory buildDir,
  ) {
    if (discovered.kind == BenchmarkFileKind.benchmarksList) {
      return BenchmarkDiscovery.generateWrapper(
        benchmarkFile: discovered.file,
        outputDir: buildDir,
      );
    }
    return discovered.file;
  }

  void _outputSuiteReport({
    required BenchmarkSuiteResult suite,
    required String format,
    String? title,
    String? diffRef,
    required String outputPath,
    bool isComparison = false,
  }) {
    if (format == 'json') {
      stdout.writeln(suite.toFormattedJson());
      return;
    }

    if (isComparison && _tryOutputComparisonReport(suite, title)) {
      return;
    }

    if (diffRef != null && diffRef.isNotEmpty) {
      _outputDiffReport(suite, diffRef, title, outputPath);
      return;
    }

    final report = MarkdownReporter.renderSuite(
      suite,
      title: title ?? (isComparison ? 'SDK Comparison Report' : null),
    );
    stdout.writeln(report);
  }

  bool _tryOutputComparisonReport(BenchmarkSuiteResult suite, String? title) {
    final sdks = suite.groups;
    if (sdks.length < 2) return false;

    final baseSdk = sdks[0];
    final baseSuite = BenchmarkSuiteResult(
      version: suite.version,
      timestamp: suite.timestamp,
      environment: suite.environment,
      benchmarks: suite.getEntriesForGroup(baseSdk),
    );
    for (var i = 1; i < sdks.length; i++) {
      final currentSdk = sdks[i];
      final currentSuite = BenchmarkSuiteResult(
        version: suite.version,
        timestamp: suite.timestamp,
        environment: suite.environment,
        benchmarks: suite.getEntriesForGroup(currentSdk),
      );
      final report = MarkdownReporter.renderDeltaTable(
        baseline: baseSuite,
        current: currentSuite,
        title: title ?? 'SDK Comparison: `$baseSdk` vs `$currentSdk`',
        baselineLabel: baseSdk,
        currentLabel: currentSdk,
      );
      stdout.writeln(report);
    }
    return true;
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
      ..addMultiOption(
        'target',
        abbr: 't',
        defaultsTo: ['jit'],
        help: 'Target runtime(s) to validate (jit, aot, wasm, js, all).',
      )
      ..addMultiOption(
        'compiler-flag',
        help: 'Extra flags forwarded directly to dart compile.',
      );
  }

  @override
  Future<int> run() async {
    final List<TargetRuntime> targets;
    try {
      targets = TargetRuntime.parseTargets(argResults!.multiOption('target'));
    } on FormatException catch (e) {
      stderr.writeln(e.message);
      return ExitCode.usage.code;
    }
    final targetPath = _resolveTargetPath(argResults!.rest);
    final verbose = globalResults?.flag('verbose') ?? false;

    final files = BenchmarkDiscovery.discover(targetPath, verbose: verbose);
    if (files.isEmpty) {
      stderr.writeln('No benchmark files found at "$targetPath".');
      return ExitCode.noInput.code;
    }

    final compilerFlags = argResults!.multiOption('compiler-flag');
    final buildDir = Directory(
      p.join('.dart_tool', 'bench_press', 'validate_wrappers'),
    );

    stdout.writeln('Validating benchmarks across ${targets.join(", ")}...');
    var allPassed = true;

    for (final discovered in files) {
      final executionFile = discovered.kind == BenchmarkFileKind.benchmarksList
          ? BenchmarkDiscovery.generateWrapper(
              benchmarkFile: discovered.file,
              outputDir: buildDir,
            )
          : discovered.file;

      for (final runtime in targets) {
        final passed = await _validateTarget(
          discovered: discovered,
          executionFile: executionFile,
          runtime: runtime,
          compilerFlags: compilerFlags,
        );
        if (!passed) allPassed = false;
      }
    }

    return allPassed ? ExitCode.success.code : ExitCode.software.code;
  }

  Future<bool> _validateTarget({
    required DiscoveredBenchmarkFile discovered,
    required File executionFile,
    required TargetRuntime runtime,
    required List<String> compilerFlags,
  }) async {
    if (!sdk.isRuntimeAvailable(runtime)) {
      stdout.writeln(
        '⏭️  [$runtime] ${discovered.basename} (skipped: unavailable)',
      );
      return true;
    }

    final compilation = await compiler.compile(
      sourceFile: executionFile,
      runtime: runtime,
      compilerFlags: compilerFlags,
    );

    if (!compilation.success) {
      stdout.writeln('❌ [$runtime] ${discovered.basename} (compilation error)');
      stderr.writeln(compilation.stderr.trim());
      return false;
    }

    final execResult = await processRunner.execute(
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
  return '.';
}
