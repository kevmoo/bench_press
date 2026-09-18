import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  group('GitBaselineExtractor & GitDiffReporter', () {
    test('extractRaw and extractSuite handle missing refs cleanly', () {
      final nonExistentRef = GitBaselineExtractor.extractRaw(
        gitRef: 'non_existent_ref_99999',
        filePath: 'pubspec.yaml',
      );
      check(nonExistentRef).isNull();

      final nonExistentFile = GitBaselineExtractor.extractRaw(
        gitRef: 'HEAD',
        filePath: 'non_existent_file_99999.json',
      );
      check(nonExistentFile).isNull();

      final nonJsonSuite = GitBaselineExtractor.extractSuite(
        gitRef: 'HEAD',
        filePath: 'pubspec.yaml',
      );
      check(nonJsonSuite).isNull();
    });

    test('extractSuite and renderGitDiffReport extract baseline', () {
      _initGitRepo(d.sandbox);

      final baseEntry = _createEntry('crypto_hash', 'aot', 100.0);
      final baseSuite = createSampleSuite(benchmarks: [baseEntry]);

      File(d.path('benchmark_results.json'))
          .writeAsStringSync(baseSuite.toFormattedJson());

      _commitAll(d.sandbox, 'baseline commit');

      final extracted = GitBaselineExtractor.extractSuite(
        gitRef: 'HEAD',
        filePath: 'benchmark_results.json',
        workingDirectory: d.sandbox,
      );

      check(extracted).isNotNull();
      check(extracted!.benchmarks.length).equals(1);
      check(extracted.benchmarks.first.key).equals('crypto_hash:aot');

      final curEntry = _createEntry('crypto_hash', 'aot', 50.0);
      final curSuite = createSampleSuite(
        benchmarks: [curEntry],
        timestamp: '2026-08-30T01:00:00.000Z',
      );

      final report = GitDiffReporter.renderGitDiffReport(
        gitRef: 'HEAD',
        filePath: 'benchmark_results.json',
        current: curSuite,
        workingDirectory: d.sandbox,
      );

      check(report).contains('Git Baseline Delta');
      check(report).contains('crypto_hash');
      check(report).contains('2.00x');
      check(report).contains('🚀 Faster');
      check(report).contains('<!-- mdformat off(prevent table wrapping) -->');
      check(report).contains('<!-- mdformat on -->');
    });

    test('renderGitDiffReport falls back when baseline is missing', () {
      final curSuite = createSampleSuite(
        benchmarks: [_createEntry('crypto_hash', 'aot', 50.0)],
        timestamp: '2026-08-30T01:00:00.000Z',
      );

      final report = GitDiffReporter.renderGitDiffReport(
        gitRef: 'invalid_git_ref',
        filePath: 'benchmark_results.json',
        current: curSuite,
      );

      check(report).contains('No Git Baseline Found');
      check(report).contains('⚠️ **Notice**');
      check(report).contains('crypto_hash');
    });

    test('async git extraction functions work properly', () async {
      _initGitRepo(d.sandbox);

      final suite = createSampleSuite(
        benchmarks: [_createEntry('sort_int', 'wasm', 80.0)],
      );

      await d.file('results.json', suite.toFormattedJson()).create();
      _commitAll(d.sandbox, 'add results.json');

      final extractedRaw = await GitBaselineExtractor.extractRawAsync(
        gitRef: 'HEAD',
        filePath: 'results.json',
        workingDirectory: d.sandbox,
      );
      check(extractedRaw).isNotNull();

      final extractedSuite = await GitBaselineExtractor.extractSuiteAsync(
        gitRef: 'HEAD',
        filePath: 'results.json',
        workingDirectory: d.sandbox,
      );
      check(extractedSuite).isNotNull();
      check(extractedSuite!.benchmarks.first.key).equals('sort_int:wasm');
    });
  });
}

void _initGitRepo(String workingDir) {
  Process.runSync('git', ['init', '-b', 'main'], workingDirectory: workingDir);
  Process.runSync('git', [
    'config',
    'user.email',
    'tester@example.com',
  ], workingDirectory: workingDir);
  Process.runSync('git', [
    'config',
    'user.name',
    'Tester',
  ], workingDirectory: workingDir);
}

void _commitAll(String workingDir, String message) {
  Process.runSync('git', ['add', '.'], workingDirectory: workingDir);
  Process.runSync('git', [
    'commit',
    '-m',
    message,
  ], workingDirectory: workingDir);
}

BenchmarkEntry _createEntry(String name, String target, double meanNs) =>
    createSampleEntry(
      name: name,
      target: target,
      samples: 15,
      metrics: createSampleMetrics(
        meanNs: meanNs,
        medianNs: meanNs,
        minNs: meanNs * 0.95,
        maxNs: meanNs * 1.1,
        stddevNs: meanNs * 0.05,
        cv: 0.05,
        p95Ns: meanNs * 1.05,
        p99Ns: meanNs * 1.08,
        opsPerSec: 1e9 / meanNs,
      ),
      rawTrialsNs: [meanNs * 0.95, meanNs, meanNs * 1.05],
    );
