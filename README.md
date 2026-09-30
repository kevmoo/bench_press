A statistically sound, compiler-aware multi-runtime benchmarking framework for
Dart and Flutter.

## Highlights

- **Multi-Runtime Orchestration**: Run benchmarks across VM JIT (`dart run`),
  Native AOT (`dart compile exe`), WebAssembly (`dart compile wasm`), and
  JavaScript (`dart compile js`) with a single command.
- **Dead Code Elimination (DCE) Barrier**: `Blackhole.consume` prevents
  optimizing compilers from erasing benchmark loops with zero per-iteration heap
  allocations.
- **Adaptive Warmup & Interleaved Trials**: Automatically detects steady-state
  warmup convergence, calibrates ~100ms trial batches, and interleaves group
  variants in counterbalanced `ABBA BAAB` rounds to cancel host thermal drift.
- **PayloadPlausibility & Fieller Gating**: Formats `Throughput.bytes` and
  `Throughput.elements` rates (`MB/s`, `GB/s`, `items/s`), flags implausible
  rates (`> 100 GB/s` or size-invariant latencies across `>= 8x` payload
  spreads), and gates speedups on `isStable` and 95% Fieller confidence
  intervals.

## Quickstart

Add `bench_press` to your `pubspec.yaml`:

```yaml
dev_dependencies:
  bench_press: ^0.4.0
```

### 1. Write a Benchmark (`Benchmark` & `AsyncBenchmark`)

Create a benchmark file in `benchmark/` (e.g. `benchmark/json_benchmark.dart`):

```dart
import 'dart:convert';
import 'package:bench_press/bench_press.dart';

final class JsonDecodeBenchmark extends Benchmark {
  final String _payload;
  late List<int> _utf8Bytes;

  JsonDecodeBenchmark(this._payload)
    : super(
        'json_decode',
        config: const BenchmarkConfig(trials: 15, maxTrials: 30),
      );

  @override
  Throughput get throughput => Throughput.bytes(_utf8Bytes.length);

  @override
  void setup() {
    _utf8Bytes = utf8.encode(_payload);
  }

  @override
  void run() {
    Blackhole.consume(jsonDecode(_payload));
  }
}

void main(List<String> args) =>
    mainBenchmark(JsonDecodeBenchmark('{"key": "value"}'), args);
```

For async workloads, extend `AsyncBenchmark` (overriding `Future<void> run()`,
and optionally `setup()`, `warmupComplete()`, `teardown()`) and pass it to
`mainAsyncBenchmark(benchmark, args)`. Calling `.report()` on any `Benchmark`,
`AsyncBenchmark`, `BenchmarkVariant`, `BenchmarkGroup`, or `BenchmarkMatrix`
executes it in-process and returns `BenchmarkResult`s directly.

### 2. Compare Implementations (`Benchmark.compare` & `Benchmark.matrix`)

Compare a baseline against candidate implementations in a single group (variants
warm up first, then interleave trials in `ABBA BAAB` rounds):

```dart
import 'package:bench_press/bench_press.dart';

Future<void> main(List<String> args) async {
  final group = Benchmark.compare(
    name: 'string_build',
    throughput: const Throughput.elements(100, unit: 'chars'),
    baseline: (
      'concat',
      () {
        var str = '';
        for (var i = 0; i < 100; i++) {
          str += 'x';
        }
        return str;
      },
    ),
    candidates: {
      'buffer': () {
        final sb = StringBuffer();
        for (var i = 0; i < 100; i++) {
          sb.write('x');
        }
        return sb.toString();
      },
    },
  );
  await mainBenchmarkGroup(group, args);
}
```

Note: `BenchmarkVariant` (used by `Benchmark.compare`, `Benchmark.matrix`, and
`BenchmarkGroup`) automatically passes the return value of each action closure
to `Blackhole.consume` (awaiting `Future`s when async).

#### Parameterized Matrix Comparisons (`Benchmark.matrix`)

Evaluate competing implementations across multiple input sizes or cases (shared
variant names across `>= 8x` byte spreads are automatically screened for payload
invariance):

```dart
import 'package:bench_press/bench_press.dart';

Future<void> main(List<String> args) async {
  final matrix = Benchmark.matrix<int>(
    cases: [16, 256, 4096],
    name: (n) => 'string_length:$n',
    throughput: (n) => Throughput.bytes(n),
    baseline: (
      'concat',
      (n) {
        var str = '';
        for (var i = 0; i < n; i++) {
          str += 'x';
        }
        return str;
      },
    ),
    candidates: {
      'buffer': (n) {
        final sb = StringBuffer();
        for (var i = 0; i < n; i++) {
          sb.write('x');
        }
        return sb.toString();
      },
    },
  );
  await mainBenchmarkMatrix(matrix, args);
}
```

