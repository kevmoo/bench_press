## 0.4.0

- **Breaking (library exports)**: `package:bench_press/bench_press.dart` now
  exports only the benchmark-authoring (`Benchmark`, `AsyncBenchmark`,
  `BenchmarkGroup`, `BenchmarkMatrix`, `BenchmarkVariant`, `BenchmarkConfig`,
  `Throughput`, `ByteThroughput`, `ElementThroughput`, `Blackhole`), suite
  entrypoint (`mainBenchmark*`), and `.report()` result (`BenchmarkResult`,
  `BenchmarkMetrics`, `CalibratedBatch`, `WarmupResult`) APIs. Internal CLI,
  subprocess runner, compiler, statistical helper, and telemetry schema types
  that were previously re-exported in `0.3.1` are now internal to `lib/src/`.
- **Breaking (config)**: removed the `matrix.entrypoints` key from
  `bench_press.yaml`. It never chose which file ran: each value re-ran the same
  discovered benchmark files under a made-up `entrypoint` coordinate, so the
  matrix table compared identical runs. Pass benchmark files as positional paths
  to `bench_press run` instead. A leftover `entrypoints:` key is ignored.
- **Breaking (behavioral)**: `ByteThroughput.formatRate` now scales byte rates
  by decimal `1000` (`KB/s`, `MB/s`, `GB/s`) instead of `1024`, matching
  hardware memory bandwidth, network I/O conventions, and `ElementThroughput`.
- **Breaking (behavioral)**: `bench_press diff` and `bench_press run --diff` now
  pair cells by full key (name, target, and every coordinate, including group)
  instead of by name and target alone. A name reused across groups was
  previously compared against the first match in the other run. The Benchmark
  column now shows coordinates, for example `encode (group=A)`. Cells present in
  only one run are listed in an `Unmatched` note, including when nothing pairs.
- **Breaking (behavioral)**: an explicitly configured Dart SDK (`sdk` matrix
  axis in `bench_press.yaml`) is now authoritative and fails fast with a
  specific diagnostic explaining why the path was rejected instead of silently
  falling back to `dart` on `PATH`.
- `BenchmarkGroup.report`, `BenchmarkMatrix.report`, and `mainBenchmarkSuite`
  now interleave measurement trials across group variants in `ABBA BAAB` rounds
  after every variant has finished `setup`, warmup, `warmupComplete`, and batch
  calibration. Previously, all trials of variant `A` ran before variant `B`
  started, so a linear thermal ramp or a short host contention window during `B`
  produced a false speedup or regression while both variants still passed the
  within-variant `isStable` gate. When `maxTrials` is set, lockstep rounds
  continue across all variants in the group while any variant's CV exceeds 5%.
- `bench_press run` now honors `defaults.output` in `bench_press.yaml`, both for
  saving results and for the file `run --diff` looks up. An explicit `--output`
  or `--save` still takes precedence, and `benchmark_results.json` remains the
  fallback. A leading `~` expands to the home directory. The value must be a
  non-empty string; anything else is now a config error, where it was previously
  ignored. `bench_press report` and `bench_press diff` do not read it; pass them
  the path.
- Added `--pin-cpu <cpu-list>` to `bench_press run` to pin benchmark
  subprocesses (VM JIT, AOT, Node.js, and D8) via `taskset -c` on Linux.
- Added Fieller confidence interval and `isStable` speedup gating (`gate: true`
  by default, configurable via `--[no-]gate` in `bench_press run`, `report`, and
  `diff`). Unstable or unbounded-CI comparisons render as `unresolved` and are
  excluded from geometric mean rollups; a resolved comparison whose 95% CI
  contains `1.00x` renders as `➖ ⚪ Neutral`.
- Added Markdown report warning banners to flag benchmarks whose declared
  `Throughput.bytes` rate exceeds physical memory bandwidth (`100 GB/s`) or
  whose latency remains invariant (`0.9x–1.25x`) across `>=8x` payload size
  spreads for a shared benchmark name across groups.
- Derived post-warmup calibration batch sizes directly from steady-state warmup
  convergence latencies (recorded in `warmup.estimated_op_ns`), and added a
  Markdown report footnote listing any cell whose trial median moved more than
  25% from the warmup estimate that sized its batch.
- Updated `bench_press run` and `bench_press validate` to discover and execute
  all positional file and directory paths supplied on the command line rather
  than silently ignoring arguments after the first path.
- Invoked `warmupComplete()` lifecycle hook during `BenchmarkVariant` execution,
  forwarded `throughput` and `warmupComplete()` for `Benchmark` and
  `AsyncBenchmark` instances run via `mainBenchmark*`, and preserved
  programmatic `BenchmarkConfig` values unless explicitly overridden by CLI
  flags.
- Fixed Markdown suite reporting so suites mixing standalone benchmarks and
  `BenchmarkGroup` variants collate grouped variants into a single multi-row
  `### Group: ...` comparison table with the baseline ordered first and a
  geometric mean summary footer, and stopped wrapping Markdown tables in
  `mdformat off` / `mdformat on` HTML-comment guards.

