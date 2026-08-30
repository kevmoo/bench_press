import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../telemetry/git_diff.dart';
import '../telemetry/markdown_reporter.dart';
import '../telemetry/schema.dart';
import 'compiler.dart';
import 'discovery.dart';
import 'process_runner.dart';
import 'sdk.dart';

const String benchPressVersion = '0.1.0-wip';

/// The top-level command runner for `bench_press`.
final class BenchPressCommandRunner extends CommandRunner<int> {
  final DartSdk sdk;
  final TargetCompiler compiler;
  final BenchmarkProcessRunner processRunner;

  BenchPressCommandRunner({
    this.sdk = const DartSdk(),
    TargetCompiler? compiler,
    BenchmarkProcessRunner? processRunner,
  }) : compiler = compiler ?? TargetCompiler(sdk: sdk),
       processRunner = processRunner ?? BenchmarkProcessRunner(sdk: sdk),
       super(
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
  Future<int> run(Iterable<String> args) async {
    try {
      final results = parse(args);
      if (results['version'] == true) {
        stdout.writeln('bench_press version: $benchPressVersion');
        return 0;
      }
      final exitCode = await runCommand(results);
      return exitCode ?? 0;
    } on UsageException catch (e) {
      stderr.writeln(e.message);
      stderr.writeln();
      stderr.writeln(e.usage);
      return 64;
    } on Object catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }
  }
}

/// The `run` subcommand orchestrating multi-runtime benchmark execution.
final class RunCommand extends Command<int> {
  final DartSdk sdk;
  final TargetCompiler compiler;
  final BenchmarkProcessRunner processRunner;

  @override
  final String name = 'run';

  @override
  final String description =
      'Run benchmarks across one or more target runtimes (JIT, AOT, Wasm, JS).';

