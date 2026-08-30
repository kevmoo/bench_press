import 'dart:io';

import 'package:path/path.dart' as p;

/// Represents a supported benchmark compilation and execution runtime target.
enum TargetRuntime(
  /// The canonical CLI name for this runtime target.
  final String name,
) {
  /// Dart VM Just-In-Time execution (standard `dart run` or in-isolate).
  jit('jit'),

  /// Ahead-Of-Time native compiled executable (`dart compile exe -O3`).
  aot('aot'),

  /// WebAssembly Garbage Collection compiled artifact (`dart compile wasm`).
  wasm('wasm'),

  /// JavaScript compiled artifact (`dart compile js -O4`).
  js('js');

  /// Attempts to parse a runtime target from [name].
  static TargetRuntime? tryParse(String name) {
    final lower = name.trim().toLowerCase();
    for (final target in TargetRuntime.values) {
      if (target.name == lower) return target;
    }
    return null;
  }

  /// Parses a collection of raw CLI target arguments or comma-separated tokens.
  ///
  /// Supports `'all'` to select all available targets.
  static List<TargetRuntime> parseTargets(List<String> rawTokens) {
    final results = <TargetRuntime>{};
    for (final token in rawTokens) {
      _parseTokenInto(token, results);
    }
    return results.isEmpty ? [TargetRuntime.jit] : results.toList();
  }

  static void _parseTokenInto(String token, Set<TargetRuntime> results) {
    for (final part in token.split(',')) {
      final clean = part.trim().toLowerCase();
      if (clean.isEmpty) continue;
      if (clean == 'all') {
        results.addAll(TargetRuntime.values);
      } else {
        final target = tryParse(clean);
        if (target == null) {
          throw FormatException(
            'Unknown target runtime "$part". Expected one of: '
            '${TargetRuntime.values.map((t) => t.name).join(", ")}, all',
          );
        }
        results.add(target);
      }
    }
  }

  @override
  String toString() => name;
}

