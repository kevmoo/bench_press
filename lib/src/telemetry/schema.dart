import 'dart:convert';
import 'dart:io';

import '../runner.dart';
import '../stats/metrics.dart';

/// The current telemetry schema version.
const int currentTelemetrySchemaVersion = 1;

/// The standard default filename for benchmark telemetry output.
const String defaultTelemetryFileName = 'benchmark_results.json';

/// Captures machine and runtime environment details for telemetry provenance.
final class const EnvironmentInfo({
  /// The Dart runtime SDK version string.
  required final String dartVersion,

  /// The host operating system identifier (e.g. 'linux', 'macos', 'windows').
  required final String os,

  /// The host machine architecture (e.g. 'x64', 'arm64', 'ia32').
  required final String arch,

  /// Optional processor description or model name.
  final String? cpu,

  /// Optional machine hostname.
  final String? hostname,

  /// Additional environment metadata key-value pairs.
  final Map<String, Object?> extra = const {},
}) {
  /// Captures the current runtime host environment.
  factory current({
    String? cpu,
    String? hostname,
    Map<String, Object?> extra = const {},
  }) {
    var version = 'unknown';
    var os = 'unknown';
    var resolvedHostname = hostname;
    try {
      version = Platform.version;
      os = Platform.operatingSystem;
      resolvedHostname ??= Platform.localHostname;
    } on Object {
      // On web/JS runtimes dart:io Platform access is unsupported.
    }
    final arch = version.contains('arm64') || version.contains('aarch64')
        ? 'arm64'
        : (version.contains('x64') || version.contains('x86_64')
              ? 'x64'
              : 'unknown');
    return EnvironmentInfo(
      dartVersion: version,
      os: os,
      arch: arch,
      cpu: cpu,
      hostname: resolvedHostname,
      extra: extra,
    );
  }

  /// Converts the environment info to a JSON map.
  Map<String, Object?> toJson() => {
    'dart_version': dartVersion,
    'os': os,
    'arch': arch,
    if (cpu != null) 'cpu': cpu,
    if (hostname != null) 'hostname': hostname,
    if (extra.isNotEmpty) 'extra': extra,
  };

  /// Constructs an [EnvironmentInfo] from a JSON map.
  factory fromJson(Map<String, Object?> json) {
    return EnvironmentInfo(
      dartVersion: (json['dart_version'] as String?) ?? 'unknown',
      os: (json['os'] as String?) ?? 'unknown',
      arch: (json['arch'] as String?) ?? 'unknown',
      cpu: json['cpu'] as String?,
      hostname: json['hostname'] as String?,
      extra: (json['extra'] as Map<String, Object?>?) ?? const {},
    );
  }

  @override
  String toString() =>
      'EnvironmentInfo(dart: $dartVersion, os: $os, arch: $arch)';
}

