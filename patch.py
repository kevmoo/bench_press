import re

with open('lib/src/cli/command_runner.dart', 'r') as f:
    original = f.read()

# 1. Update RunCommand constructor
s = original.replace("""      ..addMultiOption(
        'vm-flag',
        help: 'Extra flags forwarded to Dart VM or Node/D8 runner.',
      )
      ..addOption(
        'format',""", """      ..addMultiOption(
        'vm-flag',
        help: 'Extra flags forwarded to Dart VM or Node/D8 runner.',
      )
      ..addMultiOption(
        'compare-sdk',
        help: 'Compare additional Dart SDKs (format: Label=Path).',
      )
      ..addOption(
        'format',""")

# 2. Update RunCommand run method
run_start = s.find("    final accumulated = await _executeDiscoveredFiles(files, targets);")
run_end = s.find("  Future<BenchmarkSuiteResult?> _executeDiscoveredFiles(")

new_run = """    final compareSdks = argResults!.multiOption('compare-sdk');
    final sdkMap = <String, DartSdk>{};
    if (compareSdks.isEmpty) {
      sdkMap['Default'] = sdk;
    } else {
      for (final opt in compareSdks) {
        final parts = opt.split('=');
        if (parts.length != 2) {
          stderr.writeln(
            'Invalid --compare-sdk format: "$opt". Expected Label=Path.',
          );
          return ExitCode.usage.code;
        }
        sdkMap[parts[0]] = DartSdk(customSdkPath: parts[1]);
      }
    }

    final processRunners = <String, BenchmarkProcessRunner>{};
    final compilers = <String, TargetCompiler>{};
    for (final entry in sdkMap.entries) {
      compilers[entry.key] = TargetCompiler(sdk: entry.value);
      processRunners[entry.key] = BenchmarkProcessRunner(sdk: entry.value);
    }

    final accumulated = await _executeDiscoveredFiles(files, targets, compilers, processRunners);
    if (accumulated == null || accumulated.benchmarks.isEmpty) {
      stderr.writeln('No benchmark results produced.');
      return ExitCode.software.code;
    }

    final noSave = argResults!.flag('no-save');
    final saveOption = argResults!.option('save');
    final outputPath = saveOption ?? argResults!.option('output')!;
    final shouldSave = !noSave;
    final format = argResults!.option('format')!;
    final title = argResults!.option('title') ??
        (compareSdks.isNotEmpty
            ? 'SDK Comparison Report'
            : null);
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
"""

s = s[:run_start] + new_run + s[run_end:]

# 3. Update _executeDiscoveredFiles
ed_start = s.find("  Future<BenchmarkSuiteResult?> _executeDiscoveredFiles(")
ed_end = s.find("  Future<BenchmarkSuiteResult?> _executeSingleTarget(")

new_ed = """  Future<BenchmarkSuiteResult?> _executeDiscoveredFiles(
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

    BenchmarkSuiteResult? accumulated;

    for (final discovered in files) {
      for (final runtime in targets) {
        // Alternate executions for identical thermal conditions.
        for (final entry in compilers.entries) {
          final label = entry.key;
          final compiler = entry.value;
          final processRunner = processRunners[label]!;
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
            compiler: compiler,
            processRunner: processRunner,
            sdkLabel: label,
          );

          if (result != null) {
            accumulated = accumulated == null
                ? result
                : accumulated.deepMerge(result);
          }
        }
      }
    }
    return accumulated;
  }
"""
s = s[:ed_start] + new_ed + s[ed_end:]

# 4. Update _executeSingleTarget
est_start = s.find("  Future<BenchmarkSuiteResult?> _executeSingleTarget({")
est_end = s.find("  bool _hasUnstableBenchmark(BenchmarkSuiteResult suite) =>")

new_est = """  Future<BenchmarkSuiteResult?> _executeSingleTarget({
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
    required String sdkLabel,
  }) async {
    if (!compiler.sdk.isRuntimeAvailable(runtime)) {
      stderr.writeln('Warning: Runtime "$runtime" is not available.');
      return null;
    }
    stdout.write(
      'Evaluating ${discovered.basename} on ${runtime.name} ($sdkLabel)... ',
    );

    final compilation = await compiler.compile(
      sourceFile: discovered.file,
      targetFile: executionFile,
      runtime: runtime,
      forceRun: forceRun,
      isolateMode: isolateMode,
      compilerFlags: compilerFlags,
    );

    if (!compilation.success) {
      stderr.writeln('Compilation failed for ${discovered.basename}:');
      stderr.writeln(compilation.errorMessage ?? compilation.stderr);
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

    final suiteResult = execResult.suiteResult!;
    final taggedBenchmarks = suiteResult.benchmarks
        .map((b) => b.copyWith(group: sdkLabel))
        .toList();

    return BenchmarkSuiteResult(
      version: suiteResult.version,
      timestamp: suiteResult.timestamp,
      environment: suiteResult.environment,
      benchmarks: taggedBenchmarks,
    );
  }

"""
s = s[:est_start] + new_est + s[est_end:]

# 5. Update _outputSuiteReport
out_start = s.find("  void _outputSuiteReport({")
out_end = s.find("    stdout.writeln(MarkdownReporter.renderSuite(suite, title: title));")


new_out = """  void _outputSuiteReport({
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

    if (isComparison) {
      final sdks = suite.groups;
      if (sdks.length >= 2) {
        final baseSdk = sdks[0];
        // Compare the first SDK against the last SDK.
        final currentSdk = sdks.last;
        final baseSuite = BenchmarkSuiteResult(
          version: suite.version,
          timestamp: suite.timestamp,
          environment: suite.environment,
          benchmarks: suite.getEntriesForGroup(baseSdk),
        );
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
        return;
      }
    }

    if (diffRef != null && diffRef.isNotEmpty) {
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
        } on FormatException {
          stderr.writeln(
            'Failed to parse baseline file $diffRef. Proceeding '
            'without comparison.',
          );
        }
      } else {
        final report = GitDiffReporter.renderGitDiffReport(
          gitRef: diffRef,
          filePath: outputPath,
          current: suite,
          title: title,
        );
        stdout.writeln(report);
        return;
      }
    }

"""
s = s[:out_start] + new_out + s[out_end:]

# 6. Fix ReportCommand and DiffCommand
s = s.replace("final class ReportCommand() extends Command<int> {", "final class ReportCommand extends Command<int> {")
s = s.replace("final class DiffCommand() extends Command<int> {", "final class DiffCommand extends Command<int> {")

with open('lib/src/cli/command_runner.dart', 'w') as f:
    f.write(s)