/// Provides reliable, cross-platform discovery of the Dart SDK and external
/// runtime engines (Node.js, D8).
final class const DartSdk({
  /// Custom override path to the Dart SDK root directory.
  final String? customSdkPath,

  /// Custom environment variable map override.
  final Map<String, String>? environment,
}) {
  Map<String, String> get _env => environment ?? Platform.environment;

  /// Returns the resolved absolute path to the active Dart SDK root directory,
  /// or `null` if no valid SDK can be identified.
  String? get sdkPath {
    if (customSdkPath != null) {
      if (isValidSdkPath(customSdkPath!)) {
        return p.normalize(p.absolute(customSdkPath!));
      }
      return null;
    }

    final fromEnv = _env['DART_SDK'];
    if (fromEnv != null && isValidSdkPath(fromEnv)) {
      return p.normalize(p.absolute(fromEnv));
    }

    if (environment == null) {
      final fromResolvedExe = _probeResolvedExecutable();
      if (fromResolvedExe != null) {
        return fromResolvedExe;
      }
    }

    final fromPath = _probePathForSdk();
    if (fromPath != null) {
      return fromPath;
    }

    final flutterRoot = _env['FLUTTER_ROOT'];
    if (flutterRoot != null) {
      final flutterSdk = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
      if (isValidSdkPath(flutterSdk)) {
        return p.normalize(p.absolute(flutterSdk));
      }
    }

    return null;
  }

  /// Resolves the active package_config.json path, if available.
  String? get packageConfigPath {
    final pkgConfigUri = Platform.packageConfig;
    if (pkgConfigUri != null && pkgConfigUri.isNotEmpty) {
      try {
        final path = Uri.parse(pkgConfigUri).toFilePath();
        if (File(path).existsSync()) {
          return p.normalize(p.absolute(path));
        }
      } on Object {
        // Ignore URI parsing errors
      }
    }
    final localConfig = File(p.join('.dart_tool', 'package_config.json'));
    if (localConfig.existsSync()) {
      return p.normalize(localConfig.absolute.path);
    }
    return null;
  }

  /// Returns the path to the `dart` (or `dart.exe`) executable binary.
  String? get dartExecutable {
    final sdk = sdkPath;
    if (sdk != null) {
      final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
      final candidate = p.join(sdk, 'bin', exeName);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return findExecutable('dart');
  }

  /// Returns the path to the `node` (or `nodejs`) executable on PATH.
  String? get nodeExecutable =>
      findExecutable('node') ?? findExecutable('nodejs');

  /// Returns the path to the `d8` executable on the system PATH.
  String? get d8Executable => findExecutable('d8');

  /// Whether a suitable WebAssembly runner (Node.js or D8) is available.
  bool get hasWasmRunner => nodeExecutable != null || d8Executable != null;

  /// Whether a suitable JavaScript runner (Node.js or D8) is available.
  bool get hasJsRunner => nodeExecutable != null || d8Executable != null;

  /// Checks whether prerequisites for executing [runtime] are satisfied.
  bool isRuntimeAvailable(TargetRuntime runtime) => switch (runtime) {
    TargetRuntime.jit => dartExecutable != null,
    TargetRuntime.aot => dartExecutable != null,
    TargetRuntime.wasm => dartExecutable != null && hasWasmRunner,
    TargetRuntime.js => dartExecutable != null && hasJsRunner,
  };

  /// Locates an executable binary by [name] across the directories in PATH.
  String? findExecutable(String name) {
    final pathVar = _env['PATH'];
    if (pathVar == null || pathVar.isEmpty) return null;

    final separator = Platform.isWindows ? ';' : ':';
    final entries = pathVar.split(separator);

    final extensions = Platform.isWindows
        ? const ['', '.exe', '.bat', '.cmd']
        : const [''];

    for (final entry in entries) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;

      for (final ext in extensions) {
        final candidate = p.join(trimmed, '$name$ext');
        final file = File(candidate);
        if (file.existsSync()) {
          return p.normalize(p.absolute(candidate));
        }
      }
    }
    return null;
  }

  /// Validates whether [candidatePath] satisfies standard Dart SDK layout.
  static bool isValidSdkPath(String candidatePath) {
    try {
      final dir = Directory(candidatePath);
      if (!dir.existsSync()) return false;

      final binDir = Directory(p.join(candidatePath, 'bin'));
      if (!binDir.existsSync()) return false;

      final dartBin = File(p.join(binDir.path, 'dart'));
      final dartExe = File(p.join(binDir.path, 'dart.exe'));
      if (!dartBin.existsSync() && !dartExe.existsSync()) {
        return false;
      }

      final hasLibInternal = Directory(
        p.join(candidatePath, 'lib', '_internal'),
      ).existsSync();
      final hasLibrariesJson = File(
        p.join(candidatePath, 'lib', 'libraries.json'),
      ).existsSync();
      final hasVersion = File(p.join(candidatePath, 'version')).existsSync();

      return hasLibInternal || hasLibrariesJson || hasVersion;
    } on Object {
      return false;
    }
  }

  String? _probeResolvedExecutable() {
    try {
      final resolved = Platform.resolvedExecutable;
      if (resolved.isNotEmpty) {
        final candidate = p.dirname(p.dirname(resolved));
        if (isValidSdkPath(candidate)) {
          return p.normalize(p.absolute(candidate));
        }
      }
    } on Object {
      // Ignore resolution errors
    }
    return null;
  }

  String? _probePathForSdk() {
    final dartPath = findExecutable('dart');
    if (dartPath == null) return null;

    try {
      final resolvedDart = File(dartPath).resolveSymbolicLinksSync();
      final candidateSdk = p.dirname(p.dirname(resolvedDart));
      if (isValidSdkPath(candidateSdk)) {
        return p.normalize(p.absolute(candidateSdk));
      }

      final flutterSdk = p.join(candidateSdk, 'bin', 'cache', 'dart-sdk');
      if (isValidSdkPath(flutterSdk)) {
        return p.normalize(p.absolute(flutterSdk));
      }
    } on Object {
      // Ignore symlink resolution errors
    }
    return null;
  }
}
