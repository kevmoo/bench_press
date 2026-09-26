A modern, statistically sound, compiler-aware multi-runtime benchmarking
framework for Dart and Flutter.

## Highlights

- **Multi-Runtime Orchestration**: Run benchmarks across VM JIT (`dart run`),
  Native AOT (`dart compile exe`), WebAssembly (`dart compile wasm`), and
  JavaScript (`dart compile js`) with a single command.
- **Dead Code Elimination (DCE) Barrier**: `Blackhole` prevents optimizing
  compilers (LLVM, Binaryen, V8) from erasing benchmark loops while maintaining
  zero per-iteration heap allocations.
- **Automated Warmup Detection**: Adaptive Steady-State Warmup Detection (RBF
  Kernel MMD + SEM Relative Error) determines true steady-state execution so you
  never have to guess warmup iteration counts.
- **Payload-Aware Throughput**: Sealed `Throughput.bytes` and
  `Throughput.elements` automatically calculate and format rates (`MB/s`,
  `GB/s`, `items/s`). Any byte rate above memory bandwidth — or any benchmark
  whose latency does not move when its payload does — is flagged in the report
  before you can quote it.
- **Implementation Comparisons**: `BenchmarkGroup` compares multiple
  implementations within a run (e.g. `concat` vs `StringBuffer`), computing
  speedup multipliers and exact Fieller 95% confidence intervals.
- **Git Baseline Diffing**: `--diff <ref>` compares live runs against prior git
  commits (or stored JSON baselines) with isolated Before vs. After delta
  tables.
- **GitHub-Ready Markdown Reports**: Generates clean, publication-ready Markdown
  tables and structured JSON telemetry.

---

## Quickstart

Add `bench_press` to your `pubspec.yaml`:

```yaml
dev_dependencies:
  bench_press: ^0.3.1
```

### 1. Write a Benchmark

Create a benchmark file in `benchmark/` (e.g. `benchmark/json_benchmark.dart`):

```dart
import 'dart:convert';
import 'package:bench_press/bench_press.dart';

final class JsonDecodeBenchmark extends Benchmark {
  final String _payload;

  JsonDecodeBenchmark(this._payload) : super('json_decode');

  @override
  Throughput get throughput =>
      Throughput.bytes(utf8.encode(_payload).length);

  @override
  void run() {
    Blackhole.consume(jsonDecode(_payload));
  }
}

void main(List<String> args) =>
    mainBenchmark(JsonDecodeBenchmark('{"key": "value"}'), args);
```

### 2. Compare Implementations (`BenchmarkGroup`)

Compare competing algorithms or packages against a baseline in a single run:

```dart
import 'package:bench_press/bench_press.dart';

final class StringConcatBenchmark extends Benchmark {
  StringConcatBenchmark() : super('concat');

  @override
  void run() {
    var str = '';
    for (var i = 0; i < 100; i++) {
      str += 'x';
    }
    Blackhole.consume(str);
  }
}

final class StringBufferBenchmark extends Benchmark {
  StringBufferBenchmark() : super('buffer');

  @override
  void run() {
    final sb = StringBuffer();
    for (var i = 0; i < 100; i++) {
      sb.write('x');
    }
    Blackhole.consume(sb.toString());
  }
}

Future<void> main(List<String> args) async {
  final concatBench = StringConcatBenchmark();
  final bufferBench = StringBufferBenchmark();
  final group = BenchmarkGroup(
    'String Group',
    [
      BenchmarkVariant('concat', concatBench.run),
      BenchmarkVariant('buffer', bufferBench.run),
    ],
  );
  await mainBenchmarkGroup(group, args);
}
```

#### Parameterized Matrix Groups (`BenchmarkGroup.matrix`)

Evaluate competing implementations across multiple inputs or datasets without
repetitive boilerplate:

```dart
Future<void> main(List<String> args) async {
  final matrix = BenchmarkGroup.matrix<int>(
    cases: [10, 100, 1000],
    name: (n) => 'string_length_$n',
    throughput: (n) => Throughput.elements(n),
    baseline: ('concat', (n) {
      var str = '';
      for (var i = 0; i < n; i++) {
        str += 'x';
      }
      Blackhole.consume(str);
    }),
    candidates: {
      'buffer': (n) {
        final sb = StringBuffer();
        for (var i = 0; i < n; i++) {
          sb.write('x');
        }
        Blackhole.consume(sb.toString());
      },
    },
  );
  await mainBenchmarkSuite(matrix, args);
}
```

### 3. Asynchronous Benchmarks (`AsyncBenchmark`)

```dart
import 'dart:async';
import 'package:bench_press/bench_press.dart';

final class AsyncFetchBenchmark extends AsyncBenchmark {
  AsyncFetchBenchmark() : super('async_fetch');

  @override
  Future<void> run() async {
    final result = await doAsyncWork();
    Blackhole.consume(result);
  }
}

Future<void> main(List<String> args) async =>
    await mainAsyncBenchmark(AsyncFetchBenchmark(), args);
```

---

## CLI Guide

Run benchmarks using the `bench_press` CLI:

