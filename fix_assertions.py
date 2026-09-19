with open("test/markdown_reporter_test.dart", "r") as f:
    text = f.read()

# Fix header matching:
text = text.replace('| Benchmark | Target | Baseline | Current',
                    '| Benchmark | Target | Batch | Baseline | Current')
                    
text = text.replace('| Implementation | Ops/sec | Mean Latency',
                    '| Implementation | Batch | Ops/sec | Mean Latency')

with open("test/markdown_reporter_test.dart", "w") as f:
    f.write(text)
