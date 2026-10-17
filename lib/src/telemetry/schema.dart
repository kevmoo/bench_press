import 'dart:convert';
import 'dart:io';

import '../runner.dart';
import '../stats/metrics.dart';
import '../throughput.dart';

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

/// N-dimensional Cartesian benchmark coordinate mapping with typed getters for
/// well-known dimensions.
extension type const BenchmarkCoordinates._(Map<String, String> _map)
    implements Map<String, String> {
  /// Constructs a [BenchmarkCoordinates] instance.
  const new([Map<String, String> map = const {}]) : _map = map;

  /// Intra-file benchmark variant comparison group (set by `BenchmarkGroup`).
  static const String groupKey = 'group';

  /// Target compilation runtime (`jit`, `aot`, `wasm`, `js`).
  static const String runtimeKey = 'runtime';

  /// Alias for [runtimeKey].
  static const String targetKey = 'target';

  /// Dart SDK binary path or label to compile and run against.
  static const String sdkKey = 'sdk';

  /// Extra flags forwarded to `dart compile`.
  static const String compilerFlagsKey = 'compiler_flags';

  /// Extra flags forwarded to the Dart VM or JavaScript runner.
  static const String vmFlagsKey = 'vm_flags';

  /// Returns the group identifier, if present.
  String? get group => this[groupKey];

  /// Returns the SDK label or path, if present.
  String? get sdk => this[sdkKey];

  /// Returns the target runtime (`jit`, `aot`, `wasm`, `js`), if present.
  String? get runtime => this[runtimeKey] ?? this[targetKey];

  /// Returns extra compiler flags, if present.
  String? get compilerFlags => this[compilerFlagsKey];

  /// Returns extra VM flags, if present.
  String? get vmFlags => this[vmFlagsKey];
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

  /// N-dimensional matrix coordinates.
  final BenchmarkCoordinates coordinates = const BenchmarkCoordinates(),

  /// Whether this entry was designated as the baseline for its group.
  final bool isBaseline = false,

  /// Declared throughput processed per invocation (bytes or element count).
  final Throughput? throughput,

  /// The number of independent OS processes aggregated into this entry
  /// (default: 1).
  final int processes = 1,

  /// Per-process arithmetic mean latencies in nanoseconds when [processes] > 1.
  final List<double> processMeansNs = const [],

  /// Per-process raw trial sample latencies in nanoseconds when
  /// [processes] > 1.
  final List<List<double>> processTrialsNs = const [],
}) {
  /// Returns the statistically independent top-level samples for confidence
  /// interval estimation: [processMeansNs] when [processes] > 1 (hierarchical
  /// process means), or [rawTrialsNs] when [processes] == 1.
  List<double> get effectiveSamplesNs {
    if (processes > 1) {
      if (processMeansNs.isNotEmpty) return processMeansNs;
      if (processTrialsNs.isNotEmpty) {
        return [
          for (final proc in processTrialsNs)
            if (proc.isNotEmpty) _meanOf(proc),
        ];
      }
    }
    return rawTrialsNs;
  }

  static double _meanOf(List<double> values) {
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// Unique composite key identifying this workload and its matrix coordinate.
  String get key {
    if (coordinates.isEmpty) {
      return '$name:$target';
    }
    final sortedCoords = coordinates.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final coordStr = sortedCoords.map((e) => '${e.key}=${e.value}').join(',');
    return '$name:$target:$coordStr';
  }

  BenchmarkEntry copyWith({
    Map<String, String>? coordinates,
    bool? isBaseline,
  }) {
    return BenchmarkEntry(
      name: name,
      target: target,
      mode: mode,
      samples: samples,
      metrics: metrics,
      rawTrialsNs: rawTrialsNs,
      warmup: warmup,
      calibratedBatchIterations: calibratedBatchIterations,
      coordinates: coordinates != null
          ? BenchmarkCoordinates(coordinates)
          : this.coordinates,
      isBaseline: isBaseline ?? this.isBaseline,
      throughput: throughput,
      processes: processes,
      processMeansNs: processMeansNs,
      processTrialsNs: processTrialsNs,
    );
  }

  /// Constructs a [BenchmarkEntry] from a [BenchmarkResult].
  factory fromResult(
    BenchmarkResult result, {
    String target = 'jit',
    String? mode,
  }) {
    final coordinates = <String, String>{};
    if (result.group != null && result.group!.isNotEmpty) {
      coordinates[BenchmarkCoordinates.groupKey] = result.group!;
    }
    return BenchmarkEntry(
      name: result.name,
      target: target,
      mode: mode ?? result.mode,
      samples: result.rawTrialLatenciesNs.length,
      metrics: result.metrics,
      rawTrialsNs: List<double>.unmodifiable(result.rawTrialLatenciesNs),
      warmup: {
        'is_stable': result.warmupResult.isStable,
        'total_iterations': result.warmupResult.totalWarmupIterations,
        'converged_at': result.warmupResult.convergedAtIteration,
        'best_mmd': result.warmupResult.bestMmd,
        'elapsed_seconds': result.warmupResult.elapsedSeconds,
        if (result.warmupResult.estimatedOpNanoseconds.isFinite)
          'estimated_op_ns': result.warmupResult.estimatedOpNanoseconds,
      },
      calibratedBatchIterations: result.calibratedBatch.iterations,
      coordinates: BenchmarkCoordinates(coordinates),
      isBaseline: result.isBaseline,
      throughput: result.throughput,
    );
  }

  /// Aggregates [processEntries] from `P` independent OS processes into a
  /// single hierarchical [BenchmarkEntry].
  factory fromProcesses(List<BenchmarkEntry> processEntries) {
    if (processEntries.isEmpty) {
      throw ArgumentError.value(
        processEntries,
        'processEntries',
        'Cannot aggregate an empty list of process entries.',
      );
    }
    if (processEntries.length == 1) return processEntries.single;

    final first = processEntries.first;
    final processMeans = List<double>.unmodifiable([
      for (final e in processEntries)
        e.rawTrialsNs.isNotEmpty ? _meanOf(e.rawTrialsNs) : e.metrics.meanNs,
    ]);
    final processTrials = List<List<double>>.unmodifiable([
      for (final e in processEntries)
        e.rawTrialsNs.isNotEmpty
            ? List<double>.unmodifiable(e.rawTrialsNs)
            : List<double>.unmodifiable([e.metrics.meanNs]),
    ]);
    final pooledRawTrials = List<double>.unmodifiable([
      for (final e in processEntries) ...e.rawTrialsNs,
    ]);
    final totalSamples = processEntries.fold<int>(
      0,
      (sum, e) => sum + e.samples,
    );
    final allStable = processEntries.every(
      (e) => (e.warmup?['is_stable'] as bool?) ?? e.metrics.isStable,
    );
    final metrics = BenchmarkMetrics.fromProcesses(
      processTrials,
      isStable: allStable,
    );

    return BenchmarkEntry(
      name: first.name,
      target: first.target,
      mode: first.mode,
      samples: totalSamples,
      metrics: metrics,
      rawTrialsNs: pooledRawTrials,
      warmup: _aggregateWarmupMaps(processEntries, allStable: allStable),
      calibratedBatchIterations: first.calibratedBatchIterations,
      coordinates: first.coordinates,
      isBaseline: first.isBaseline,
      throughput: first.throughput,
      processes: processEntries.length,
      processMeansNs: processMeans,
      processTrialsNs: processTrials,
    );
  }

  static Map<String, Object?>? _aggregateWarmupMaps(
    List<BenchmarkEntry> forkEntries, {
    required bool allStable,
  }) {
    if (forkEntries.every((e) => e.warmup == null)) return null;
    var totalIterations = 0;
    var maxConvergedAt = 0;
    var maxBestMmd = 0.0;
    var totalElapsedSec = 0.0;
    final estimates = <double>[];
    for (final e in forkEntries) {
      final w = e.warmup;
      if (w == null) continue;
      totalIterations += (w['total_iterations'] as num?)?.toInt() ?? 0;
      final conv = (w['converged_at'] as num?)?.toInt() ?? 0;
      if (conv > maxConvergedAt) maxConvergedAt = conv;
      final mmd = (w['best_mmd'] as num?)?.toDouble() ?? 0.0;
      if (mmd.isFinite && mmd > maxBestMmd) maxBestMmd = mmd;
      totalElapsedSec += (w['elapsed_seconds'] as num?)?.toDouble() ?? 0.0;
      final est = (w['estimated_op_ns'] as num?)?.toDouble();
      if (est != null && est.isFinite && est > 0) {
        estimates.add(est);
      }
    }
    return {
      'is_stable': allStable,
      'total_iterations': totalIterations,
      'converged_at': maxConvergedAt,
      'best_mmd': maxBestMmd,
      'elapsed_seconds': totalElapsedSec,
      if (estimates.isNotEmpty) 'estimated_op_ns': _meanOf(estimates),
    };
  }

  /// Converts the entry to a canonical JSON map.
  Map<String, Object?> toJson() => {
    'name': name,
    'target': target,
    'mode': mode,
    'samples': samples,
    'metrics': metrics.toJson(),
    if (coordinates.isNotEmpty) 'coordinates': coordinates,
    if (isBaseline) 'is_baseline': isBaseline,
    if (throughput != null) 'throughput': throughput!.toJson(),
    if (rawTrialsNs.isNotEmpty) 'raw_trials_ns': rawTrialsNs,
    if (processes > 1) 'processes': processes,
    if (processMeansNs.isNotEmpty) 'process_means_ns': processMeansNs,
    if (processTrialsNs.isNotEmpty) 'process_trials_ns': processTrialsNs,
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
    final rawMetrics = json['metrics'];
    if (rawMetrics is! Map<String, Object?>) {
      throw FormatException(
        'Missing "metrics" object for benchmark "$rawName"',
      );
    }
    final metrics = BenchmarkMetrics.fromJson(rawMetrics);

    final mode = _parseMode(json['mode'], rawName);
    final rawTrials = _parseRawTrials(json['raw_trials_ns'], rawName);
    final samples = _parseSamples(json['samples'], rawTrials.length, rawName);
    final coordinates = _parseCoordinates(json['coordinates'], rawName);
    final isBaseline = _parseIsBaseline(json['is_baseline'], rawName);
    final warmup = _parseWarmup(json['warmup'], rawName);
    final calibratedBatch = _parseCalibratedBatch(
      json['calibrated_batch_iterations'],
      rawName,
    );
    final throughput = _parseThroughput(json['throughput'], rawName);
    final processTrials = _parseProcessTrials(
      json['process_trials_ns'] ?? json['fork_trials_ns'],
      rawName,
    );
    final processMeans = _parseProcessMeans(
      json['process_means_ns'] ?? json['fork_means_ns'],
      processTrials,
      rawName,
    );
    final processes = _parseProcesses(
      json['processes'] ?? json['forks'],
      processMeans.length,
      rawName,
    );

    return BenchmarkEntry(
      name: rawName,
      target: rawTarget,
      mode: mode,
      samples: samples,
      metrics: metrics,
      rawTrialsNs: rawTrials,
      warmup: warmup,
      calibratedBatchIterations: calibratedBatch,
      coordinates: coordinates,
      isBaseline: isBaseline,
      throughput: throughput,
      processes: processes,
      processMeansNs: processMeans,
      processTrialsNs: processTrials,
    );
  }

  static String _parseMode(Object? value, String name) => switch (value) {
    null => 'sync',
    'sync' || 'async' => value as String,
    final other => throw FormatException(
      'Invalid "mode": "$other" in benchmark "$name" '
      '(expected "sync" or "async")',
    ),
  };

  static List<double> _parseRawTrials(Object? value, String name) {
    if (value == null) return const <double>[];
    if (value is! List) {
      throw FormatException(
        'Invalid "raw_trials_ns" in benchmark "$name": expected List, '
        'got ${value.runtimeType}',
      );
    }
    return [
      for (final e in value)
        if (e is num)
          e.toDouble()
        else
          throw FormatException(
            'Invalid trial value: $e in benchmark "$name" (expected num)',
          ),
    ];
  }

  static int _parseSamples(Object? value, int fallback, String name) =>
      switch (value) {
        null => fallback,
        final int s when s >= 0 => s > 0 ? s : fallback,
        final other => throw FormatException(
          'Invalid "samples": $other in benchmark "$name" '
          '(expected non-negative integer)',
        ),
      };

  static BenchmarkCoordinates _parseCoordinates(Object? value, String name) {
    if (value == null) return const BenchmarkCoordinates();
    if (value is! Map) {
      throw FormatException(
        'Invalid "coordinates" in benchmark "$name": expected Map, '
        'got ${value.runtimeType}',
      );
    }
    final result = <String, String>{};
    for (final MapEntry(:key, :value) in value.entries) {
      if (key is String && value is String) {
        result[key] = value;
      } else {
        throw FormatException(
          'Invalid coordinate in benchmark "$name": $key=$value '
          '(expected String: String)',
        );
      }
    }
    return BenchmarkCoordinates(Map.unmodifiable(result));
  }

  static bool _parseIsBaseline(Object? value, String name) => switch (value) {
    null => false,
    final bool b => b,
    final other => throw FormatException(
      'Invalid "is_baseline" in benchmark "$name": expected bool, got $other',
    ),
  };

  static Map<String, Object?>? _parseWarmup(Object? value, String name) =>
      switch (value) {
        null => null,
        final Map<String, Object?> m => m,
        final other => throw FormatException(
          'Invalid "warmup" in benchmark "$name": expected Map, '
          'got ${other.runtimeType}',
        ),
      };

  static int? _parseCalibratedBatch(Object? value, String name) =>
      switch (value) {
        null => null,
        final int n when n >= 0 => n,
        final other => throw FormatException(
          'Invalid "calibrated_batch_iterations" in benchmark "$name": '
          'expected non-negative integer, got $other',
        ),
      };

  static Throughput? _parseThroughput(Object? value, String name) =>
      switch (value) {
        null => null,
        final Map<String, Object?> m => Throughput.fromJson(m),
        final other => throw FormatException(
          'Invalid "throughput" in benchmark "$name": expected Map, '
          'got ${other.runtimeType}',
        ),
      };

  static int _parseProcesses(
    Object? value,
    int processMeansLength,
    String name,
  ) => switch (value) {
    null => processMeansLength > 1 ? processMeansLength : 1,
    final int p when p >= 1 => p,
    final other => throw FormatException(
      'Invalid "processes": $other in benchmark "$name" '
      '(expected positive integer >= 1)',
    ),
  };

  static List<double> _parseProcessMeans(
    Object? value,
    List<List<double>> processTrials,
    String name,
  ) {
    if (value == null) {
      if (processTrials.length > 1) {
        return [
          for (final proc in processTrials)
            if (proc.isNotEmpty) _meanOf(proc),
        ];
      }
      return const <double>[];
    }
    if (value is! List) {
      throw FormatException(
        'Invalid "process_means_ns" in benchmark "$name": expected List, '
        'got ${value.runtimeType}',
      );
    }
    return [
      for (final e in value)
        if (e is num)
          e.toDouble()
        else
          throw FormatException(
            'Invalid process mean value: $e in benchmark "$name" '
            '(expected num)',
          ),
    ];
  }

  static List<List<double>> _parseProcessTrials(Object? value, String name) {
    if (value == null) return const <List<double>>[];
    if (value is! List) {
      throw FormatException(
        'Invalid "process_trials_ns" in benchmark "$name": expected List, '
        'got ${value.runtimeType}',
      );
    }
    return [for (final proc in value) _parseRawTrials(proc, name)];
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
    String? mode,
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

  /// Aggregates [processSuites] from `P` independent OS process invocations
  /// into a single hierarchical [BenchmarkSuiteResult].
  factory aggregateProcesses(List<BenchmarkSuiteResult> processSuites) {
    if (processSuites.isEmpty) {
      throw ArgumentError.value(
        processSuites,
        'processSuites',
        'Cannot aggregate an empty list of process suites.',
      );
    }
    if (processSuites.length == 1) return processSuites.single;

    final grouped = <String, List<BenchmarkEntry>>{};
    for (final suite in processSuites) {
      for (final entry in suite.benchmarks) {
        grouped.putIfAbsent(entry.key, () => <BenchmarkEntry>[]).add(entry);
      }
    }

    final aggregatedEntries = <BenchmarkEntry>[
      for (final entries in grouped.values)
        BenchmarkEntry.fromProcesses(entries),
    ];
    final last = processSuites.last;
    return BenchmarkSuiteResult(
      version: currentTelemetrySchemaVersion,
      timestamp: last.timestamp,
      environment: last.environment,
      benchmarks: aggregatedEntries,
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

  /// Returns distinct benchmark group names in order of appearance.
  List<String> get groups {
    final set = <String>{};
    for (final entry in benchmarks) {
      final g = entry.coordinates.group ?? entry.coordinates.sdk;
      if (g != null && g.isNotEmpty) {
        set.add(g);
      }
    }
    return set.toList();
  }

  /// Returns all entries belonging to [groupName].
  List<BenchmarkEntry> getEntriesForGroup(String groupName) =>
      benchmarks.where((e) {
        final g = e.coordinates.group ?? e.coordinates.sdk;
        return g == groupName;
      }).toList();

  /// Performs a deterministic deep-merge of [other] into this suite result.
  ///
  /// Matching entries (keyed by [BenchmarkEntry.key]: `name:target` or
  /// `name:target:coordStr`) from [other] replace existing entries. New entries
  /// are appended. The resulting entries are sorted deterministically by
  /// benchmark name and then target name.
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
