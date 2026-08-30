// ignore_for_file: unnecessary_type_name_in_constructor

/// Represents the data volume or discrete element count processed per
/// benchmark invocation.
///
/// Use `Throughput.bytes` for data processing, serializers, codecs,
/// compression, cryptography, and network I/O to automatically compute and
/// format data rates (`B/s`, `KB/s`, `MB/s`, `GB/s`).
///
/// Use `Throughput.elements` for discrete items, records, AST nodes, or event
/// counts to compute item processing rates (`items/s`, `records/s`,
/// `k tokens/s`).
sealed class const Throughput() {
  /// Declares throughput based on raw byte volume processed per invocation.
  const factory Throughput.bytes(int bytes) = ByteThroughput;

  /// Declares throughput based on discrete items/elements processed per
  /// invocation.
  const factory Throughput.elements(int count, {String unit}) =
      ElementThroughput;

  /// Constructs a [Throughput] definition from a serialized JSON map.
  factory Throughput.fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    final amount = (json['amount'] as num?)?.toInt() ?? 0;
    if (type == 'bytes') {
      return ByteThroughput(amount);
    } else {
      final unit = (json['unit'] as String?) ?? 'elements';
      return ElementThroughput(amount, unit: unit);
    }
  }

  /// Calculates the human-readable rate string given a [meanLatencyNs].
  String formatRate(double meanLatencyNs);

  /// Converts this throughput declaration to a JSON-serializable map.
  Map<String, Object?> toJson();
}

/// Throughput based on raw byte volume.
final class const ByteThroughput(
  /// Number of bytes processed per benchmark invocation.
  final int bytes,
) extends Throughput {
  @override
  String formatRate(double meanLatencyNs) {
    if (meanLatencyNs <= 0.0 || bytes <= 0) return '-';
    final secondsPerOp = meanLatencyNs / 1e9;
    final bytesPerSecond = bytes / secondsPerOp;

    if (bytesPerSecond >= 1024 * 1024 * 1024) {
      final gbPerSec = bytesPerSecond / (1024 * 1024 * 1024);
      return '${gbPerSec.toStringAsFixed(2)} GB/s';
    } else if (bytesPerSecond >= 1024 * 1024) {
      final mbPerSec = bytesPerSecond / (1024 * 1024);
      return '${mbPerSec.toStringAsFixed(1)} MB/s';
    } else if (bytesPerSecond >= 1024) {
      final kbPerSec = bytesPerSecond / 1024;
      return '${kbPerSec.toStringAsFixed(1)} KB/s';
    } else {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
  }

  @override
  Map<String, Object?> toJson() => {'type': 'bytes', 'amount': bytes};

  @override
  String toString() => 'Throughput.bytes($bytes)';
}

/// Throughput based on discrete items or element counts.
final class const ElementThroughput(
  /// Number of discrete elements processed per benchmark invocation.
  final int count, {

  /// Custom descriptive unit (e.g. 'items', 'records', 'tokens', 'nodes').
  final String unit = 'elements',
}) extends Throughput {
  @override
  String formatRate(double meanLatencyNs) {
    if (meanLatencyNs <= 0.0 || count <= 0) return '-';
    final secondsPerOp = meanLatencyNs / 1e9;
    final itemsPerSecond = count / secondsPerOp;

    if (itemsPerSecond >= 1e9) {
      return '${(itemsPerSecond / 1e9).toStringAsFixed(2)}B $unit/s';
    } else if (itemsPerSecond >= 1e6) {
      return '${(itemsPerSecond / 1e6).toStringAsFixed(1)}M $unit/s';
    } else if (itemsPerSecond >= 1e3) {
      return '${(itemsPerSecond / 1e3).toStringAsFixed(1)}k $unit/s';
    } else {
      return '${itemsPerSecond.toStringAsFixed(0)} $unit/s';
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'elements',
    'amount': count,
    'unit': unit,
  };

  @override
  String toString() => 'Throughput.elements($count, unit: "$unit")';
}
