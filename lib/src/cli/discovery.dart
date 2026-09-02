import 'dart:io';

import 'package:path/path.dart' as p;

/// Represents the detected structural category of a benchmark file.
@Deprecated('No longer used. All benchmark files are standalone executables.')
enum BenchmarkFileKind() {
  /// The file provides a standalone `main(...)` entrypoint.
  standaloneMain,

  /// The file declares/exports a top-level `benchmarks` variable or getter.
  benchmarksList,

  /// The file structure could not be definitively classified.
  unknown,
}

/// Represents a discovered benchmark file and its structural metadata.
final class const DiscoveredBenchmarkFile({
  /// The underlying Dart source file.
  required final File file,
}) {
  /// Absolute normalized path of the file.
  String get path => p.normalize(file.absolute.path);

  /// Basename of the file.
  String get basename => p.basename(file.path);

  @override
  String toString() => 'DiscoveredBenchmarkFile($path)';
}

/// Discovers benchmark files in repositories and directories.
abstract final class BenchmarkDiscovery() {
  /// File suffixes recognized as benchmark files during directory discovery.
  static const List<String> benchmarkSuffixes = [
    '_benchmark.dart',
    '_bench.dart',
  ];

  /// Discovers benchmark files within [targetPath] (which may be a specific
  /// file or a directory).
  ///
  /// If [targetPath] points to a file, it must have a `.dart` extension.
  /// If [targetPath] points to a directory, it recursively finds all files
  /// ending with `_benchmark.dart` or `_bench.dart`, ignoring hidden folders
  /// (prefixed with `.`) and `build` directories.
  ///
  /// Throws [FormatException] if [targetPath] points to a non-Dart file.
  /// Throws [PathNotFoundException] if [targetPath] does not exist.
  static List<DiscoveredBenchmarkFile> discover(
    String targetPath, {
    bool verbose = false,
  }) {
    final file = File(targetPath);
    if (file.existsSync()) {
      if (p.extension(targetPath) != '.dart') {
        throw FormatException('Target path is not a Dart file: "$targetPath".');
      }
      return [DiscoveredBenchmarkFile(file: file)];
    }

    final dir = Directory(targetPath);
    if (!dir.existsSync()) {
      throw PathNotFoundException(
        targetPath,
        const OSError(),
        'Target path does not exist: "$targetPath".',
      );
    }

    final results = <DiscoveredBenchmarkFile>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isIgnoredPath(entity.path, targetPath)) continue;

      if (_isBenchmarkFileName(entity.path)) {
        results.add(DiscoveredBenchmarkFile(file: entity));
      } else if (verbose) {
        stderr.writeln('Skipping non-benchmark file: ${entity.path}');
      }
    }

    results.sort((a, b) => a.path.compareTo(b.path));
    return results;
  }

  static bool _isBenchmarkFileName(String filePath) {
    final name = p.basename(filePath);
    for (final suffix in benchmarkSuffixes) {
      if (name.endsWith(suffix)) return true;
    }
    return false;
  }

  static bool _isIgnoredPath(String filePath, String targetPath) {
    if (p.extension(filePath) != '.dart') return true;
    final relPath = p.relative(filePath, from: targetPath);
    for (final s in p.split(p.normalize(relPath))) {
      if (s == '.' || s == '..') continue;
      if (s.startsWith('.') || s == 'build') {
        return true;
      }
    }
    return false;
  }
}
