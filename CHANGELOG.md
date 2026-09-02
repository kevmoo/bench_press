## 0.1.1-wip

- Added `--compare-sdk` multi-option flag to `bench_press run` to isolate and strictly evaluate target performance characteristics against different Dart SDK paths using mathematically sound Fieller 95% ratio confidence interval deltas.
- Renamed `KbssdWarmupDetector` to `AdaptiveWarmupDetector` (`src/stats/warmup.dart`) and deprecated the old name.
- Fixed steady-state warmup convergence math using Standard Error of the Mean (SEM) relative error (`<= 3%`) and stationarity checks.
- Hardened `Blackhole.drain()` compiler barrier against whole-program Dead-Store Elimination across AOT, Wasm, and JavaScript.
- Fixed `BenchmarkCalibrator` to support sub-10µs operations without throwing `CalibrationException`, and capped exponential probing growth.
- Implemented continuous Student's t-distribution quantile calculation (Hill's Algorithm 396) for accurate Fieller confidence intervals across all degrees of freedom.
- Fixed unhandled exception propagation in Isolate execution mode (`BenchmarkProcessRunner`).
- Stripped comments during benchmark discovery and disambiguated generated wrapper filenames.
- Prevented floating-point overflow in geometric mean speedup reporting via log-sum calculation.
- Updated FiellerInterval.compute to return isValid: false (with NaN bounds) when sample size is degenerate (N < 2).

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

