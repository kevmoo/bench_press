A modern, statistically sound, compiler-aware multi-runtime benchmarking
framework for Dart and Flutter.

## Motivation: The Problem with `package:benchmark_harness`

The legacy `package:benchmark_harness` was built for early Dart VM JIT execution
and exhibits fundamental design flaws in modern optimizing compiler environments:

1. **Dead Code Elimination (DCE) Vulnerability**: Modern Dart AOT (`dart compile
   exe`), WasmGC (`dart compile wasm`), and dart2js (`-O4`) compilers
   aggressively optimize away loops whose computed values are not consumed.
   Unprotected benchmark loops often measure 0 ns simply because the compiler
   erased the entire computation.
2. **Naive Single-Shot Timing**: It relies on coarse millisecond wall-clock
   increments without steady-state warmup convergence, outlier detection, or
   statistical variance tracking.
3. **No Multi-Runtime Orchestration**: It cannot coordinate or compare results
   across compilation targets (VM JIT, AOT, WasmGC, JS) or automate Node.js / D8
   subprocesses.
4. **No Statistically Sound Diffs**: It prints ad-hoc iteration counts without
   structured JSON telemetry, baseline tracking, or ratio confidence intervals.

`bench_press` solves these challenges with compiler-aware DCE barriers,
monomorphic batch measurement loops, automated steady-state warmup detection,
and cross-target CLI orchestration.

## Core Primitives & Compiler Awareness

### 1. `Blackhole` DCE Barrier

`Blackhole` prevents optimizing compilers from eliminating benchmarked
computations without introducing per-iteration heap allocations.

```dart
// DCE Hazard: Compiler can eliminate the entire loop in AOT / Wasm
for (var i = 0; i < count; i++) {
  parser.parse(bytes);
}

// Protected: Blackhole retains computation across all compiler backends
for (var i = 0; i < count; i++) {
  Blackhole.consume(parser.parse(bytes));
}
```

* **Opaque Static Buffer**: Writes values into an 8-slot array
  (`_sink[_index++ & 7] = value`), forcing compilers across VM JIT, AOT, WasmGC,
  and dart2js to retain computation outputs.
* **Cross-Backend Inlining Pragmas**: Tagged with `@pragma('vm:prefer-inline')`,
  `@pragma('wasm:prefer-inline')`, and `@pragma('dart2js:prefer-inline')` to
  eliminate call overhead.
* **Terminal Drain**: `Blackhole.drain()` computes a bitwise checksum of all
  buffer slots and resets the sink, ensuring memory isolation between trials.

### 2. Monomorphic Inner Batch Loops

Measuring high-frequency operations (< 1 µs) directly with individual timer
calls introduces severe measurement noise and quantization error.

* **Batch Calibration**: Automatically scales batch size `N` so that each
  timed batch takes >= 10 ms (minimizing timer quantization to < 0.1%).
* **Single Monotonic Timer Read**: Reads the monotonic clock once per batch and
  computes mean iteration latency by dividing by `N`.
* **Zero Polymorphic Dispatch**: Runs a tight, monomorphic loop without
  per-iteration function pointers or dynamic dispatch.
* **No Empty Loop Subtraction**: `bench_press` intentionally avoids subtracting
  empty loop timings, as modern superscalar CPUs parallelize loop control
  instructions across independent execution ports.

## Statistical Rigor & Steady-State Detection

### 1. KBSSD Warmup Convergence

`bench_press` implements Kallithea-Borg Self-Stopping Detection (KBSSD) to
determine when a benchmark has achieved true steady-state execution:

* **Sliding Window MMD**: Computes Maximum Mean Discrepancy across consecutive
  sample windows to detect distribution shifts.
* **MAD Dynamic Thresholding**: Scales convergence thresholds dynamically using
  Median Absolute Deviation.
* **SEM Practical Steady-State Check**: Accepts convergence if:
  `1.96 * SEM <= 0.03 * Mean`
* **Patience Budget Fallback**: If warmup does not converge within the budget
  (e.g., 200 iterations), it selects the lowest MMD window, flags
  `isStable: false`, and logs a warning.

### 2. Calibration Guards

* **Runtime Bounds**: Enforces runtime bounds (10 µs to 200 ms).
* **Spectre Coarse Timer Virtualization**: Accommodates timer virtualization
  under browser environments (`dart.library.js_interop`).
* **Bypass Flag**: Use `--force-run` to bypass calibration safety bounds during
  development.

### 3. Fieller's Confidence Intervals

When computing speedup ratios between baseline and candidate branches,
`bench_press` computes exact 95% confidence intervals using Fieller's theorem
on the speedup ratio (mean_baseline / mean_candidate).

## Telemetry & JSON Persistence

Results are persisted to canonical JSON (`benchmark_results.json`) with
deterministic deep-merging by `(name, target)`:

```json
{
  "version": 1,
  "timestamp": "2026-08-30T00:00:00.000Z",
  "environment": {
    "dart_version": "3.14.0",
    "os": "linux",
    "arch": "x64"
  },
  "benchmarks": [
    {
      "name": "json_decode/small",
      "target": "wasm",
      "mode": "sync",
      "samples": 15,
      "metrics": {
        "mean_ns": 412.5,
        "median_ns": 410.2,
        "min_ns": 405.0,
        "max_ns": 435.1,
        "stddev_ns": 8.4,
        "ops_per_sec": 2424242.4,
        "is_stable": true
      }
    }
  ]
}
```

## API Guide & Usage

### 1. Synchronous Benchmark

```dart
import 'package:bench_press/bench_press.dart';

final class StringConcatBenchmark extends Benchmark {
  StringConcatBenchmark() : super('string/plus_concat');

  @override
  void run() {
    var str = '';
    for (var i = 0; i < 50; i++) {
      str += 'token';
    }
    Blackhole.consume(str);
  }
}

void main() {
  final result = StringConcatBenchmark().report();
  print('Mean: ${result.metrics.meanNs.toStringAsFixed(1)} ns');
}
```

