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

    final baselineNode = map.nodes['baseline'];
    final baseline = <String, String>{};
    if (baselineNode is YamlMap) {
      for (final key in baselineNode.keys) {
        baseline[key.toString()] = baselineNode[key].toString();
      }
    } else if (baselineNode != null) {
      throw SourceSpanException('baseline must be a map.', baselineNode.span);
    }

    final axesNode = map.nodes['axes'];
    final axes = <String, Map<String, dynamic>>{};
    if (axesNode is YamlMap) {
      for (final key in axesNode.keys) {
        final axisName = key.toString();
        final axisValues = axesNode.nodes[key];

        final axisMap = <String, dynamic>{};
        if (axisValues is YamlMap) {
          for (final vKey in axisValues.keys) {
            axisMap[vKey.toString()] = axisValues[vKey]?.toString() ?? '';
          }
        } else if (axisValues is YamlList) {
          for (final value in axisValues.nodes) {
            final strVal = value.value?.toString() ?? '';
            axisMap[strVal] = strVal; // If it's a list, key == value
          }
        } else {
          throw SourceSpanException(
            'Axis must be a map or list.',
            axisValues!.span,
          );
        }
        axes[axisName] = axisMap;
      }
    } else if (axesNode != null) {
      throw SourceSpanException('axes must be a map.', axesNode.span);
    }

    final entrypointsNode = map.nodes['entrypoints'];
    Map<String, String>? entrypoints;
    if (entrypointsNode is YamlMap) {
      entrypoints = {};
      for (final key in entrypointsNode.keys) {
        entrypoints[key.toString()] = entrypointsNode[key].toString();
      }
    } else if (entrypointsNode != null) {
      throw SourceSpanException(
        'entrypoints must be a map.',
        entrypointsNode.span,
      );
    }

    return MatrixConfig(
      explicitBaseline: baseline,
      axes: axes,
      entrypoints: entrypoints,
    );
  }

  List<MatrixCoordinate> generateCoordinates() {
    // If no axes are defined, return a single empty coordinate
    if (axes.isEmpty && entrypoints == null) {
      return [MatrixCoordinate({}, true)];
    }

    final allAxes = axes.entries.toList();
    if (entrypoints != null && entrypoints!.isNotEmpty) {
      allAxes.add(MapEntry('entrypoint', entrypoints!));
    }

    var combinations = <Map<String, String>>[{}];
    var resolvedValues = <Map<String, String>>[{}];

    for (var axis in allAxes) {
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
      combinations = newCombos;
      resolvedValues = newResolved;
    }

    // Determine the implicit baseline if not explicit
    final implicitBaseline = <String, String>{};
    for (var axis in allAxes) {
      if (axis.value.isNotEmpty) {
        implicitBaseline[axis.key] = axis.value.keys.first;
      }
    }

    final baselineToMatch = explicitBaseline.isNotEmpty
        ? explicitBaseline
        : implicitBaseline;

    final results = <MatrixCoordinate>[];
    for (var i = 0; i < combinations.length; i++) {
      final combo = combinations[i];
      final values = resolvedValues[i];

      // Check if baseline
      var isBaseline = true;
      for (final key in baselineToMatch.keys) {
        if (combo[key] != baselineToMatch[key]) {
          isBaseline = false;
          break;
        }
      }
      results.add(MatrixCoordinate(combo, isBaseline, values));
    }

    return results;
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
