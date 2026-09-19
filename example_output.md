=== Running Standalone Benchmark Reports ===

Benchmark: fibonacci_recursive
  Mean:       71661.7 ns
  Median:     71101.9 ns
  Min:        69470.8 ns
  Ops/sec:    13954 ops/s
  Is Stable:  ✅ Yes

Benchmark: async_microtask_batch
  Mean:       445.8 ns
  Ops/sec:    2243061 ops/s

Benchmark: string_buffer_variant
  Mean:       15435.9 ns
  Ops/sec:    64784 ops/s

=== Model 1: BenchmarkGroup Results ===
  plus_concat (Baseline): 245577 ops/s (4072.0 ns/op)
  string_buffer: 910840 ops/s (1097.9 ns/op)
  join: 860104 ops/s (1162.7 ns/op)