### 2. Asynchronous Benchmark

```dart
import 'package:bench_press/bench_press.dart';

final class AsyncFetchBenchmark extends AsyncBenchmark {
  AsyncFetchBenchmark() : super('async/fetch_batch');

  @override
  Future<void> run() async {
    final data = await Future.microtask(() => 42);
    Blackhole.consume(data);
  }
}

Future<void> main() async {
  final result = await AsyncFetchBenchmark().report();
  print('Ops/sec: ${result.metrics.opsPerSec.toStringAsFixed(0)}');
}
```

### 3. Compositional Functional Variants

```dart
import 'dart:convert';
import 'package:bench_press/bench_press.dart';

final variant = BenchmarkVariant('json/encode_variant', () {
  final json = jsonEncode({'key': 'value', 'count': 100});
  Blackhole.consume(json);
});

Future<void> main() async {
  await variant.report();
}
```

### 4. Model 1: Intra-Run Apples-to-Apples Comparison Groups

Use `BenchmarkGroup` to evaluate competing algorithmic implementations executed within the **exact same process and thermal envelope**:

```dart
import 'package:bench_press/bench_press.dart';

// Option A: BenchmarkGroup with declared baseline
final stringGroup = BenchmarkGroup('String Construction', [
  BenchmarkVariant('concat', () {
    var s = '';
    for (var i = 0; i < 50; i++) s += 'token';
    Blackhole.consume(s);
  }, isBaseline: true), // Reference baseline

  BenchmarkVariant('string_buffer', () {
    final sb = StringBuffer();
    for (var i = 0; i < 50; i++) sb.write('token');
    Blackhole.consume(sb.toString());
  }),

  BenchmarkVariant('join', () {
    final list = List.filled(50, 'token');
    Blackhole.consume(list.join());
  }),
]);

// Option B: Declarative Matrix Builder
final jsonSuite = BenchmarkGroup.compare(
  name: 'JSON Deserialization',
  baseline: ('dart:convert', () => jsonDecode(payload)),
  candidates: {
    'custom_buffer': () => CustomBufferDecoder.decode(payload),
    'fast_parser': () => FastParser.parse(payload),
  },
);
```

#### Automatic Implementation Comparison Table

When grouped benchmarks are executed, `bench_press` automatically renders a direct variant comparison table with exact 95% Fieller confidence intervals:

<!-- mdformat off(prevent table wrapping) -->
| Implementation | Ops/sec | Mean Latency | vs. Baseline (`concat`) | Speedup Ratio | 95% Confidence Interval | Status |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `concat` (Baseline) | 163,288 ops/s | 6.12 µs | 1.00x (ref) | 1.00x | [1.00x – 1.00x] | Ref |
| `string_buffer` | 727,840 ops/s | 1.37 µs | **4.47x faster** | 4.47x | **[4.38x – 4.56x]** | Peak |
| `join` | 727,566 ops/s | 1.37 µs | **4.46x faster** | 4.46x | **[4.37x – 4.55x]** | Fast |
<!-- mdformat on -->

### 5. Benchmark Suites

Export a top-level `benchmarks` list to enable CLI auto-discovery:

```dart
import 'package:bench_press/bench_press.dart';

final benchmarks = <Object>[
  StringConcatBenchmark(),
  AsyncFetchBenchmark(),
  variant,
  stringGroup,
];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
```

## CLI Guide (`bench_press`)

`bench_press` includes a multi-runtime CLI orchestrator:

```bash
dart run bench_press <command> [arguments]
```

### Subcommands

#### `run`
Compiles and executes benchmarks across target runtimes:

```bash
# Run on VM JIT (default)
dart run bench_press run benchmark/

# Run across all supported compilation targets (JIT, AOT, WasmGC, JS)
dart run bench_press run -t jit -t aot -t wasm -t js benchmark/

# Model 2: Live diffing against a baseline JSON file or Git reference
dart run bench_press run --diff main benchmark/
dart run bench_press run --diff baseline.json benchmark/

# Save/merge results to a specific telemetry file
dart run bench_press run --save baseline.json benchmark/

# Fast local iteration via Dart isolates
dart run bench_press run --isolate-mode benchmark/

# Exit with non-zero status if any benchmark fails steady-state warmup
dart run bench_press run --fail-on-unstable benchmark/
```

#### `validate`
Fast ~2s smoke verification checking syntax and runtime health across
compilers:

```bash
dart run bench_press validate benchmark/
```

#### `report`
Rehydrates and formats Markdown summary tables from saved JSON telemetry:

```bash
dart run bench_press report -f benchmark_results.json
```

#### `diff`
Computes isolated Before-vs-After delta tables against git history or a baseline
JSON file:

```bash
# Diff current telemetry against main branch in git
dart run bench_press diff -b main -c benchmark_results.json

# Diff against a specific baseline JSON file
dart run bench_press diff -b baseline_results.json -c benchmark_results.json
```

## Continuous Integration (GitHub Actions)

Add the following workflow to `.github/workflows/ci.yaml` to validate
benchmarks on every push and pull request:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1
        with:
          sdk: dev

      - name: Setup Node.js (WasmGC runner)
        uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Install dependencies
        run: dart pub get

      - name: Verify formatting
        run: dart format --output=none --set-exit-if-changed .

      - name: Analyze project
        run: dart analyze --fatal-infos

      - name: Run test suite
        run: dart test

      - name: Validate benchmark suite
        run: dart run bin/bench_press.dart validate benchmark/
```

## License

MIT License. See [LICENSE](LICENSE) for details.