  RunCommand({
    required this.sdk,
    required this.compiler,
    required this.processRunner,
  }) {
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
      ..addFlag(
        'save',
        defaultsTo: true,
        help: 'Save/merge JSON results to the output file.',
      )
      ..addOption(
        'trials',
        help: 'Number of measurement trials per benchmark (default: 15).',
      )
      ..addFlag(
        'force-run',
        negatable: false,
        help: 'Force execution bypassing calibration safety aborts (<10µs).',
      )
      ..addFlag(
        'isolate-mode',
        negatable: false,
        help: 'Execute JIT benchmarks within spawned Dart isolates.',
      )
      ..addOption(
        'diff',
        help:
            'Git reference (e.g. HEAD~1, main) to diff results against '
            'in-memory.',
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
      ..addOption('title', help: 'Custom heading title for the report.');
  }

  @override
  Future<int> run() async {
    final targets = TargetRuntime.parseTargets(
      argResults!['target'] as List<String>,
    );
    final targetPath = _resolveTargetPath(argResults!.rest);
    final files = BenchmarkDiscovery.discover(targetPath);

    if (files.isEmpty) {
      stderr.writeln('No benchmark files found at "$targetPath".');
      return 1;
    }

    final accumulated = await _executeDiscoveredFiles(files, targets);
    if (accumulated == null || accumulated.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return 1;
    }

    final outputPath = argResults!['output'] as String;
    final shouldSave = argResults!['save'] as bool;
    final format = argResults!['format'] as String;
    final title = argResults!['title'] as String?;
    final diffRef = argResults!['diff'] as String?;
    final failOnUnstable = argResults!['fail-on-unstable'] as bool;

    final finalSuite = shouldSave
        ? accumulated.mergeAndSave(File(outputPath))
        : accumulated;

    _outputSuiteReport(
      suite: finalSuite,
      format: format,
      title: title,
      diffRef: diffRef,
      outputPath: outputPath,
    );

    if (failOnUnstable && _hasUnstableBenchmark(finalSuite)) {
      stderr.writeln(
        'Failure: One or more benchmarks failed steady-state warmup.',
      );
      return 2;
    }

    return 0;
  }

  Future<BenchmarkSuiteResult?> _executeDiscoveredFiles(
    List<DiscoveredBenchmarkFile> files,
    List<TargetRuntime> targets,
  ) async {
    final buildDir = Directory(
      p.join('.dart_tool', 'bench_press', 'generated'),
    );
    final trials = int.tryParse(argResults!['trials'] as String? ?? '');
    final forceRun = argResults!['force-run'] as bool;
    final isolateMode = argResults!['isolate-mode'] as bool;
    final compilerFlags = argResults!['compiler-flag'] as List<String>;
    final vmFlags = argResults!['vm-flag'] as List<String>;

    BenchmarkSuiteResult? accumulated;

    for (final discovered in files) {
      final executionFile = _resolveExecutionFile(discovered, buildDir);
      for (final runtime in targets) {
        final result = await _executeSingleTarget(
          discovered: discovered,
          executionFile: executionFile,
          runtime: runtime,
          trials: trials,
          forceRun: forceRun,
          isolateMode: isolateMode,
          compilerFlags: compilerFlags,
          vmFlags: vmFlags,
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

  Future<BenchmarkSuiteResult?> _executeSingleTarget({
    required DiscoveredBenchmarkFile discovered,
    required File executionFile,
    required TargetRuntime runtime,
    required int? trials,
    required bool forceRun,
    required bool isolateMode,
    required List<String> compilerFlags,
    required List<String> vmFlags,
  }) async {
    if (!sdk.isRuntimeAvailable(runtime)) {
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

    return execResult.suiteResult;
  }

  bool _hasUnstableBenchmark(BenchmarkSuiteResult suite) =>
      suite.benchmarks.any((b) => !b.metrics.isStable);

  String _resolveTargetPath(List<String> rest) {
    if (rest.isNotEmpty) return rest.first;
    if (Directory('benchmark').existsSync()) return 'benchmark';
    if (Directory('benchmarks').existsSync()) return 'benchmarks';
    return '.';
  }

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
  }) {
    if (format == 'json') {
      stdout.writeln(suite.toFormattedJson());
      return;
    }

    if (diffRef != null && diffRef.isNotEmpty) {
      final report = GitDiffReporter.renderGitDiffReport(
        gitRef: diffRef,
        filePath: outputPath,
        current: suite,
        title: title,
      );
      stdout.writeln(report);
    } else {
      final report = MarkdownReporter.renderSuite(suite, title: title);
      stdout.writeln(report);
    }
  }
}

/// The `validate` subcommand providing fast 2-second smoke verification.
final class ValidateCommand extends Command<int> {
  final DartSdk sdk;
  final TargetCompiler compiler;
  final BenchmarkProcessRunner processRunner;

  @override
  final String name = 'validate';

  @override
  final String description =
      'Quick smoke test across compilers to verify syntax and runtime '
      'health in ~2s.';

  ValidateCommand({
    required this.sdk,
    required this.compiler,
    required this.processRunner,
  }) {
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
    final targets = TargetRuntime.parseTargets(
      argResults!['target'] as List<String>,
    );
    final targetPath = argResults!.rest.isNotEmpty
        ? argResults!.rest.first
        : (Directory('benchmark').existsSync() ? 'benchmark' : '.');

    final files = BenchmarkDiscovery.discover(targetPath);
    if (files.isEmpty) {
      stderr.writeln('No benchmark files found at "$targetPath".');
      return 1;
    }

    final compilerFlags = argResults!['compiler-flag'] as List<String>;
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

    return allPassed ? 0 : 1;
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
final class ReportCommand extends Command<int> {
  @override
  final String name = 'report';

  @override
  final String description =
      'Render a formatted Markdown report from stored JSON telemetry.';

  ReportCommand() {
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
        : (argResults!['from-json'] as String);

    final file = File(inputPath);
    if (!file.existsSync()) {
      stderr.writeln('Telemetry file "$inputPath" does not exist.');
      return 1;
    }

    final title = argResults!['title'] as String?;
    final outputPath = argResults!['output'] as String?;

    try {
      final report = MarkdownReporter.renderFromFile(file, title: title);
      if (outputPath != null && outputPath.isNotEmpty) {
        final outFile = File(outputPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsStringSync('$report\n');
      } else {
        stdout.writeln(report);
      }
      return 0;
    } on Object catch (e) {
      stderr.writeln('Failed to render report: $e');
      return 1;
    }
  }
}

/// The `diff` subcommand computing isolated Before-vs-After delta tables.
final class DiffCommand extends Command<int> {
  @override
  final String name = 'diff';

  @override
  final String description =
      'Diff two JSON telemetry files or diff current telemetry against '
      'a Git ref.';

  DiffCommand() {
    argParser
      ..addOption(
        'baseline',
        abbr: 'b',
        mandatory: true,
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

  @override
  Future<int> run() async {
    final baselineArg = argResults!['baseline'] as String;
    final currentArg = argResults!['current'] as String;
    final targetFileArg = argResults!['target-file'] as String;
    final title = argResults!['title'] as String?;
    final outputPath = argResults!['output'] as String?;

    final currentFile = File(currentArg);
    if (!currentFile.existsSync()) {
      stderr.writeln('Current telemetry file "$currentArg" does not exist.');
      return 1;
    }

    String report;
    final baselineFile = File(baselineArg);
    if (baselineFile.existsSync()) {
      report = MarkdownReporter.renderDeltaFromFiles(
        baselineFile: baselineFile,
        currentFile: currentFile,
        title: title,
      );
    } else {
      final currentSuite = BenchmarkSuiteResult.loadFromFile(currentFile);
      report = GitDiffReporter.renderGitDiffReport(
        gitRef: baselineArg,
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
    return 0;
  }
}
