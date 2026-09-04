import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

enum _Dataset(final int size) {
  small(10),
  medium(100),
  large(1000),
}

void main() {
  group('BenchmarkMatrix & BenchmarkGroup.matrix', () {
    test(
      'creates groups with correct names, baseline, candidates, and throughput',
      () {
        final matrix = BenchmarkGroup.matrix<_Dataset>(
          cases: _Dataset.values,
          name: (d) => 'decode - ${d.name}',
          baseline: ('dart:convert', (d) => 'json_${d.size}'),
          candidates: {
            'codable': (d) => 'codable_${d.size}',
            'fast_parser': (d) => 'fast_${d.size}',
          },
          throughput: (d) => Throughput.bytes(d.size * 1024),
        );

        check(matrix.length).equals(3);
        check(matrix.cases).deepEquals(_Dataset.values);
        check(matrix.groups.length).equals(3);
        check(matrix.toString()).contains('BenchmarkMatrix<_Dataset>');

        for (var i = 0; i < _Dataset.values.length; i++) {
          final dataset = _Dataset.values[i];
          final group = matrix[i];

          check(group.name).equals('decode - ${dataset.name}');
          check(group.variants.length).equals(3);

          // Baseline checks
          final baseline = group.variants[0];
          check(baseline.name).equals('dart:convert');
          check(baseline.isBaseline).isTrue();
          check(baseline.group).equals('decode - ${dataset.name}');
          check(baseline.throughput).isNotNull();
          check((baseline.throughput as ByteThroughput).bytes)
              .equals(dataset.size * 1024);

          // Candidates checks
          final candidate1 = group.variants[1];
          check(candidate1.name).equals('codable');
          check(candidate1.isBaseline).isFalse();
          check(candidate1.group).equals('decode - ${dataset.name}');
          check((candidate1.throughput as ByteThroughput).bytes)
              .equals(dataset.size * 1024);

          final candidate2 = group.variants[2];
          check(candidate2.name).equals('fast_parser');
          check(candidate2.isBaseline).isFalse();
          check(candidate2.group).equals('decode - ${dataset.name}');
        }
      },
    );

    test(
      'passes parameterized inputs accurately to baseline and candidates',
      () {
        final receivedBaselineInputs = <int>[];
        final receivedCandidateInputs = <int>[];

        final matrix = BenchmarkGroup.matrix<int>(
          cases: [5, 15, 25],
          name: (n) => 'scale_$n',
          baseline: (
            'base',
            (n) {
              receivedBaselineInputs.add(n);
              return n * 2;
            },
          ),
          candidates: {
            'cand': (n) {
              receivedCandidateInputs.add(n);
              return n * 3;
            },
          },
        );

        for (final group in matrix) {
          for (final variant in group.variants) {
            variant.executeSync();
          }
        }

        check(receivedBaselineInputs).deepEquals([5, 15, 25]);
        check(receivedCandidateInputs).deepEquals([5, 15, 25]);
      },
    );

    test(
      'executes setup and teardown lifecycle hooks with parameterized inputs',
      () {
        final setupInputs = <String>[];
        final teardownInputs = <String>[];

        final matrix = BenchmarkGroup.matrix<String>(
          cases: ['alpha', 'beta'],
          name: (c) => 'case_$c',
          baseline: ('base', (c) => c.length),
          candidates: {'cand': (c) => c.toUpperCase()},
          setup: setupInputs.add,
          teardown: teardownInputs.add,
        );

        // For each group, we have 2 variants (base + cand).
        // Each variant invokes setup and teardown once.
        for (final group in matrix) {
          for (final variant in group.variants) {
            variant.setup?.call();
            variant.executeSync();
            variant.teardown?.call();
          }
        }

        check(setupInputs).deepEquals(['alpha', 'alpha', 'beta', 'beta']);
        check(teardownInputs).deepEquals(['alpha', 'alpha', 'beta', 'beta']);
      },
    );

    test('handles asynchronous actions seamlessly in matrix', () async {
      final asyncResults = <String>[];

      final matrix = BenchmarkGroup.matrix<String>(
        cases: ['async1', 'async2'],
        name: (c) => 'async_group_$c',
        baseline: (
          'async_base',
          (c) async {
            await Future<void>.delayed(Duration.zero);
            asyncResults.add('base_$c');
          },
        ),
        candidates: {
          'async_cand': (c) async {
            await Future<void>.delayed(Duration.zero);
            asyncResults.add('cand_$c');
          },
        },
      );

      for (final group in matrix) {
        for (final variant in group.variants) {
          await variant.executeAsync();
        }
      }

      check(asyncResults).deepEquals([
        'base_async1',
        'cand_async1',
        'base_async2',
        'cand_async2',
      ]);
    });

    test('matrix.report executes all variants and returns results', () async {
      var syncCalls = 0;
      final matrix = BenchmarkGroup.matrix<int>(
        cases: [1, 2],
        name: (n) => 'report_group_$n',
        baseline: ('base', (n) => syncCalls += n),
        candidates: {'cand': (n) => syncCalls += n * 10},
        config: const BenchmarkConfig(
          trials: 2,
          minWarmupIterations: 2,
          maxWarmupIterations: 4,
          targetBatchDuration: Duration(milliseconds: 1),
          forceRun: true,
        ),
      );

      final results = await matrix.report();
      check(results.length).equals(4); // 2 cases * 2 variants
      check(results[0].name).equals('base');
      check(results[0].group).equals('report_group_1');
      check(results[0].isBaseline).isTrue();

      check(results[1].name).equals('cand');
      check(results[1].group).equals('report_group_1');
      check(results[1].isBaseline).isFalse();

      check(results[2].name).equals('base');
      check(results[2].group).equals('report_group_2');
      check(results[2].isBaseline).isTrue();

      check(results[3].name).equals('cand');
      check(results[3].group).equals('report_group_2');
      check(results[3].isBaseline).isFalse();

      check(syncCalls).isGreaterThan(0);
    });

    test('supports empty cases gracefully', () async {
      final matrix = BenchmarkGroup.matrix<int>(
        cases: [],
        name: (n) => 'empty_$n',
        baseline: ('base', (n) => n),
        candidates: {'cand': (n) => n},
      );

      check(matrix.isEmpty).isTrue();
      check(matrix.length).equals(0);
      check(matrix.cases.isEmpty).isTrue();

      final results = await matrix.report();
      check(results.isEmpty).isTrue();
    });

    test(
      'optional throughput, setup, and teardown default to null gracefully',
      () {
        final matrix = BenchmarkGroup.matrix<int>(
          cases: [42],
          name: (n) => 'group_$n',
          baseline: ('base', (n) => n),
          candidates: {'cand': (n) => n * 2},
        );

        final group = matrix.first;
        for (final v in group.variants) {
          check(v.throughput).isNull();
          check(v.setup).isNull();
          check(v.teardown).isNull();
        }
      },
    );

    test('is directly compatible with mainBenchmarkSuite', () async {
      final tempDir = Directory.systemTemp.createTempSync('matrix_suite_test_');
      try {
        final outputFile = File(p.join(tempDir.path, 'matrix_output.json'));
        final args = [
          '--json-output',
          outputFile.path,
          '--validate',
          '--target',
          'jit',
        ];

        final matrix = BenchmarkGroup.matrix<String>(
          cases: ['mini', 'micro'],
          name: (c) => 'dataset_$c',
          baseline: ('base', (c) => c.length),
          candidates: {'cand': (c) => c.hashCode},
        );

        // Pass BenchmarkMatrix directly as the suite argument
        await mainBenchmarkSuite(matrix, args);

        check(outputFile.existsSync()).isTrue();
        final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
        check(suite.benchmarks.length).equals(4);

        final miniBase = suite.benchmarks.any(
          (b) => b.name == 'base' && b.coordinates.group == 'dataset_mini',
        );
        final miniCand = suite.benchmarks.any(
          (b) => b.name == 'cand' && b.coordinates.group == 'dataset_mini',
        );
        final microBase = suite.benchmarks.any(
          (b) => b.name == 'base' && b.coordinates.group == 'dataset_micro',
        );
        final microCand = suite.benchmarks.any(
          (b) => b.name == 'cand' && b.coordinates.group == 'dataset_micro',
        );

        check(miniBase).isTrue();
        check(miniCand).isTrue();
        check(microBase).isTrue();
        check(microCand).isTrue();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'is compatible when passed in a list alongside other benchmarks',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'matrix_list_test_',
        );
        try {
          final outputFile = File(
            p.join(tempDir.path, 'matrix_list_output.json'),
          );
          final args = [
            '--json-output',
            outputFile.path,
            '--validate',
            '--target',
            'jit',
          ];

          final matrix = BenchmarkGroup.matrix<int>(
            cases: [100],
            name: (n) => 'matrix_case_$n',
            baseline: ('m_base', (n) => n),
            candidates: {'m_cand': (n) => n + 1},
          );

          final singleVariant = BenchmarkVariant('standalone_var', () => 123);

          // Pass inside a list containing both BenchmarkVariant and Matrix
          await mainBenchmarkSuite([singleVariant, matrix], args);

          check(outputFile.existsSync()).isTrue();
          final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
          check(suite.benchmarks.length).equals(3); // 1 standalone + 2 matrix
          check(suite.findEntry('standalone_var', 'jit')).isNotNull();

          final caseBase = suite.benchmarks.any(
            (b) =>
                b.name == 'm_base' && b.coordinates.group == 'matrix_case_100',
          );
          final caseCand = suite.benchmarks.any(
            (b) =>
                b.name == 'm_cand' && b.coordinates.group == 'matrix_case_100',
          );
          check(caseBase).isTrue();
          check(caseCand).isTrue();
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'mainBenchmarkMatrix forwards seamlessly to mainBenchmarkSuite',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'matrix_entrypoint_test_',
        );
        try {
          final outputFile = File(
            p.join(tempDir.path, 'entrypoint_output.json'),
          );
          final args = [
            '--json-output',
            outputFile.path,
            '--validate',
            '--target',
            'jit',
          ];

          final matrix = BenchmarkGroup.matrix<int>(
            cases: [99],
            name: (n) => 'fwd_group_$n',
            baseline: ('fwd_base', (n) => n),
            candidates: {'fwd_cand': (n) => n},
          );

          await mainBenchmarkMatrix(matrix, args);

          check(outputFile.existsSync()).isTrue();
          final suite = BenchmarkSuiteResult.loadFromFile(outputFile);
          check(suite.benchmarks.length).equals(2);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
