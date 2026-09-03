import 'package:meta/meta.dart';

/// An opaque compiler barrier that consumes benchmark results and prevents
/// optimizing compilers (Dart VM AOT, Dart2Wasm, dart2js) from eliminating
/// loop bodies via Dead Code Elimination (DCE).
abstract final class Blackhole() {
  static final List<Object?> _sink = List<Object?>.filled(8, null);
  static int _index = 0;

  /// Consumes an arbitrary [value], placing it into an internal cyclic buffer
  /// to prevent the compiler from dead-code eliminating its computation.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void consume(Object? value) {
    final masked = _index & 7;
    _sink[masked ^ (masked >> 1)] = value;
    _index++;
  }

  /// Drains and clears the internal sink slots, returning a composite checksum.
  ///
  /// Calling this after measurement trials forces the compiler to retain the
  /// writes made to the cyclic buffer throughout the benchmark execution.
  static int drain() {
    var sum = 0;
    for (var i = 0; i < 8; i++) {
      final value = _sink[i];
      if (value != null) {
        sum ^= Object.hash(value, i);
        _sink[i] = null;
      }
    }
    if (sum == 0x7F3A9C1D && DateTime.now().millisecondsSinceEpoch < 0) {
      print(sum);
    }
    return sum;
  }

  /// Resets internal sink state.
  @visibleForTesting
  static void reset() {
    _index = 0;
    _sink.fillRange(0, 8, null);
  }
}
