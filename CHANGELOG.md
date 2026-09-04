## 0.3.0-wip

- Added explicit CLI options `--d8-path` and `--node-path` to `bench_press run` and `bench_press validate`, supporting custom binary overrides, `D8_PATH` and `NODE_PATH` environment variables, and SDK auto-probing for bundled D8 under `bin/resources/dart2wasm/d8` (Issue #19).
- Fixed silent crashes on Node.js for JS and Wasm targets by replacing `stdout.writeln` with `print`, generating self-invoking `.run.mjs` and `.node.cjs` wrappers with unhandled rejection listeners, and forwarding CLI arguments via `dartMainRunner` (Issue #29).
- Added parameterized matrix group builder `BenchmarkGroup.matrix<T>` (and convenience `Benchmark.matrix<T>`) and `BenchmarkMatrix<T>` to benchmark competing implementations across parameterized inputs or datasets without repetitive boilerplate (Issue #23).
- Added `mainBenchmarkMatrix` CLI entrypoint and updated `mainBenchmarkSuite` to execute `BenchmarkMatrix` instances seamlessly.
- Added robust dispersion metrics to `BenchmarkMetrics`: Median Absolute Deviation (`madNs`), normal-consistent robust CV (`robustCv = (1.4826 * madNs) / medianNs`), and Interquartile Range (`iqrNs`).
- Added `isRobustStable` to `BenchmarkMetrics` and updated `isStable` to incorporate robust dispersion, preventing transient bimodal GC sweeps from falsely failing steady-state stability for allocation-heavy workloads (Issue #20).
- Added adaptive trial scaling via `--max-trials` CLI option and `maxTrials` in `BenchmarkConfig` / `DefaultsConfig`, allowing `BenchmarkRunner` to dynamically collect additional measurement trials when initial variance exceeds threshold.
- Enhanced `AdaptiveWarmupDetector` to distinguish systemic monotonic drift from transient bimodal outliers via `computeRobustSem` and `hasSystemicDrift`.
- Added non-breaking `warmupComplete()` lifecycle hook to `Benchmark` and `AsyncBenchmark`.
- **Breaking Change**: Streamlined `Blackhole` API to a single universal `consume(Object? value)` method. Removed redundant specialized methods (`consumeInt`, `consumeDouble`, `consumeBool`, `consumeString`, `consumeObject`).
- Hardened `Blackhole` compiler barrier against optimizing compiler Dead Code Elimination:
  - Adopted 3-bit cyclic Gray-code ring buffer indexing (`(index & 7) ^ ((index & 7) >> 1)`) to disrupt compiler loop unrolling and vectorization without consecutive slot collisions.
  - Coupled slot position with element hashing in `Blackhole.drain()` via `Object.hash(_sink[i], i)` to guarantee position-dependent reduction.
  - Corrected documentation regarding retention guarantees (retains the last 8 writes across the cyclic Gray-code buffer).
  - Fixed 5.2x latency cliff on Web/JavaScript previously caused by eager `double.hashCode` computation.

## 0.2.0

- Added multi-tier Cartesian comparison matrix support (Issue #5) via unified `bench_press.yaml` configuration manifest, `--config`, and `--dry-run` inspection flag.
- Added N-dimensional `coordinates: Map<String, String>` mapping to `BenchmarkEntry` telemetry schema, replacing the single-axis `group` property.
- Added `MarkdownReporter.renderMatrixComparisonTable` to render multidimensional matrix reports with grouped left-hand dimension columns and Fieller 95% ratio confidence intervals.

- Extracted mathematical and calibration constants (`Lanczos`, `Acklam`, and `BenchmarkCalibrator` thresholds) with detailed doc comments.
- Removed legacy transitional `--compare-sdk` option in favor of unified Cartesian matrix configurations in `bench_press.yaml`.
- Added positional argument support (`<baseline> [current]`) to `bench_press diff` alongside `--baseline` (`-b`) and `--current` (`-c`).
- Added `Blackhole.consumeString` and `Blackhole.consumeObject` overloads with `@pragma('dart2js:never-inline')` compiler barriers.
- Added `maxSemRelativeError` option (default `0.03`) to `BenchmarkConfig` for steady-state warmup convergence.
- Added `BenchmarkEntry.copyWith` method and updated `BenchmarkEntry.key` to include optional `group` (`$name:$target:$group`) with deterministic name/target ordering in `BenchmarkSuiteResult.deepMerge`.
- Updated `BenchmarkSuiteResult.groups` to return group names in order of appearance rather than sorted alphabetically.
- Aligned default `targetBatchDuration` to `100ms` across CLI runners and `BenchmarkConfig`.
- Unified default benchmark discovery directories across `run` and `validate` commands (`benchmark`, `benchmarks`, `bench`).
- Simplified benchmark discovery to convention-based matching (targeting files ending in `*_benchmark.dart` or `*_bench.dart`) requiring standard `void main()` entrypoints, eliminating ad-hoc regex content parsing and dynamic wrapper script generation.
- Updated benchmark discovery to default strictly to `benchmark/` (or `benchmarks/`, `bench/`) and throw explicit errors (`FormatException` for non-Dart files, `PathNotFoundException` for nonexistent paths) rather than silently ignoring files or walking the entire repository root.
- Removed `BenchmarkFileKind` enum and dynamic wrapper script generation.
- Removed deprecated `KbssdWarmupDetector` alias in favor of `AdaptiveWarmupDetector`.
- Fixed steady-state warmup convergence math using Standard Error of the Mean (SEM) relative error (`<= 3%`) and stationarity checks.
- Hardened `Blackhole.drain()` compiler barrier against whole-program Dead-Store Elimination across AOT, Wasm, and JavaScript.
- Fixed `BenchmarkCalibrator` to support sub-10µs operations without throwing `CalibrationException`, while throwing `CalibrationException` by default when maximum probe batches produce zero elapsed ticks (`elapsedUs == 0`) unless `forceRun: true` (`--force-run`) is specified (which warns and continues).
- Added `mode` (`'sync'` vs `'async'`) property to `BenchmarkResult` (which `BenchmarkEntry.fromResult` now inherits for JSON telemetry).
- Implemented continuous Student's t-distribution quantile calculation (regularized incomplete beta for `1 < df < 2` and Hill's Algorithm 396 for `df > 2`) for accurate Fieller confidence intervals across all degrees of freedom.
- Fixed unhandled exception propagation in Isolate execution mode (`BenchmarkProcessRunner`).
- Prevented floating-point overflow in geometric mean speedup reporting via log-sum calculation.
- Updated `FiellerInterval.compute` to return `isValid: false` (with `NaN` bounds) when sample size is degenerate (`N < 2`).

## 0.1.0

- Initial release of `bench_press`: A modern, statistically sound, compiler-aware multi-runtime benchmarking framework for Dart and Flutter.
- Multi-runtime execution support across JIT, AOT (`dart compile exe`), WasmGC (`dart compile wasm`), and JavaScript (`dart compile js`).
- `Benchmark`, `AsyncBenchmark`, `BenchmarkVariant`, and `BenchmarkGroup` harnesses with lifecycle hooks (`setup`, `run`, `teardown`).
- `Blackhole` dead-code elimination (DCE) sink to safely consume benchmark results without compiler dead-code stripping.
- `Throughput` metric tracking for byte rates (`B/s`, `KB/s`, `MB/s`, `GB/s`) and element rates (`items/s`, `records/s`, `tokens/s`).
- Automated batch calibration and steady-state warmup convergence detection.
- Statistical summary metrics (Mean, Median, Min, Max, StdDev, CV, p95, p99, Ops/sec) with Fieller 95% confidence intervals for variant ratios.
- Markdown reporting with side-by-side variant comparisons and before/after baseline diffing.
- `bench_press` CLI with `run`, `validate`, `report`, and `diff` subcommands.

