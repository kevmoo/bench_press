## 0.1.1-wip

- Added `--compare-sdk` multi-option flag to `bench_press run` to isolate and strictly evaluate target performance characteristics against different Dart SDK paths using mathematically sound Fieller 95% ratio confidence interval deltas.

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

