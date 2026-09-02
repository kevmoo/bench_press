import 'package:bench_press/bench_press.dart';

const int _iterations = 100;

/// ❌ DCE Hazard: Computations in this benchmark loop are discarded.
///
/// On aggressive optimizing compilers (such as `dart compile exe` AOT,
/// `dart compile wasm` WasmGC, or `dart compile js -O4`), the compiler's dead
/// code elimination (DCE) pass detects that the calculation results are unused
/// and eliminates the loop body. This produces misleadingly low latencies
/// (~0 ns or empty loop baseline) rather than measuring real work.
final class UnprotectedDeadCodeBenchmark() extends Benchmark {
  this : super('dce/unprotected_dead_code');

  @override
  void run() {
    var acc = 0;
    for (var i = 0; i < _iterations; i++) {
      acc = (acc * 31 + i) ^ (i << 2);
    }
    // Result is discarded! Optimizing compilers can eliminate the loop.
  }
}

/// ✅ Protected: Computations are fed into the [Blackhole] sink barrier.
///
/// [Blackhole] stores the result into an opaque 8-slot static array with
/// backend-specific inlining pragmas (`@pragma('vm:prefer-inline')`,
/// `@pragma('wasm:prefer-inline')`, `@pragma('dart2js:prefer-inline')`).
/// The compiler is forced to retain the full computation without incurring
/// per-iteration heap allocations.
final class ProtectedBlackholeBenchmark() extends Benchmark {
  this : super('dce/protected_blackhole');

  @override
  void run() {
    var acc = 0;
    for (var i = 0; i < _iterations; i++) {
      acc = (acc * 31 + i) ^ (i << 2);
      Blackhole.consumeInt(acc);
    }
  }
}

/// ✅ Protected with Terminal Drain: Demonstrates object consumption and drain.
///
/// Feeds intermediate objects into [Blackhole.consume] and executes a terminal
/// [Blackhole.drain] checksum to ensure all slots are referenced and cleared.
final class ProtectedBlackholeDrainBenchmark() extends Benchmark {
  this : super('dce/protected_blackhole_drain');

  @override
  void run() {
    for (var i = 0; i < _iterations; i++) {
      final obj = 'item_$i';
      Blackhole.consume(obj);
    }
    Blackhole.drain();
  }
}

/// Discovered benchmark collection for `bench_press run` / `validate`.
final List<Object> benchmarks = [
  UnprotectedDeadCodeBenchmark(),
  ProtectedBlackholeBenchmark(),
  ProtectedBlackholeDrainBenchmark(),
];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
