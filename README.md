# 🏋️ BenchPress (`pkg:bench_press`)

A modern, statistically sound, compiler-aware multi-runtime benchmarking framework for Dart and Flutter.

---

## 🚀 Features

* **Dead Code Elimination (DCE) Barrier**: `Blackhole` with cross-backend inlining pragmas preventing compiler loop elimination across VM JIT, AOT, WasmGC, and dart2js with zero per-iteration heap allocations.
* **Monomorphic Inner Batching**: Calibrated batch execution ($N$ iterations per single timer read divided by $N$) with zero polymorphic dispatch or timer overhead in the hot loop.
* **Statistical Rigor & Steady-State Detection**: KBSSD (Kallithea-Borg Self-Stopping Detection) with sliding window MMD (Maximum Mean Discrepancy), MAD dynamic thresholding, and SEM practical steady-state gating.
* **Operational Calibration Guards**: 10 µs - 200 ms runtime bounds, Web timer virtualization accommodations (Spectre coarse timer handling in JS/Wasm), and `--force-run` bypass.
* **Multi-Target CLI Orchestrator**: 1-command build, execute, and compare across VM JIT, AOT, WasmGC, and JS.
* **Telemetry & Diffs**: Deterministic JSON persistence, zero-token rehydration (`--from-json`), git baseline diffing (`--diff <ref>`), and `[Worst / Avg / Best]` relative efficiency triplets.

---

## 📦 Getting Started

```dart
import 'package:bench_press/bench_press.dart';

void main() {
  Benchmark(
    'String Concatenation',
    config: BenchmarkConfig(trials: 15),
  ).run();
}
```
