import 'dart:io';

import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Telemetry & Serialization', () {
    test('EnvironmentInfo serializes and deserializes cleanly', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
        cpu: 'AMD EPYC',
        hostname: 'cloudtop-1',
        extra: {'ci': true},
      );

      final json = env.toJson();
      check(json['dart_version']).equals('3.14.0');
      check(json['os']).equals('linux');
      check(json['arch']).equals('x64');
      check(json['cpu']).equals('AMD EPYC');
      check(json['hostname']).equals('cloudtop-1');

      final deserialized = EnvironmentInfo.fromJson(json);
      check(deserialized.dartVersion).equals('3.14.0');
      check(deserialized.os).equals('linux');
      check(deserialized.arch).equals('x64');
      check(deserialized.cpu).equals('AMD EPYC');
      check(deserialized.hostname).equals('cloudtop-1');
      check(deserialized.extra['ci']).equals(true);

      final current = EnvironmentInfo.current();
      check(current.dartVersion).isNotEmpty();
      check(current.os).isNotEmpty();
    });

    test('BenchmarkMetrics JSON round-trip preserves properties', () {
      const metrics = BenchmarkMetrics(
        meanNs: 125.5,
        medianNs: 124.0,
        minNs: 120.0,
        maxNs: 135.0,
        stddevNs: 3.5,
        cv: 0.0278,
        p95Ns: 132.0,
        p99Ns: 134.5,
        opsPerSec: 7968127.4,
        isStable: true,
      );

      final json = metrics.toJson();
      final deserialized = BenchmarkMetrics.fromJson(json);

      check(deserialized.meanNs).equals(125.5);
      check(deserialized.medianNs).equals(124.0);
      check(deserialized.minNs).equals(120.0);
      check(deserialized.maxNs).equals(135.0);
      check(deserialized.stddevNs).equals(3.5);
      check(deserialized.cv).equals(0.0278);
      check(deserialized.p95Ns).equals(132.0);
      check(deserialized.p99Ns).equals(134.5);
      check(deserialized.opsPerSec).equals(7968127.4);
      check(deserialized.isStable).isTrue();
    });

    test('BenchmarkEntry creation, validation and serialization', () {
      const metrics = BenchmarkMetrics(
        meanNs: 500.0,
        medianNs: 495.0,
        minNs: 480.0,
        maxNs: 530.0,
        stddevNs: 10.0,
        cv: 0.02,
        p95Ns: 520.0,
        p99Ns: 528.0,
        opsPerSec: 2000000.0,
        isStable: true,
      );

      const entry = BenchmarkEntry(
        name: 'crypto/sha256',
        target: 'wasm',
        mode: 'sync',
        samples: 15,
        metrics: metrics,
        rawTrialsNs: [480.0, 490.0, 500.0, 510.0, 520.0],
        warmup: {'is_stable': true, 'total_iterations': 45},
        calibratedBatchIterations: 2000,
      );

      check(entry.key).equals('crypto/sha256:wasm');

      final json = entry.toJson();
      check(json['name']).equals('crypto/sha256');
      check(json['target']).equals('wasm');
      check(json['mode']).equals('sync');
      check(json['samples']).equals(15);
      check(json['calibrated_batch_iterations']).equals(2000);

      final deserialized = BenchmarkEntry.fromJson(json);
      check(deserialized.name).equals('crypto/sha256');
      check(deserialized.target).equals('wasm');
      check(deserialized.rawTrialsNs.length).equals(5);
      check(deserialized.metrics.meanNs).equals(500.0);
      check(deserialized.calibratedBatchIterations).equals(2000);

      // Validation errors
      check(() => BenchmarkEntry.fromJson({'target': 'wasm'}))
          .throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({'name': 'foo'}))
          .throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({'name': 'foo', 'target': 'wasm'}))
          .throws<FormatException>();

      final validBase = {
        'name': 'foo',
        'target': 'jit',
        'metrics': metrics.toJson(),
      };

      check(() => BenchmarkEntry.fromJson({...validBase, 'mode': 'fast'}))
          .throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({...validBase, 'coordinates': 'bad'}))
          .throws<FormatException>();
      check(
        () => BenchmarkEntry.fromJson({
          ...validBase,
          'coordinates': {'sdk': 123},
        }),
      ).throws<FormatException>();
      check(
        () => BenchmarkEntry.fromJson({...validBase, 'raw_trials_ns': 'bad'}),
      ).throws<FormatException>();
      check(
        () => BenchmarkEntry.fromJson({
          ...validBase,
          'raw_trials_ns': ['not_a_num'],
        }),
      ).throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({...validBase, 'samples': -1}))
          .throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({...validBase, 'samples': 'ten'}))
          .throws<FormatException>();
      check(
        () => BenchmarkEntry.fromJson({...validBase, 'is_baseline': 'true'}),
      ).throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({...validBase, 'warmup': 'bad'}))
          .throws<FormatException>();
      check(
        () => BenchmarkEntry.fromJson({
          ...validBase,
          'calibrated_batch_iterations': -5,
        }),
      ).throws<FormatException>();
      check(() => BenchmarkEntry.fromJson({...validBase, 'throughput': 'bad'}))
          .throws<FormatException>();
    });

    test('BenchmarkSuiteResult rejects incompatible schema versions', () {
      final invalidJson = {
        'version': 999,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'environment': {'dart_version': '3.14.0', 'os': 'linux', 'arch': 'x64'},
        'benchmarks': <Object?>[],
      };

      check(() => BenchmarkSuiteResult.fromJson(invalidJson))
          .throws<FormatException>();
    });

    test('Deterministic deepMerge merges sweeps with sorted output', () {
      const env = EnvironmentInfo(
        dartVersion: '3.14.0',
        os: 'linux',
        arch: 'x64',
      );

      final entryJit1 = _createEntry('json_decode', 'jit', 100.0);
      final entryWasm1 = _createEntry('json_decode', 'wasm', 80.0);
      final entryAot1 = _createEntry('crypto_hash', 'aot', 50.0);

      final suite1 = BenchmarkSuiteResult(
        version: currentTelemetrySchemaVersion,
        timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
        environment: env,
        benchmarks: [entryJit1, entryWasm1, entryAot1],
      );

      final entryWasm2 = _createEntry('json_decode', 'wasm', 75.0);
      final entryAot2 = _createEntry('json_decode', 'aot', 60.0);
      final entryZ = _createEntry('z_workload', 'jit', 200.0);

      final suite2 = BenchmarkSuiteResult(
        version: currentTelemetrySchemaVersion,
        timestamp: DateTime.parse('2026-08-30T02:00:00.000Z'),
        environment: env,
        benchmarks: [entryWasm2, entryAot2, entryZ],
      );

      final merged = suite1.deepMerge(suite2);

      check(merged.benchmarks.length).equals(5);
      check(merged.timestamp)
          .equals(DateTime.parse('2026-08-30T02:00:00.000Z'));

      final keys = merged.benchmarks.map((b) => b.key).toList();
      check(keys).deepEquals([
        'crypto_hash:aot',
        'json_decode:aot',
        'json_decode:jit',
        'json_decode:wasm',
        'z_workload:jit',
      ]);

      final wasmEntry = merged.findEntry('json_decode', 'wasm');
      check(wasmEntry).isNotNull();
      check(wasmEntry!.metrics.meanNs).equals(75.0);

      check(merged.benchmarkNames)
          .deepEquals(['crypto_hash', 'json_decode', 'z_workload']);
      check(merged.targets).deepEquals(['aot', 'jit', 'wasm']);
      check(merged.getEntriesForBenchmark('json_decode').length).equals(3);
      check(merged.getEntriesForTarget('aot').length).equals(2);
    });

    test('File persistence: saveToFile, loadFromFile, and mergeAndSave', () {
      final tempDir = Directory.systemTemp.createTempSync('bench_press_test_');
      try {
        final telemetryFile = File('${tempDir.path}/benchmark_results.json');
        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );

        final initialEntry = _createEntry('workload_a', 'jit', 100.0);
        final initialSuite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
          environment: env,
          benchmarks: [initialEntry],
        );

        initialSuite.saveToFile(telemetryFile);
        check(telemetryFile.existsSync()).isTrue();

        final loaded = BenchmarkSuiteResult.loadFromFile(telemetryFile);
        check(loaded.benchmarks.length).equals(1);
        check(loaded.benchmarks.first.key).equals('workload_a:jit');

        final secondEntry = _createEntry('workload_a', 'aot', 40.0);
        final secondSuite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T02:00:00.000Z'),
          environment: env,
          benchmarks: [secondEntry],
        );

        final mergedResult = secondSuite.mergeAndSave(telemetryFile);
        check(mergedResult.benchmarks.length).equals(2);

        final reloaded = BenchmarkSuiteResult.loadFromFile(telemetryFile);
        check(reloaded.benchmarks.length).equals(2);
        check(reloaded.findEntry('workload_a', 'jit')).isNotNull();
        check(reloaded.findEntry('workload_a', 'aot')).isNotNull();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
    test(
      'toString formatting on telemetry models produces clean descriptions',
      () {
        const env = EnvironmentInfo(
          dartVersion: '3.14.0',
          os: 'linux',
          arch: 'x64',
        );
        check(env.toString()).contains('EnvironmentInfo(dart: 3.14.0');

        const metrics = BenchmarkMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 90.0,
          maxNs: 110.0,
          stddevNs: 5.0,
          cv: 0.05,
          p95Ns: 108.0,
          p99Ns: 109.0,
          opsPerSec: 10000000.0,
          isStable: true,
        );
        check(metrics.toString()).contains('BenchmarkMetrics(');
        check(metrics.toString()).contains('mean: 100.0 ns');

        final entry = _createEntry('sample_task', 'jit', 100.0);
        check(entry.toString()).contains('BenchmarkEntry(sample_task:jit');

        final suite = BenchmarkSuiteResult(
          version: currentTelemetrySchemaVersion,
          timestamp: DateTime.parse('2026-08-30T01:00:00.000Z'),
          environment: env,
          benchmarks: [entry],
        );
        check(suite.toString()).contains('BenchmarkSuiteResult(v1');
      },
    );

    test(
      'BenchmarkEntry preserves group, isBaseline, and throughput in JSON',
      () {
        const metrics = BenchmarkMetrics(
          meanNs: 100.0,
          medianNs: 100.0,
          minNs: 90.0,
          maxNs: 110.0,
          stddevNs: 5.0,
          cv: 0.05,
          p95Ns: 108.0,
          p99Ns: 109.0,
          opsPerSec: 10000000.0,
          isStable: true,
        );

        const entry = BenchmarkEntry(
          name: 'grouped_task',
          target: 'aot',
          mode: 'sync',
          samples: 10,
          metrics: metrics,
          coordinates: {'group': 'CryptoGroup'},
          isBaseline: true,
          throughput: Throughput.bytes(1024),
        );

        final json = entry.toJson();
        check(json['coordinates'] as Map?)
            .isNotNull()
            .deepEquals({'group': 'CryptoGroup'});
        check(json['is_baseline']).equals(true);
        check(json['throughput']).isNotNull();

        final deserialized = BenchmarkEntry.fromJson(json);
        check(deserialized.coordinates['group']).equals('CryptoGroup');
        check(deserialized.isBaseline).isTrue();
        check(deserialized.throughput).equals(const Throughput.bytes(1024));
      },
    );

    test(
      'AsyncBenchmark results serialize mode: async in JSON telemetry',
      () async {
        final benchmark = _TestAsyncBenchmark('async_task');
        final result = await BenchmarkRunner.runAsync(benchmark);
        check(result.mode).equals('async');

        final entry = BenchmarkEntry.fromResult(result, target: 'jit');
        check(entry.mode).equals('async');

        final json = entry.toJson();
        check(json['mode']).equals('async');

        final suite = BenchmarkSuiteResult.fromResults([result], target: 'jit');
        final suiteJson = suite.toJson();
        final benchmarksJson = suiteJson['benchmarks'] as List;
        check((benchmarksJson.first as Map)['mode']).equals('async');
      },
    );
  });
}

final class _TestAsyncBenchmark(super.name) extends AsyncBenchmark {
  this
    : super(
        config: const BenchmarkConfig(
          trials: 1,
          minWarmupIterations: 1,
          maxWarmupIterations: 2,
          targetBatchDuration: Duration(milliseconds: 1),
          forceRun: true,
        ),
      );

  @override
  Future<void> run() async {
    Blackhole.consume(1);
  }
}

BenchmarkEntry _createEntry(String name, String target, double meanNs) {
  final metrics = BenchmarkMetrics(
    meanNs: meanNs,
    medianNs: meanNs,
    minNs: meanNs * 0.95,
    maxNs: meanNs * 1.1,
    stddevNs: meanNs * 0.05,
    cv: 0.05,
    p95Ns: meanNs * 1.05,
    p99Ns: meanNs * 1.08,
    opsPerSec: 1e9 / meanNs,
    isStable: true,
  );
  return BenchmarkEntry(
    name: name,
    target: target,
    mode: 'sync',
    samples: 15,
    metrics: metrics,
    rawTrialsNs: [meanNs * 0.95, meanNs, meanNs * 1.05],
  );
}
