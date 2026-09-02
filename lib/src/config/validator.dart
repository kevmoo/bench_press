import 'bench_press_config.dart';

class ConfigValidator() {
  static void validateConfig(BenchPressConfig config) {
    // 1. Verify standard targets
    final allowedTargets = ['jit', 'aot', 'wasm', 'js'];
    for (final target in config.defaults.targets) {
      if (!allowedTargets.contains(target)) {
        throw FormatException(
          'Invalid default target: $target. Allowed: $allowedTargets',
        );
      }
    }

    // 2. Validate matrix
    final coords = config.generateCoordinates();

    // Check runtime axes
    final runtimeAxis = config.matrix.axes['runtime'];
    if (runtimeAxis != null) {
      for (final runtime in runtimeAxis.values) {
        if (!allowedTargets.contains(runtime.toString())) {
          throw FormatException('Invalid runtime in matrix axis: $runtime');
        }
      }
    }

    // Combinatorial Explosion Safety Guard
    if (coords.length > 50) {
      print(
        'WARNING: This configuration will generate ${coords.length} '
        'coordinates per workload.',
      );
      print('This exceeds the safety threshold of 50 runs.');
    }
  }
}
