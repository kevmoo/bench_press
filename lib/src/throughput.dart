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
/// `k tokens/s`, `G items/s`).
sealed class const Throughput() {
  /// Declares throughput based on raw byte volume processed per invocation.
  const factory Throughput.bytes(int bytes) = ByteThroughput;

  /// Declares throughput based on discrete items/elements processed per
  /// invocation.
  const factory Throughput.elements(int count, {String unit}) =
      ElementThroughput;

  /// Constructs a [Throughput] definition from a serialized JSON map.
  ///
  /// Throws [FormatException] if `type` is missing or unrecognized, or if
  /// `amount` is negative or not an integer.
  factory Throughput.fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    final amount = (json['amount'] as num?)?.toInt();
    if (amount == null || amount < 0) {
      throw FormatException('Invalid or missing throughput amount: $amount');
    }
    if (type == 'bytes') {
      return ByteThroughput(amount);
    } else if (type == 'elements') {
      final unit = (json['unit'] as String?) ?? 'elements';
      return ElementThroughput(amount, unit: unit);
    }
    throw FormatException('Unrecognized throughput type: "$type"');
  }

  /// Calculates the human-readable rate string given a [meanLatencyNs].
  ///
  /// Returns `'-'` if [meanLatencyNs] is non-positive, NaN, or infinite, or if
  /// the declared throughput volume is zero.
  String formatRate(double meanLatencyNs);

  /// Converts this throughput declaration to a JSON-serializable map.
  Map<String, Object?> toJson();
}

/// Throughput based on raw byte volume.
///
/// Uses standard 1024-based binary scaling (`KB/s`, `MB/s`, `GB/s`) matching
/// standard operating system and I/O benchmarking conventions.
final class const ByteThroughput(
  /// Number of bytes processed per benchmark invocation.
  final int bytes,
) extends Throughput {
  @override
  String formatRate(double meanLatencyNs) {
    if (meanLatencyNs.isNaN ||
        meanLatencyNs.isInfinite ||
        meanLatencyNs <= 0.0 ||
        bytes <= 0) {
      return '-';
    }
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ByteThroughput && other.bytes == bytes);

  @override
  int get hashCode => Object.hash(ByteThroughput, bytes);

  @override
  String toString() => 'Throughput.bytes($bytes)';
}

/// Throughput based on discrete items or element counts.
///
/// Uses standard SI 1000-based decimal scaling (`k`, `M`, `G`) matching
/// discrete item, event, or token processing conventions.
final class const ElementThroughput(
  /// Number of discrete elements processed per benchmark invocation.
  final int count, {

  /// Custom descriptive unit (e.g. 'items', 'records', 'tokens', 'nodes').
  final String unit = 'elements',
}) extends Throughput {
  @override
  String formatRate(double meanLatencyNs) {
    if (meanLatencyNs.isNaN ||
        meanLatencyNs.isInfinite ||
        meanLatencyNs <= 0.0 ||
        count <= 0) {
      return '-';
    }
    final secondsPerOp = meanLatencyNs / 1e9;
    final itemsPerSecond = count / secondsPerOp;

    if (itemsPerSecond >= 1e9) {
      return '${(itemsPerSecond / 1e9).toStringAsFixed(2)}G $unit/s';
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ElementThroughput &&
          other.count == count &&
          other.unit == unit);

  @override
  int get hashCode => Object.hash(ElementThroughput, count, unit);

  @override
  String toString() => 'Throughput.elements($count, unit: "$unit")';
}