## 0.3.1

- Hardened `bench_press run` and `bench_press validate` to exit with non-zero
  exit code (`ExitCode.software`) when target builds fail compilation,
  executions crash, or benchmark targets produce zero results.
- Fixed `_finishSuiteExecution` in `RunCommand` to propagate partial failure
  statuses across multi-target and multi-file Cartesian matrix executions while
  still preserving valid accumulated results.
- Implemented value equality (`operator ==`) and order-independent `hashCode` on
  `DartSdk`.
- Fixed CLI-specified `--d8-path` and `--node-path` overrides in `RunCommand`
  and `ValidateCommand` to ensure user-provided binary paths instantiate fresh
  compilers and process runners.
- Fixed `ValidateCommand._validateCoordinate` to iterate across all resolved
  runtime targets when Cartesian matrix configurations omit runtime dimensions
  (matching `RunCommand` behavior).

## 0.3.0

- **Breaking Change**: Streamlined `Blackhole` API to a single universal
  `consume(Object? value)` method. Removed redundant specialized methods
  (`consumeInt`, `consumeDouble`, `consumeBool`, `consumeString`,
  `consumeObject`).
- Hardened `Blackhole` compiler barrier against optimizing compiler Dead Code
  Elimination:
  - Adopted 3-bit cyclic Gray-code ring buffer indexing
    (`(index & 7) ^ ((index & 7) >> 1)`) to disrupt compiler loop unrolling and
    vectorization without consecutive slot collisions.
  - Coupled slot position with element hashing in `Blackhole.drain()` via
    `Object.hash(_sink[i], i)` to guarantee position-dependent reduction.
  - Corrected documentation regarding retention guarantees (retains the last 8
    writes across the cyclic Gray-code buffer).
  - Fixed 5.2x latency cliff on Web/JavaScript previously caused by eager
    `double.hashCode` computation.