```bash
# Run on default target (JIT) across benchmark/
dart run bench_press run

# Run across multiple runtime targets (JIT, AOT, WasmGC, JS)
dart run bench_press run -t jit -t aot -t wasm

# Adaptive trial scaling (scale up to 50 trials if initial variance exceeds threshold)
dart run bench_press run --max-trials 50

# Specify custom D8 or Node.js executables for Web/Wasm runtimes
dart run bench_press run -t wasm --d8-path /path/to/d8 --node-path /path/to/node

# Bypass compiled artifact caching across runs
dart run bench_press run --no-cache -t aot

# Run a specific benchmark file or directory
dart run bench_press run benchmark/json_benchmark.dart

# Fast validation smoke-test (verifies build & runtime health in ~2s)
dart run bench_press validate
```

### Benchmark Discovery

`bench_press` discovers benchmarks using standard Dart conventions:

- **File Suffixes**: When scanning a directory (defaulting to `benchmark/`), it
  discovers all files ending in `*_benchmark.dart` or `*_bench.dart`. Helper
  files (e.g. `utils.dart`, `fixtures.dart`) are cleanly ignored.
- **Direct File Targets**: You can also target any individual `.dart` file
  directly (e.g. `dart run bench_press run benchmark/my_custom_run.dart`).
- **Entrypoints**: Every benchmark file must be an executable script declaring a
  `main` entrypoint (such as
  `void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);`).

### Comparing Against Git Baselines (`--diff`)

Diff current code against a prior git commit or baseline JSON:

```bash
# Measure current code and compare against main
dart run bench_press run --diff origin/main benchmark/

# Save baseline for subsequent comparisons
dart run bench_press run --save baseline.json benchmark/

# Diff against saved baseline
dart run bench_press run --diff baseline.json benchmark/
```

### Pinning to CPUs (`--pin-cpu`, Linux)

The kernel is free to migrate a benchmark thread between cores mid-measurement,
which invalidates L1/L2 along the way, and an SMT sibling running unrelated work
contends for the same physical core. Both produce run-to-run variance that more
trials will not remove, because the machine really is doing something different
each time.

```bash
# Pin every benchmark process to CPU 2
dart run bench_press run --pin-cpu 2 benchmark/

# A range, or a list, in taskset -c syntax
dart run bench_press run --pin-cpu 0-3 benchmark/
dart run bench_press run --pin-cpu 2,4,6 benchmark/
```

`bench_press` prefixes each benchmark command with `taskset`, so pinning applies
uniformly to the Dart VM, AOT executables, Node.js, and D8.

**Pick CPUs that are not SMT siblings.** Two logical CPUs sharing a physical
core share its execution units, so pinning to both is close to not pinning at
all. `lscpu -e=CPU,CORE` maps them:

Any two CPUs with the same `CORE` are siblings, and they are usually **not**
adjacent. This groups the CPUs by the physical core they sit on:

```console
$ lscpu -e=CPU,CORE | awk 'NR>1 {a[$2]=a[$2]" "$1} END {for (c in a) print "core "c":"a[c]}' | sort -V
core 0: 0 8
core 1: 1 9
core 2: 2 10
core 3: 3 11
```

On this 16-CPU/8-core host the sibling of CPU 0 is CPU 8, so `--pin-cpu 0-3`
gets four distinct cores while `--pin-cpu 0,8` gets one core twice. The stride
is not always 8 — run the command rather than assuming it.

Caveats worth knowing:

- **A malformed CPU list is a usage error** — `bench_press` exits `64` without
  running, rather than measuring unpinned and handing back numbers that look
  pinned.
- **A CPU that does not exist is not caught up front.** Only the _syntax_ is
  validated; `taskset` reports an unsatisfiable set, after compilation, with
  `failed to set pid's affinity: Invalid argument` and a non-zero exit. The host
  CPU count is deliberately not used as a bound, because a process confined to a
  narrower cpuset would then be told valid CPUs are invalid.
- **Linux only.** macOS is not supported — the Darwin kernel exposes no POSIX
  CPU affinity interface, so there is no `taskset` equivalent. On any
  unsupported host, or when `taskset` is missing from `PATH` (common in minimal
  container images; it ships in `util-linux`), the flag warns on stderr and the
  run continues unpinned.
- **Not compatible with `--isolate-mode`**, which runs JIT benchmarks in-process
  rather than spawning a command to wrap. Pin the whole process instead:
  `taskset -c 2 dart run bench_press run --isolate-mode ...`.
- Pinning constrains the scheduler, it does not silence the machine. It pairs
  with a fixed CPU governor (`performance`) and an otherwise idle host.

### CI / Automation Integration

```bash
# Fail CI build with non-zero exit code if any benchmark is unstable
dart run bench_press run --fail-on-unstable -t jit,aot benchmark/
```

Example GitHub Actions workflow:

```yaml
name: Benchmarks

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1
        with:
          sdk: dev

      - name: Setup Node.js (WasmGC runner)
        uses: actions/setup-node@v7
        with:
          node-version: 22

      - name: Install dependencies
        run: dart pub get

      - name: Validate benchmark suite
        run: dart run bin/bench_press.dart validate benchmark/
```

---

## Architecture & Statistical Methodology

For in-depth details on compiler mechanics, `Blackhole` static sinks, Adaptive
Steady-State Warmup Detection (RBF Kernel MMD + SEM Relative Error), and Fieller
ratio confidence intervals, see:

- [**Architecture & Statistical Methodology**](doc/background.md)

---

## License

MIT License. See [LICENSE](LICENSE) for details.