/// Telemetry record for a single benchmark workload executed against a target.
final class const BenchmarkEntry({
  /// The unique benchmark workload name (e.g. 'json_decode/small').
  required final String name,

  /// The compilation/execution target (e.g. 'jit', 'aot', 'wasm', 'js').
  required final String target,

  /// The execution mode ('sync' or 'async').
  required final String mode,

  /// The number of measurement trial samples recorded.
  required final int samples,

  /// Distribution summary metrics computed from the trial samples.
  required final BenchmarkMetrics metrics,

  /// The raw trial sample latencies in nanoseconds.
  final List<double> rawTrialsNs = const [],

  /// Diagnostic metadata from the warmup convergence phase.
  final Map<String, Object?>? warmup,

  /// Calibrated batch iterations used in the inner measurement loop.
  final int? calibratedBatchIterations,
}) {
  /// The unique composite key identifying this benchmark and target pair.
  String get key => '$name:$target';

  /// Constructs a [BenchmarkEntry] from a [BenchmarkResult].
  factory fromResult(
    BenchmarkResult result, {
    String target = 'jit',
    String mode = 'sync',
  }) {
    return BenchmarkEntry(
      name: result.name,
      target: target,
      mode: mode,
      samples: result.rawTrialLatenciesNs.length,
      metrics: result.metrics,
      rawTrialsNs: List<double>.unmodifiable(result.rawTrialLatenciesNs),
      warmup: {
        'is_stable': result.warmupResult.isStable,
        'total_iterations': result.warmupResult.totalWarmupIterations,
        'converged_at': result.warmupResult.convergedAtIteration,
        'best_mmd': result.warmupResult.bestMmd,
        'elapsed_seconds': result.warmupResult.elapsedSeconds,
      },
      calibratedBatchIterations: result.calibratedBatch.iterations,
    );
  }

  /// Converts the entry to a canonical JSON map.
  Map<String, Object?> toJson() => {
    'name': name,
    'target': target,
    'mode': mode,
    'samples': samples,
    'metrics': metrics.toJson(),
    if (rawTrialsNs.isNotEmpty) 'raw_trials_ns': rawTrialsNs,
    if (warmup != null) 'warmup': warmup,
    if (calibratedBatchIterations != null)
      'calibrated_batch_iterations': calibratedBatchIterations,
  };

  /// Constructs a [BenchmarkEntry] from a JSON map with schema validation.
  factory fromJson(Map<String, Object?> json) {
    final rawName = json['name'];
    if (rawName is! String || rawName.isEmpty) {
      throw const FormatException(
        'Missing or invalid "name" in benchmark entry',
      );
    }
    final rawTarget = json['target'];
    if (rawTarget is! String || rawTarget.isEmpty) {
      throw const FormatException(
        'Missing or invalid "target" in benchmark entry',
      );
    }
    final mode = (json['mode'] as String?) ?? 'sync';
    final samples = (json['samples'] as num?)?.toInt() ?? 0;

    final rawMetrics = json['metrics'];
    if (rawMetrics is! Map<String, Object?>) {
      throw FormatException(
        'Missing "metrics" object for benchmark "$rawName"',
      );
    }
    final metrics = BenchmarkMetrics.fromJson(rawMetrics);

    final rawTrialsList = json['raw_trials_ns'];
    final rawTrials = rawTrialsList is List
        ? rawTrialsList.map((e) => (e as num).toDouble()).toList()
        : const <double>[];

    final warmup = json['warmup'] as Map<String, Object?>?;
    final calibratedBatch = (json['calibrated_batch_iterations'] as num?)
        ?.toInt();

    return BenchmarkEntry(
      name: rawName,
      target: rawTarget,
      mode: mode,
      samples: samples > 0 ? samples : rawTrials.length,
      metrics: metrics,
      rawTrialsNs: rawTrials,
      warmup: warmup,
      calibratedBatchIterations: calibratedBatch,
    );
  }

  @override
  String toString() =>
      'BenchmarkEntry($key: ${metrics.meanNs.toStringAsFixed(1)} ns, '
      '${metrics.opsPerSec.toStringAsFixed(0)} ops/s)';
}