- Added top-level `### Suite Summary` roll-up table with geometric mean,
  minimum, and maximum speedup across comparison groups to
  `MarkdownReporter.renderSuite` and `MarkdownReporter.renderSuiteSummaryTable`
  when suites contain 2 or more distinct groups (Issue #22).
- Added compilation artifact caching to `TargetCompiler.compile` and `--cache` /
  `--no-cache` CLI flags to `bench_press run`, avoiding redundant AOT/Wasm/JS
  compilation for unchanged benchmark files and dependencies (Issue #21).
- Added explicit CLI options `--d8-path` and `--node-path` to `bench_press run`
  and `bench_press validate`, supporting custom binary overrides, `D8_PATH` and
  `NODE_BINARY`/`NODE_EXECUTABLE` environment variables, and SDK auto-probing
  for bundled D8 under `bin/resources/dart2wasm/d8` (Issue #19).
- Fixed silent crashes on Node.js for JS and Wasm targets by replacing
  `stdout.writeln` with `print`, generating self-invoking `.run.mjs` and
  `.node.cjs` wrappers with unhandled rejection listeners, and forwarding CLI
  arguments via `dartMainRunner` (Issue #29, #30).
- Added parameterized matrix group builder `BenchmarkGroup.matrix<T>` (and
  convenience `Benchmark.matrix<T>`) and `BenchmarkMatrix<T>` to benchmark
  competing implementations across parameterized inputs or datasets without
  repetitive boilerplate (Issue #23).
- Added `mainBenchmarkMatrix` CLI entrypoint and updated `mainBenchmarkSuite` to
  execute `BenchmarkMatrix` instances seamlessly.
- Added robust dispersion metrics to `BenchmarkMetrics`: Median Absolute
  Deviation (`madNs`), normal-consistent robust CV
  (`robustCv = (1.4826 * madNs) / medianNs`), and Interquartile Range (`iqrNs`).
- Added `isRobustStable` to `BenchmarkMetrics` and updated `isStable` to
  incorporate robust dispersion, preventing transient bimodal GC sweeps from
  falsely failing steady-state stability for allocation-heavy workloads (Issue
  #20).
- Added adaptive trial scaling via `--max-trials` CLI option and `maxTrials` in
  `BenchmarkConfig` / `DefaultsConfig`, allowing `BenchmarkRunner` to
  dynamically collect additional measurement trials when initial variance
  exceeds threshold.
- Enhanced `AdaptiveWarmupDetector` to distinguish systemic monotonic drift from
  transient bimodal outliers via `computeRobustSem` and `hasSystemicDrift`.
- Added non-breaking `warmupComplete()` lifecycle hook to `Benchmark` and
  `AsyncBenchmark`.

## 0.2.0

- Added multi-tier Cartesian comparison matrix support (Issue #5) via unified
  `bench_press.yaml` configuration manifest, `--config`, and `--dry-run`
  inspection flag.
- Added N-dimensional `coordinates: Map<String, String>` mapping to
  `BenchmarkEntry` telemetry schema, replacing the single-axis `group` property.
- Added `MarkdownReporter.renderMatrixComparisonTable` to render
  multidimensional matrix reports with grouped left-hand dimension columns and
  Fieller 95% ratio confidence intervals.

- Extracted mathematical and calibration constants (`Lanczos`, `Acklam`, and
  `BenchmarkCalibrator` thresholds) with detailed doc comments.
- Removed legacy transitional `--compare-sdk` option in favor of unified
  Cartesian matrix configurations in `bench_press.yaml`.
- Added positional argument support (`<baseline> [current]`) to
  `bench_press diff` alongside `--baseline` (`-b`) and `--current` (`-c`).
- Added `Blackhole.consumeString` and `Blackhole.consumeObject` overloads with
  `@pragma('dart2js:never-inline')` compiler barriers.
- Added `maxSemRelativeError` option (default `0.03`) to `BenchmarkConfig` for
  steady-state warmup convergence.
- Added `BenchmarkEntry.copyWith` method and updated `BenchmarkEntry.key` to
  include optional `group` (`$name:$target:$group`) with deterministic
  name/target ordering in `BenchmarkSuiteResult.deepMerge`.
- Updated `BenchmarkSuiteResult.groups` to return group names in order of
  appearance rather than sorted alphabetically.
- Aligned default `targetBatchDuration` to `100ms` across CLI runners and
  `BenchmarkConfig`.
- Unified default benchmark discovery directories across `run` and `validate`
  commands (`benchmark`, `benchmarks`, `bench`).
- Simplified benchmark discovery to convention-based matching (targeting files
  ending in `*_benchmark.dart` or `*_bench.dart`) requiring standard
  `void main()` entrypoints, eliminating ad-hoc regex content parsing and
  dynamic wrapper script generation.
- Updated benchmark discovery to default strictly to `benchmark/` (or
  `benchmarks/`, `bench/`) and throw explicit errors (`FormatException` for
  non-Dart files, `PathNotFoundException` for nonexistent paths) rather than
  silently ignoring files or walking the entire repository root.
- Removed `BenchmarkFileKind` enum and dynamic wrapper script generation.
- Removed deprecated `KbssdWarmupDetector` alias in favor of
  `AdaptiveWarmupDetector`.
- Fixed steady-state warmup convergence math using Standard Error of the Mean
  (SEM) relative error (`<= 3%`) and stationarity checks.
- Hardened `Blackhole.drain()` compiler barrier against whole-program Dead-Store
  Elimination across AOT, Wasm, and JavaScript.
- Fixed `BenchmarkCalibrator` to support sub-10µs operations without throwing
  `CalibrationException`, while throwing `CalibrationException` by default when
  maximum probe batches produce zero elapsed ticks (`elapsedUs == 0`) unless
  `forceRun: true` (`--force-run`) is specified (which warns and continues).
- Added `mode` (`'sync'` vs `'async'`) property to `BenchmarkResult` (which
  `BenchmarkEntry.fromResult` now inherits for JSON telemetry).
- Implemented continuous Student's t-distribution quantile calculation
  (regularized incomplete beta for `1 < df < 2` and Hill's Algorithm 396 for
  `df > 2`) for accurate Fieller confidence intervals across all degrees of
  freedom.
- Fixed unhandled exception propagation in Isolate execution mode
  (`BenchmarkProcessRunner`).
- Prevented floating-point overflow in geometric mean speedup reporting via
  log-sum calculation.
- Updated `FiellerInterval.compute` to return `isValid: false` (with `NaN`
  bounds) when sample size is degenerate (`N < 2`).

## 0.1.0

- Initial release of `bench_press`: A modern, statistically sound,
  compiler-aware multi-runtime benchmarking framework for Dart and Flutter.
- Multi-runtime execution support across JIT, AOT (`dart compile exe`), WasmGC
  (`dart compile wasm`), and JavaScript (`dart compile js`).
- `Benchmark`, `AsyncBenchmark`, `BenchmarkVariant`, and `BenchmarkGroup`
  harnesses with lifecycle hooks (`setup`, `run`, `teardown`).
- `Blackhole` dead-code elimination (DCE) sink to safely consume benchmark
  results without compiler dead-code stripping.
- `Throughput` metric tracking for byte rates (`B/s`, `KB/s`, `MB/s`, `GB/s`)
  and element rates (`items/s`, `records/s`, `tokens/s`).
- Automated batch calibration and steady-state warmup convergence detection.
- Statistical summary metrics (Mean, Median, Min, Max, StdDev, CV, p95, p99,
  Ops/sec) with Fieller 95% confidence intervals for variant ratios.
- Markdown reporting with side-by-side variant comparisons and before/after
  baseline diffing.
- `bench_press` CLI with `run`, `validate`, `report`, and `diff` subcommands.
