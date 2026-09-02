## 0.2.0-wip

- Extracted mathematical and calibration constants (`Lanczos`, `Acklam`, and `BenchmarkCalibrator` thresholds) with detailed doc comments.
- Added `--compare-sdk` multi-option flag to `bench_press run` to isolate and strictly evaluate target performance characteristics against different Dart SDK paths using mathematically sound Fieller 95% ratio confidence interval deltas.
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

