import 'dart:io';

import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import '../config.dart' show BenchmarkConfig;
import '../telemetry/schema.dart' show defaultTelemetryFileName;

class BenchPressConfig({
  required final DefaultsConfig defaults,
  required final MatrixConfig matrix,
}) {
  static BenchPressConfig fromYaml(String yamlString, {Uri? sourceUrl}) {
    try {
      final doc = loadYamlDocument(yamlString, sourceUrl: sourceUrl);
      final root = doc.contents;
      if (root is! YamlMap) {
        throw SourceSpanException('Root must be a map.', root.span);
      }

      final defaultsMap = root['defaults'] as YamlMap?;
      final matrixMap = root['matrix'] as YamlMap?;

      final defaults = DefaultsConfig.fromYaml(defaultsMap);
      final matrix = MatrixConfig.fromYaml(matrixMap);

      return BenchPressConfig(defaults: defaults, matrix: matrix);
    } on SourceSpanException {
      rethrow;
    } catch (e) {
      throw FormatException('Invalid bench_press config: $e');
    }
  }

  static BenchPressConfig? loadFrom(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return fromYaml(file.readAsStringSync(), sourceUrl: file.uri);
  }

  List<MatrixCoordinate> generateCoordinates() {
    return matrix.generateCoordinates();
  }
}

class DefaultsConfig({
  required final List<String> targets,
  required final int trials,
  final int? maxTrials,
  final int processes = 1,
  final double threshold = 0.0,
  final String output = defaultTelemetryFileName,
  required final bool isolateMode,
}) {
  static DefaultsConfig fromYaml(YamlMap? map) {
    if (map == null) {
      return DefaultsConfig(
        targets: ['jit', 'aot'],
        trials: BenchmarkConfig.defaultTrials,
        maxTrials: null,
        processes: 1,
        threshold: 0.0,
        isolateMode: false,
      );
    }

    final targetsNode = map.nodes['targets'];
    var targets = <String>['jit', 'aot'];
    if (targetsNode is YamlList) {
      targets = targetsNode.nodes.map((n) => n.value.toString()).toList();
    } else if (targetsNode != null) {
      throw SourceSpanException('targets must be a list.', targetsNode.span);
    }

    final trialsNode = map.nodes['trials'];
    var trials = BenchmarkConfig.defaultTrials;
    if (trialsNode != null) {
      if (trialsNode.value is! int) {
        throw SourceSpanException(
          'trials must be an integer.',
          trialsNode.span,
        );
      }
      trials = trialsNode.value as int;
    }

    final maxTrialsNode = map.nodes['max_trials'] ?? map.nodes['max-trials'];
    int? maxTrials;
    if (maxTrialsNode != null) {
      if (maxTrialsNode.value is! int) {
        throw SourceSpanException(
          'max_trials must be an integer.',
          maxTrialsNode.span,
        );
      }
      maxTrials = maxTrialsNode.value as int;
    }

    final processes = _parseProcesses(
      map.nodes['processes'] ?? map.nodes['forks'],
    );
    final threshold = _parseThreshold(map.nodes['threshold']);

    final isolateNode = map.nodes['isolate_mode'];
    var isolateMode = false;
    if (isolateNode != null) {
      isolateMode = isolateNode.value == true;
    }

    return DefaultsConfig(
      targets: targets,
      trials: trials,
      maxTrials: maxTrials,
      processes: processes,
      threshold: threshold,
      output: _parseOutput(map.nodes['output']),
      isolateMode: isolateMode,
    );
  }

  /// Parses a relative equivalence threshold from a CLI option string (such as
  /// `'0.02'` or `'2%'`), returning `null` if invalid or outside `[0.0, 1.0)`.
  static double? tryParseThreshold(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final double? parsed;
    if (trimmed.endsWith('%')) {
      final numPart = double.tryParse(
        trimmed.substring(0, trimmed.length - 1).trim(),
      );
      parsed = numPart != null ? numPart / 100.0 : null;
    } else {
      parsed = double.tryParse(trimmed);
    }
    if (parsed == null || !parsed.isFinite || parsed < 0.0 || parsed >= 1.0) {
      return null;
    }
    return parsed;
  }

  static int _parseProcesses(YamlNode? node) {
    if (node == null) return 1;
    final value = node.value;
    if (value is int && value >= 1) return value;
    throw SourceSpanException(
      'processes must be a positive integer (>= 1).',
      node.span,
    );
  }

  static double _parseThreshold(YamlNode? node) {
    if (node == null) return 0.0;
    final value = node.value;
    if (value is num) {
      final d = value.toDouble();
      if (d.isFinite && d >= 0.0 && d < 1.0) return d;
    } else if (value is String) {
      final parsed = tryParseThreshold(value);
      if (parsed != null) return parsed;
    }
    throw SourceSpanException(
      'threshold must be a relative fraction >= 0.0 and < 1.0 '
      '(e.g. 0.02 or "2%").',
      node.span,
    );
  }

  static String _parseOutput(YamlNode? node) {
    if (node == null) return defaultTelemetryFileName;
    final value = node.value;
    if (value is String && value.isNotEmpty) return value;
    throw SourceSpanException('output must be a non-empty string.', node.span);
  }
}

