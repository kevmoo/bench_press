## 0.3.2-wip

- Added `--pin-cpu` to `bench_press run`, which prefixes every benchmark command
  with `taskset -c` so pinning applies uniformly to the Dart VM, AOT
  executables, Node.js, and D8. Accepts `taskset -c` list syntax (`2`, `0,2,4`,
  `0-3`, `0-7:2`).
  - A malformed CPU list is a **usage error**: `run` exits `64` without
    measuring, matching `--d8-path` and `--node-path`. Only the syntax is
    checked, so a CPU that does not exist on the host is still reported by
    `taskset` after compilation; the host CPU count is deliberately not used as
    a bound, since a process confined to a narrower cpuset would then be told
    valid CPUs are invalid.
  - Host and mode limitations warn on stderr and continue unpinned: a non-Linux
    host, `taskset` absent from `PATH`, and `--isolate-mode`, which runs
    in-process and so has no command to wrap. Under `--isolate-mode` the warning
    distinguishes a run that still has spawned targets to pin from a JIT-only
    run, where nothing is pinned at all.
  - **Windows and macOS are unsupported for different reasons**, and the warning
    says which. Windows has processor affinity but as a bitmask rather than a
    CPU list, so it points at setting affinity on the process directly; macOS
    has no affinity interface at all, so it points at `--trials` instead.
    Neither message offers a command to paste, because none has been exercised
    on those platforms — CI runs Linux only today.
- `ThroughputPlausibility.screenInvariance` now also compares across the arms of
  a comparison group, so it catches the defect when each payload size carries
  its own benchmark name (`write_200_fixed_13b` / `_1mb`) instead of one name
  recurring across groups. The previous release note claimed it caught a 256 KiB
  case the bandwidth ceiling misses; that was only true for the recurring-name
  shape, and the original defect was in the other one. Group-scoped findings set
  `InvariantLatency.groupScoped` and are worded as such in the report.
- Narrowed the invariance test from a ceiling to a band
  (`minInvariantLatencyRatio` 0.9 to `maxInvariantLatencyRatio` 1.25). A payload
  that is never read gives a latency ratio of ~1.0, so a large payload coming
  out materially _faster_ is not invariance — it means the two points are doing
  different work. Without the floor, a group holding unrelated arms read as a
  finding on real output.
- Added `ThroughputPlausibility`, which screens benchmarks that declare
  `Throughput.bytes` for two signs of a payload that is never actually read, and
  `MarkdownReporter.renderSuite` banners naming what it finds. Such a benchmark
  reports a rate bounded by loop overhead rather than data movement, which can
  be an order of magnitude past what the hardware can do. `screenSuite` catches
  rates above a memory-bandwidth ceiling; `screenInvariance` catches a benchmark
  whose latency does not move when its payload does, which works at payload
  sizes small enough to stay under that ceiling.
- Stopped `MarkdownReporter` from wrapping tables in `mdformat off` /
  `mdformat on` HTML-comment guards. Those guards are a Google3/Piper
  convention; on GitHub they are inert comments that every consumer then has to
  strip out of committed reports. Every table row is already emitted on a single
  physical line, so nothing relied on them.
- **Breaking (behavioral)**: an explicitly configured Dart SDK is now
  authoritative. When `customSdkPath` (the `sdk` matrix axis) is set but does
  not resolve to a usable SDK, `DartSdk.dartExecutable` returns `null` instead
  of silently falling back to `dart` on `PATH`. Previously a mistyped or stale
  configured path would compile and benchmark whatever SDK happened to be on
  `PATH`, with no warning and nothing downstream able to tell the difference.
- Added `DartSdk.explicitSdkError`, which explains why a configured SDK path was
  rejected. `TargetCompiler` now reports it instead of the generic "not found on
  PATH or DART_SDK", which named the two sources that are not consulted once an
  explicit path is supplied.
- Updated `bench_press run` and `bench_press validate`
  (`BenchmarkDiscovery.discoverAll` and `resolveTargetPaths`) to discover and
  execute all positional file and directory paths supplied on the command line
  rather than silently ignoring arguments after the first path.
- Computed post-warmup calibration batch sizes directly from steady-state warmup
  convergence latencies via `BenchmarkCalibrator.calibratedBatchForDuration`,
  eliminating redundant probe loops.
- Invoked `warmupComplete()` hook in `runVariant()`.
- Added Fieller confidence interval and `isRobustStable` gating to
  `MarkdownReporter` (`gate: true` by default, configurable via `--[no-]gate` in
  `bench_press run`, `report`, and `diff`), rendering `unresolved` and excluding
  unstable or unbounded-CI comparisons from geometric mean rollup metrics.
- Added `Batch` column to `MarkdownReporter` variant, matrix, and delta tables
  alongside a `>2.0x` batch-size divergence warning banner.
- Updated `BenchmarkRunner` (`run`, `runAsync`, `runVariant`) to perform
  post-warmup recalibration via `BenchmarkCalibrator` before recording
  measurement trials, warning when steady-state batch size increases by `>10x`.
- Fixed `MarkdownReporter.renderSuite` and `renderMatrixComparisonTable` so
  suites mixing standalone benchmarks and `BenchmarkGroup` variants collate
  grouped variants into a single multi-row `### Group: ...` comparison table
  with the baseline ordered first and a geometric mean summary footer.

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
