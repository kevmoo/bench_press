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
  variants in counterbalanced `ABBA BAAB` visits to cancel host thermal drift,
  discarding two batches at every switch between variants.
- **PayloadPlausibility & Fieller Gating**: Formats `Throughput.bytes` and
  `Throughput.elements` rates (`MB/s`, `GB/s`, `items/s`), flags implausible
  rates (`> 100 GB/s` or size-invariant latencies across `>= 8x` payload
  spreads), and gates speedups on `isStable` and 95% Fieller confidence
  intervals.

## Quickstart

Add `bench_press` to your `pubspec.yaml`:

```yaml
dev_dependencies:
  bench_press: ^0.4.2
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
        config: const BenchmarkConfig(trials: 16, maxTrials: 32),
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

# Spawn 5 independent OS processes per target for cross-process CIs
dart run bench_press run --processes 5 -t jit,aot,wasm

# Pin benchmark subprocesses to specific Linux CPU cores (taskset -c syntax)
dart run bench_press run --pin-cpu 2 -t jit,aot

# Bypass compiled artifact caching or specify custom Web/Wasm runners
dart run bench_press run --no-cache -t wasm --d8-path /path/to/d8 --node-path /path/to/node

# Fast validation smoke test (1 warmup, 1 trial across targets)
dart run bench_press validate

# Render a Markdown/table/JSON report or diff from saved JSON results
dart run bench_press report --from-json benchmark_results.json
dart run bench_press diff baseline.json benchmark_results.json

# Require a ±2% practical significance / TOST equivalence band
dart run bench_press diff --threshold 0.02 baseline.json benchmark_results.json
dart run bench_press run --threshold 0.02 --diff origin/main benchmark/

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
  trials: 16
  max_trials: 32
  processes: 1
  threshold: 0.02
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

### Multi-Process Benchmarking (`--processes`)

By default (`--processes 1`), `bench_press` executes each benchmark target in a
single isolated OS process. Within that process, `Benchmark.compare` and
`Benchmark.matrix` already interleave variants in four `ABBA BAAB` block visits
with two discarded transition batches per switch.

When to use `--processes <P>` (or `defaults.processes` in `bench_press.yaml`):

- **Stay with `--processes 1` (default)** for fast local iteration, CI smoke
  checks, and intra-file `Benchmark.compare` / `Benchmark.matrix` runs where all
  variants share a single OS process.
- **Use `--processes 5` (or `3–10`)** when comparing separate process launches
  (such as `bench_press.yaml` matrix coordinates across different SDKs or
  compiler flags, or `bench_press run --diff` across Git commits) or when
  verifying sub-3% speedups where OS page-frame placement, ASLR layout, or JIT
  code-cache alignment could shift an entire process by 1–2%.
- **Compile-once & `ABBA BAAB` process launch order**: `bench_press run`
  compiles every `(coordinate, runtime)` artifact once upfront, then spawns `P`
  fresh OS processes per cell in `ABBA BAAB` coordinate traversal order across
  rounds `p = 0 .. P - 1`.
- **Hierarchical aggregation & variance decomposition**: Top-level summary
  metrics and Fieller confidence intervals are computed over the `P` process
  means (`effectiveSamplesNs`), using paired covariance (`paired: true`) when
  variants share the same `P` OS process launches and unpaired Welch-Fieller
  (`paired: false`) across separate process launches.
- **Interpreting `Between-Process Share` (`between_process_share`)**: When
  `--processes > 1`, the `### All Benchmarks` Markdown table adds `Processes`
  and `Between-Process Share` columns (and JSON telemetry records
  `metrics.variance_components`: `ms_within`, `ms_between`, `var_within`,
  `var_between`, and
  `between_process_share = var_between / (var_between + var_within)`):
  - **Near `0%` (`0%–20%`)**: Separate OS process launches landed on nearly the
    same speed; most noise is trial-to-trial jitter inside one process, so
    `--processes 1` or more `--trials` is sufficient.
  - **High (`>= 50%`)**: Process-launch shifts (ASLR memory layout, OS page
    placement, cache alignment) dominate total variance. Running more `--trials`
    inside a single process will not narrow the confidence interval—increase
    `--processes` instead.

### Practical Significance & Equivalence Testing (`--threshold`)

By default (`--threshold 0`), any resolved comparison whose 95% Fieller CI
contains `1.00x` is reported as `➖ ⚪ Neutral`, and point estimates clearing
`±5%` (`>= 1.05x` or `<= 0.95x`) with a non-straddling 95% CI are flagged as
`🚀 Faster` (`🚀 🥇 Peak`) or `⚠️ Regression` (`⚠️ 🔴 Slow`).

When you want to separate statistically significant micro-movements from
practically meaningful changes—or prove that a refactoring did not regress
performance beyond a known tolerance—pass `--threshold <delta>` (as a relative
fraction in `[0.0, 1.0)` like `0.02` for ±2%, or set `defaults.threshold` in
`bench_press.yaml`) to `run`, `report`, or `diff`:

- **`🚀 Faster` / `🚀 🥇 Peak`**: The entire 95% Fieller CI lies at or above
  `1.0 + threshold` (for example `>= 1.02x` at `--threshold 0.02`).
- **`⚠️ Regression` / `⚠️ 🔴 Slow`**: The entire 95% Fieller CI lies at or below
  `1.0 / (1.0 + threshold)` (for example `<= 0.9804x` at `--threshold 0.02`).
- **`✅ Equivalent` (Schuirmann TOST)**: The 90% Fieller CI (corresponding to
  two one-sided tests at `alpha = 0.05` per side) lies completely inside
  `[1.0 / (1.0 + threshold), 1.0 + threshold]`, proving equivalence within the
  practical margin.
- **`➖ ⚪ Inconclusive`**: The confidence interval straddles the equivalence
  boundary without proving either a directional change beyond `threshold` or
  equivalence within `±threshold` (add `--processes` or `--trials` to tighten
  the interval).

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