/// A complete, standalone collection of benchmark telemetry results.
final class const BenchmarkSuiteResult({
  /// The schema version (must equal [currentTelemetrySchemaVersion]).
  final int version = currentTelemetrySchemaVersion,

  /// The timestamp when the benchmark suite execution completed.
  required final DateTime timestamp,

  /// The environment metadata where the benchmarks were executed.
  required final EnvironmentInfo environment,

  /// The list of benchmark entries recorded.
  required final List<BenchmarkEntry> benchmarks,
}) {
  /// Constructs a [BenchmarkSuiteResult] from a list of [BenchmarkResult]s.
  factory fromResults(
    List<BenchmarkResult> results, {
    EnvironmentInfo? environment,
    DateTime? timestamp,
    String target = 'jit',
    String mode = 'sync',
  }) {
    final entries = results
        .map((r) => BenchmarkEntry.fromResult(r, target: target, mode: mode))
        .toList();
    return BenchmarkSuiteResult(
      timestamp: timestamp ?? DateTime.now().toUtc(),
      environment: environment ?? EnvironmentInfo.current(),
      benchmarks: entries,
    );
  }

  /// Finds an entry matching [name] and [target], or returns `null`.
  BenchmarkEntry? findEntry(String name, String target) {
    for (final entry in benchmarks) {
      if (entry.name == name && entry.target == target) {
        return entry;
      }
    }
    return null;
  }

  /// Returns all entries for a specific workload [name] across all targets.
  List<BenchmarkEntry> getEntriesForBenchmark(String name) =>
      benchmarks.where((e) => e.name == name).toList();

  /// Returns all entries for a specific [target] across all workloads.
  List<BenchmarkEntry> getEntriesForTarget(String target) =>
      benchmarks.where((e) => e.target == target).toList();

  /// Returns distinct benchmark workload names sorted alphabetically.
  List<String> get benchmarkNames {
    final set = <String>{};
    for (final entry in benchmarks) {
      set.add(entry.name);
    }
    return set.toList()..sort();
  }

  /// Returns distinct target names sorted alphabetically.
  List<String> get targets {
    final set = <String>{};
    for (final entry in benchmarks) {
      set.add(entry.target);
    }
    return set.toList()..sort();
  }

  /// Performs a deterministic deep-merge of [other] into this suite result.
  ///
  /// Matching entries (keyed by `name:target`) from [other] replace existing
  /// entries. New entries are appended. The resulting entries are sorted
  /// deterministically by benchmark name and then target name.
  BenchmarkSuiteResult deepMerge(BenchmarkSuiteResult other) {
    final map = <String, BenchmarkEntry>{};
    for (final entry in benchmarks) {
      map[entry.key] = entry;
    }
    for (final entry in other.benchmarks) {
      map[entry.key] = entry;
    }

    final mergedList = map.values.toList()
      ..sort((a, b) {
        final nameComp = a.name.compareTo(b.name);
        if (nameComp != 0) return nameComp;
        return a.target.compareTo(b.target);
      });

    return BenchmarkSuiteResult(
      version: currentTelemetrySchemaVersion,
      timestamp: other.timestamp,
      environment: other.environment,
      benchmarks: mergedList,
    );
  }

  /// Converts the suite result to a canonical JSON map.
  Map<String, Object?> toJson() => {
    'version': version,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'environment': environment.toJson(),
    'benchmarks': benchmarks.map((b) => b.toJson()).toList(),
  };

  /// Serializes the suite result to formatted JSON text.
  String toFormattedJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// Parses a [BenchmarkSuiteResult] from a JSON map with schema validation.
  factory fromJson(Map<String, Object?> json) {
    final version = (json['version'] as num?)?.toInt();
    if (version != currentTelemetrySchemaVersion) {
      throw FormatException(
        'Unsupported telemetry schema version: $version '
        '(expected $currentTelemetrySchemaVersion)',
      );
    }

    final rawTimestamp = json['timestamp'];
    if (rawTimestamp is! String) {
      throw const FormatException(
        'Missing or invalid "timestamp" in telemetry',
      );
    }
    final timestamp = DateTime.parse(rawTimestamp);

    final rawEnv = json['environment'];
    if (rawEnv is! Map<String, Object?>) {
      throw const FormatException(
        'Missing or invalid "environment" in telemetry',
      );
    }
    final env = EnvironmentInfo.fromJson(rawEnv);

    final rawBenchmarks = json['benchmarks'];
    if (rawBenchmarks is! List) {
      throw const FormatException(
        'Missing or invalid "benchmarks" list in telemetry',
      );
    }

    final benchmarks = rawBenchmarks
        .map((e) => BenchmarkEntry.fromJson(e as Map<String, Object?>))
        .toList();

    return BenchmarkSuiteResult(
      version: currentTelemetrySchemaVersion,
      timestamp: timestamp,
      environment: env,
      benchmarks: benchmarks,
    );
  }

  /// Parses a [BenchmarkSuiteResult] from formatted JSON text.
  factory fromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Telemetry JSON root must be an object/map');
    }
    return BenchmarkSuiteResult.fromJson(decoded);
  }

  /// Saves the suite result to [file] as formatted JSON.
  void saveToFile(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${toFormattedJson()}\n');
  }

  /// Asynchronously saves the suite result to [file] as formatted JSON.
  Future<void> saveToFileAsync(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('${toFormattedJson()}\n');
  }

  /// Loads a [BenchmarkSuiteResult] from [file].
  static BenchmarkSuiteResult loadFromFile(File file) {
    if (!file.existsSync()) {
      throw FileSystemException('Telemetry file does not exist', file.path);
    }
    final content = file.readAsStringSync();
    return BenchmarkSuiteResult.fromJsonString(content);
  }

  /// Asynchronously loads a [BenchmarkSuiteResult] from [file].
  static Future<BenchmarkSuiteResult> loadFromFileAsync(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('Telemetry file does not exist', file.path);
    }
    final content = await file.readAsString();
    return BenchmarkSuiteResult.fromJsonString(content);
  }

  /// Merges this result into [file] if it exists, or saves it fresh.
  /// Returns the resulting merged [BenchmarkSuiteResult].
  BenchmarkSuiteResult mergeAndSave(File file) {
    if (file.existsSync()) {
      try {
        final existing = loadFromFile(file);
        final merged = existing.deepMerge(this);
        merged.saveToFile(file);
        return merged;
      } on FormatException {
        // If existing file is corrupted or incompatible, overwrite with fresh
        saveToFile(file);
        return this;
      }
    } else {
      saveToFile(file);
      return this;
    }
  }

  /// Asynchronously merges this result into [file] if it exists, or saves it
  /// fresh.
  Future<BenchmarkSuiteResult> mergeAndSaveAsync(File file) async {
    if (await file.exists()) {
      try {
        final existing = await loadFromFileAsync(file);
        final merged = existing.deepMerge(this);
        await merged.saveToFileAsync(file);
        return merged;
      } on FormatException {
        await saveToFileAsync(file);
        return this;
      }
    } else {
      await saveToFileAsync(file);
      return this;
    }
  }

  @override
  String toString() =>
      'BenchmarkSuiteResult(v$version, ${benchmarks.length} benchmarks, '
      'targets: ${targets.join(",")})';
}