class MatrixConfig({
  required final Map<String, String> explicitBaseline,
  required final Map<String, Map<String, dynamic>> axes,
}) {
  static MatrixConfig fromYaml(YamlMap? map) {
    if (map == null) {
      return MatrixConfig(explicitBaseline: {}, axes: {});
    }

    final baseline = _parseBaseline(map.nodes['baseline']);
    final axes = _parseAxes(map.nodes['axes']);

    return MatrixConfig(explicitBaseline: baseline, axes: axes);
  }

  static Map<String, String> _parseBaseline(YamlNode? node) {
    if (node == null) return {};
    if (node is! YamlMap) {
      throw SourceSpanException('baseline must be a map.', node.span);
    }
    return {for (final key in node.keys) key.toString(): node[key].toString()};
  }

  static Map<String, Map<String, dynamic>> _parseAxes(YamlNode? node) {
    if (node == null) return {};
    if (node is! YamlMap) {
      throw SourceSpanException('axes must be a map.', node.span);
    }
    final axes = <String, Map<String, dynamic>>{};
    for (final key in node.keys) {
      axes[key.toString()] = _parseSingleAxis(node.nodes[key]);
    }
    return axes;
  }

  static Map<String, dynamic> _parseSingleAxis(YamlNode? axisNode) {
    if (axisNode is YamlMap) {
      return {
        for (final k in axisNode.keys)
          k.toString(): axisNode[k]?.toString() ?? '',
      };
    }
    if (axisNode is YamlList) {
      return {
        for (final item in axisNode.nodes)
          item.value?.toString() ?? '': item.value?.toString() ?? '',
      };
    }
    throw SourceSpanException(
      'Axis must be a map or list.',
      axisNode?.span ?? SourceSpan(SourceLocation(0), SourceLocation(0), ''),
    );
  }

  List<MatrixCoordinate> generateCoordinates() {
    if (axes.isEmpty) {
      return [MatrixCoordinate({}, true)];
    }

    final allAxes = axes.entries.toList();
    final (:combinations, :resolvedValues) = _computeCartesian(allAxes);
    final baselineToMatch = explicitBaseline.isNotEmpty
        ? explicitBaseline
        : _computeImplicitBaseline(allAxes);

    return _buildCoordinates(combinations, resolvedValues, baselineToMatch);
  }

  static ({
    List<Map<String, String>> combinations,
    List<Map<String, String>> resolvedValues,
  })
  _computeCartesian(List<MapEntry<String, Map<String, dynamic>>> allAxes) {
    var combinations = <Map<String, String>>[{}];
    var resolvedValues = <Map<String, String>>[{}];

    for (final axis in allAxes) {
      final (:newCombos, :newResolved) = _expandAxis(
        axis,
        combinations,
        resolvedValues,
      );
      combinations = newCombos;
      resolvedValues = newResolved;
    }
    return (combinations: combinations, resolvedValues: resolvedValues);
  }

  static ({
    List<Map<String, String>> newCombos,
    List<Map<String, String>> newResolved,
  })
  _expandAxis(
    MapEntry<String, Map<String, dynamic>> axis,
    List<Map<String, String>> combinations,
    List<Map<String, String>> resolvedValues,
  ) {
    final axisName = axis.key;
    final axisMap = axis.value;
    final newCombos = <Map<String, String>>[];
    final newResolved = <Map<String, String>>[];

    for (var i = 0; i < combinations.length; i++) {
      final currentCombo = combinations[i];
      final currentResolved = resolvedValues[i];

      for (final entry in axisMap.entries) {
        final newCombo = Map<String, String>.from(currentCombo)
          ..[axisName] = entry.key;
        final newRes = Map<String, String>.from(currentResolved)
          ..[axisName] = entry.value.toString();
        newCombos.add(newCombo);
        newResolved.add(newRes);
      }
    }
    return (newCombos: newCombos, newResolved: newResolved);
  }

  static Map<String, String> _computeImplicitBaseline(
    List<MapEntry<String, Map<String, dynamic>>> allAxes,
  ) {
    final implicit = <String, String>{};
    for (final axis in allAxes) {
      if (axis.value.isNotEmpty) {
        implicit[axis.key] = axis.value.keys.first;
      }
    }
    return implicit;
  }

  static List<MatrixCoordinate> _buildCoordinates(
    List<Map<String, String>> combinations,
    List<Map<String, String>> resolvedValues,
    Map<String, String> baselineToMatch,
  ) {
    final results = <MatrixCoordinate>[];
    for (var i = 0; i < combinations.length; i++) {
      final combo = combinations[i];
      final values = resolvedValues[i];
      final isBaseline = _matchesBaseline(combo, baselineToMatch);
      results.add(MatrixCoordinate(combo, isBaseline, values));
    }
    return results;
  }

  static bool _matchesBaseline(
    Map<String, String> combo,
    Map<String, String> baselineToMatch,
  ) {
    for (final entry in baselineToMatch.entries) {
      if (combo[entry.key] != entry.value) return false;
    }
    return true;
  }
}

class MatrixCoordinate(
  /// The abstract labels for the coordinate (e.g. {sdk: stock})
  final Map<String, String> coordinates,
  final bool isBaseline, [
  Map<String, String>? resolvedValues,
]) {
  /// The resolved paths/flags (e.g. {sdk: /path/to/sdk})
  final Map<String, String> resolvedValues = resolvedValues ?? coordinates;
}
