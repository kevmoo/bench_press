import 'dart:io';

import 'markdown_reporter.dart';
import 'schema.dart';

/// Extracts baseline benchmark telemetry JSON records from Git history.
abstract final class GitBaselineExtractor {
  /// Extracts the raw file contents at [filePath] from git commit [gitRef].
  ///
  /// Returns `null` if git is unavailable, [gitRef] does not exist, [filePath]
  /// is not present at that commit, or the command exits with a non-zero code.
  static String? extractRaw({
    required String gitRef,
    required String filePath,
    String? workingDirectory,
  }) {
    try {
      final posixPath = filePath.replaceAll('\\', '/');
      final result = Process.runSync('git', [
        'show',
        '$gitRef:$posixPath',
      ], workingDirectory: workingDirectory);
      if (result.exitCode == 0) {
        final stdout = result.stdout;
        if (stdout is String && stdout.trim().isNotEmpty) {
          return stdout;
        }
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// Asynchronously extracts raw file contents from git history.
  static Future<String?> extractRawAsync({
    required String gitRef,
    required String filePath,
    String? workingDirectory,
  }) async {
    try {
      final posixPath = filePath.replaceAll('\\', '/');
      final result = await Process.run('git', [
        'show',
        '$gitRef:$posixPath',
      ], workingDirectory: workingDirectory);
      if (result.exitCode == 0) {
        final stdout = result.stdout;
        if (stdout is String && stdout.trim().isNotEmpty) {
          return stdout;
        }
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// Loads and parses a [BenchmarkSuiteResult] baseline from git history at
  /// [gitRef]:[filePath].
  ///
  /// Returns `null` if the baseline cannot be extracted or if the JSON fails
  /// schema validation.
  static BenchmarkSuiteResult? extractSuite({
    required String gitRef,
    required String filePath,
    String? workingDirectory,
  }) {
    final raw = extractRaw(
      gitRef: gitRef,
      filePath: filePath,
      workingDirectory: workingDirectory,
    );
    if (raw == null) return null;

    try {
      return BenchmarkSuiteResult.fromJsonString(raw);
    } on FormatException {
      return null;
    }
  }

  /// Asynchronously loads and parses a [BenchmarkSuiteResult] from git history.
  static Future<BenchmarkSuiteResult?> extractSuiteAsync({
    required String gitRef,
    required String filePath,
    String? workingDirectory,
  }) async {
    final raw = await extractRawAsync(
      gitRef: gitRef,
      filePath: filePath,
      workingDirectory: workingDirectory,
    );
    if (raw == null) return null;

    try {
      return BenchmarkSuiteResult.fromJsonString(raw);
    } on FormatException {
      return null;
    }
  }
}

/// Holds the comparison state between a Git baseline and current telemetry.
final class GitBaselineDiffResult {
  /// The Git reference (commit hash, branch, or tag) queried for baseline.
  final String gitRef;

  /// The target telemetry file path queried in git history.
  final String filePath;

  /// The extracted baseline suite result, or `null` if unavailable.
  final BenchmarkSuiteResult? baseline;

  /// The current working suite result.
  final BenchmarkSuiteResult current;

  /// Whether a valid baseline was successfully retrieved.
  bool get hasBaseline => baseline != null;

  const GitBaselineDiffResult({
    required this.gitRef,
    required this.filePath,
    required this.baseline,
    required this.current,
  });
}

/// Generates Git-backed Before-vs-After delta comparison reports.
abstract final class GitDiffReporter {
  /// Compares [current] suite against the baseline at [gitRef]:[filePath].
  static GitBaselineDiffResult loadDiff({
    required String gitRef,
    required String filePath,
    required BenchmarkSuiteResult current,
    String? workingDirectory,
  }) {
    final baseline = GitBaselineExtractor.extractSuite(
      gitRef: gitRef,
      filePath: filePath,
      workingDirectory: workingDirectory,
    );
    return GitBaselineDiffResult(
      gitRef: gitRef,
      filePath: filePath,
      baseline: baseline,
      current: current,
    );
  }

  /// Renders a Markdown delta report comparing [current] against [gitRef].
  ///
  /// If the baseline is missing or invalid, falls back to rendering a warning
  /// message along with the current suite summary table.
  static String renderGitDiffReport({
    required String gitRef,
    required String filePath,
    required BenchmarkSuiteResult current,
    String? workingDirectory,
    String? title,
  }) {
    final diff = loadDiff(
      gitRef: gitRef,
      filePath: filePath,
      current: current,
      workingDirectory: workingDirectory,
    );

    if (diff.hasBaseline) {
      return MarkdownReporter.renderDeltaTable(
        baseline: diff.baseline!,
        current: current,
        title: title ?? 'Git Baseline Delta: `$gitRef` ($filePath)',
        baselineLabel: 'Git ($gitRef)',
        currentLabel: 'Current',
      );
    } else {
      final buffer = StringBuffer();
      buffer.writeln(
        '### ${title ?? 'Benchmark Results (No Git Baseline Found)'}',
      );
      buffer.writeln();
      buffer.writeln(
        '> ⚠️ **Notice**: Could not locate a valid baseline telemetry file at '
        '`$gitRef:$filePath` in Git history. Showing current suite summary:',
      );
      buffer.writeln();
      buffer.writeln(MarkdownReporter.renderSummaryTable(current));
      return buffer.toString();
    }
  }
}