Use `mainBenchmarkSuite([...], args)` to combine multiple `Benchmark`,
`AsyncBenchmark`, `BenchmarkVariant`, `BenchmarkGroup`, or `BenchmarkMatrix`
items in one file.

## CLI Guide

```bash
# Run all *_benchmark.dart and *_bench.dart files under benchmark/ on JIT
dart run bench_press run

# Run across multiple targets (-t jit,aot,wasm,js or -t all)
dart run bench_press run -t jit,aot,wasm

# Override trial count or adaptive scaling ceiling (scales up while CV > 5%)
dart run bench_press run --trials 20 --max-trials 50

# Pin benchmark subprocesses to specific Linux CPU cores (taskset -c syntax)
dart run bench_press run --pin-cpu 2 -t jit,aot

# Bypass compiled artifact caching or specify custom Web/Wasm runners
dart run bench_press run --no-cache -t wasm --d8-path /path/to/d8 --node-path /path/to/node

# Fast validation smoke test (1 warmup, 1 trial across targets)
dart run bench_press validate

# Render a Markdown/table/JSON report or diff from saved JSON results
dart run bench_press report --from-json benchmark_results.json
dart run bench_press diff baseline.json benchmark_results.json

# Run a single benchmark script directly with entrypoint flags
dart run benchmark/json_benchmark.dart --validate
dart run benchmark/json_benchmark.dart --trials 5 --target-batch-ms 50
```

### Comparing Against Git Baselines (`--diff`)

```bash
# Measure current working tree and compare against a git ref
dart run bench_press run --diff origin/main benchmark/

# Save a baseline JSON file and compare against it later
dart run bench_press run --save baseline.json benchmark/
dart run bench_press run --diff baseline.json benchmark/
```

### Matrix Configuration (`bench_press.yaml`)

`bench_press` loads `bench_press.yaml` from the working directory (or `-c` /
`--config`) to configure defaults and Cartesian matrices across Dart SDKs,
compiler flags, and runtimes:

```yaml
defaults:
  targets: [jit, aot, js, wasm]
  trials: 15
  max_trials: 30
  isolate_mode: false
  # Default output path for `run` and `run --diff` (supports leading `~`).
  output: benchmark_results.json

matrix:
  baseline:
    sdk: stock
    flags: baseline
  axes:
    sdk:
      stock: stock
      patched: ~/github/dart-sdk/out/ReleaseX64/dart-sdk
    flags:
      baseline: ''
      asserts: '--enable-asserts'
```

- **`axes.sdk`**: `'stock'` uses the ambient `dart` SDK; any other path
  (supporting leading `~`) overrides the SDK across all targets and fails fast
  if the directory or `bin/dart` binary is missing.
- **`axes.flags`**: Space-separated flags passed to `dart compile`.
- **`axes.runtime` (or `axes.target`)**: Overrides `defaults.targets` (`jit`,
  `aot`, `wasm`, `js`).
- **`baseline`**: Marks the reference coordinate (defaults to the first entry of
  each axis). Preview the matrix plan without running via
  `dart run bench_press run --dry-run`.

### Pinning to CPUs (`--pin-cpu`, Linux)

On Linux, `--pin-cpu <cpu-list>` wraps each benchmark subprocess (`dart`, AOT
executables, `node`, `d8`) in `taskset -c <cpu-list>`:

- Pick physical cores that are not SMT siblings (inspect via
  `lscpu -e=CPU,CORE`) and pair with the `performance` CPU frequency governor.
- Malformed CPU list syntax exits with usage error `64`; on macOS, Windows, or
  containers without `taskset`, `bench_press` warns on stderr and continues
  unpinned.
- Not compatible with `--isolate-mode` (which runs JIT in-process); wrap the
  outer command with `taskset -c 2 dart run bench_press run --isolate-mode`
  instead.

### CI Integration

```yaml
- name: Validate benchmark suite (1 trial smoke check)
  run: dart run bench_press validate benchmark/

- name: Run benchmarks and fail on unstable variance
  run: dart run bench_press run --fail-on-unstable -t jit,aot benchmark/
```

## Architecture & Statistical Methodology

See [**doc/background.md**](doc/background.md) for details on the `Blackhole`
Gray-code ring buffer, Adaptive Steady-State Warmup Detection (RBF Kernel MMD +
SEM Relative Error), `ABBA BAAB` trial interleaving, and Fieller ratio
confidence intervals.

## License

MIT License. See [LICENSE](LICENSE) for details.
