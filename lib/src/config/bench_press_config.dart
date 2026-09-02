import 'dart:io';

import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

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
  required final String output,
  required final bool isolateMode,
}) {
  static DefaultsConfig fromYaml(YamlMap? map) {
    if (map == null) {
      return DefaultsConfig(
        targets: ['jit', 'aot'],
        trials: 15,
        output: 'benchmark_results.json',
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
    var trials = 15;
    if (trialsNode != null) {
      if (trialsNode.value is! int) {
        throw SourceSpanException(
          'trials must be an integer.',
          trialsNode.span,
        );
      }
      trials = trialsNode.value as int;
    }

    final outputNode = map.nodes['output'];
    var output = 'benchmark_results.json';
    if (outputNode != null) {
      output = outputNode.value.toString();
    }

    final isolateNode = map.nodes['isolate_mode'];
    var isolateMode = false;
    if (isolateNode != null) {
      isolateMode = isolateNode.value == true;
    }

    return DefaultsConfig(
      targets: targets,
      trials: trials,
      output: output,
      isolateMode: isolateMode,
    );
  }
}

class MatrixConfig({
  required final Map<String, String> explicitBaseline,
  required final Map<String, Map<String, dynamic>> axes,
  final Map<String, String>? entrypoints,
}) {
  static MatrixConfig fromYaml(YamlMap? map) {
    if (map == null) {
      return MatrixConfig(explicitBaseline: {}, axes: {});
    }

    final baseline = _parseBaseline(map.nodes['baseline']);
    final axes = _parseAxes(map.nodes['axes']);
    final entrypoints = _parseEntrypoints(map.nodes['entrypoints']);

    return MatrixConfig(
      explicitBaseline: baseline,
      axes: axes,
      entrypoints: entrypoints,
    );
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

  static Map<String, String>? _parseEntrypoints(YamlNode? node) {
    if (node == null) return null;
    if (node is! YamlMap) {
      throw SourceSpanException('entrypoints must be a map.', node.span);
    }
    return {for (final key in node.keys) key.toString(): node[key].toString()};
  }

  List<MatrixCoordinate> generateCoordinates() {
    if (axes.isEmpty && entrypoints == null) {
      return [MatrixCoordinate({}, true)];
    }

    final allAxes = _buildAllAxes();
    final (:combinations, :resolvedValues) = _computeCartesian(allAxes);
    final baselineToMatch = explicitBaseline.isNotEmpty
        ? explicitBaseline
        : _computeImplicitBaseline(allAxes);

    return _buildCoordinates(combinations, resolvedValues, baselineToMatch);
  }

  List<MapEntry<String, Map<String, dynamic>>> _buildAllAxes() {
    final allAxes = axes.entries.toList();
    if (entrypoints != null && entrypoints!.isNotEmpty) {
      allAxes.add(MapEntry('entrypoint', entrypoints!));
    }
    return allAxes;
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
