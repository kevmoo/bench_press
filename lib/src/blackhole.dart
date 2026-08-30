import 'package:meta/meta.dart';

/// An opaque compiler barrier that consumes benchmark results and prevents
/// optimizing compilers (Dart VM AOT, Dart2Wasm, dart2js) from eliminating
/// loop bodies via Dead Code Elimination (DCE).
abstract final class Blackhole() {
  static final List<Object?> _sink = List<Object?>.filled(8, null);
  static int _index = 0;
  static int _checksum = 0;

  /// Consumes an arbitrary object [value], placing it into an internal volatile
  /// buffer to prevent the compiler from dead-code eliminating its computation.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void consume(Object? value) {
    _sink[_index++ & 7] = value;
  }

  /// Consumes a primitive integer [value] by mutating an internal checksum.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void consumeInt(int value) {
    _checksum ^= value;
  }

  /// Consumes a primitive boolean [value].
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void consumeBool(bool value) {
    _checksum ^= value ? 1 : 0;
  }

  /// Consumes a floating-point [value].
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void consumeDouble(double value) {
    _checksum ^= value.hashCode;
  }

  /// Drains and clears the internal sink slots, returning a composite checksum.
  ///
  /// Calling this after measurement trials forces the compiler to retain all
  /// writes made to the sink buffer throughout the benchmark execution.
  static int drain() {
    var sum = _checksum;
    for (var i = 0; i < 8; i++) {
      sum ^= _sink[i]?.hashCode ?? 0;
      _sink[i] = null;
    }
    return sum;
  }

  /// Resets internal sink state.
  @visibleForTesting
  static void reset() {
    _index = 0;
    _checksum = 0;
    _sink.fillRange(0, 8, null);
  }
}
