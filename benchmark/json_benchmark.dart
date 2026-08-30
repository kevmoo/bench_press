import 'dart:convert';

import 'package:bench_press/bench_press.dart';

/// A realistic structured data record for JSON serialization benchmarks.
final class const UserProfile({
  required final int id,
  required final String name,
  required final String email,
  required final bool isActive,
  required final double score,
  required final List<String> tags,
}) {
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'isActive': isActive,
    'score': score,
    'tags': tags,
  };

  factory fromJson(Map<String, Object?> json) => UserProfile(
    id: json['id'] as int,
    name: json['name'] as String,
    email: json['email'] as String,
    isActive: json['isActive'] as bool,
    score: (json['score'] as num).toDouble(),
    tags: (json['tags'] as List<Object?>).cast<String>(),
  );

  /// Custom lightweight manual JSON serializer writing directly to a buffer.
  String toCustomJson() {
    final sb = StringBuffer('{"id":')
      ..write(id)
      ..write(',"name":"')
      ..write(name)
      ..write('","email":"')
      ..write(email)
      ..write('","isActive":')
      ..write(isActive)
      ..write(',"score":')
      ..write(score)
      ..write(',"tags":[');
    for (var i = 0; i < tags.length; i++) {
      if (i > 0) sb.write(',');
      sb
        ..write('"')
        ..write(tags[i])
        ..write('"');
    }
    sb.write(']}');
    return sb.toString();
  }
}

const UserProfile _sampleUser = UserProfile(
  id: 42891,
  name: 'Alex Mercer',
  email: 'alex.mercer@example.com',
  isActive: true,
  score: 98.75,
  tags: ['engineering', 'dart', 'performance', 'wasm', 'compiler'],
);

final Map<String, Object?> _sampleMap = _sampleUser.toJson();
final String _sampleJsonString = jsonEncode(_sampleMap);

/// Model 1: Grouped JSON Serialization Variants
final BenchmarkGroup jsonSerializationGroup = BenchmarkGroup(
  'JSON Serialization',
  [
    BenchmarkVariant(
      'dart_convert',
      () {
        final encoded = jsonEncode(_sampleMap);
        Blackhole.consume(encoded);
      },
      isBaseline: true,
      throughput: Throughput.bytes(_sampleJsonString.length),
    ),
    BenchmarkVariant('custom_buffer', () {
      final encoded = _sampleUser.toCustomJson();
      Blackhole.consume(encoded);
    }, throughput: Throughput.bytes(_sampleJsonString.length)),
  ],
);

/// Model 1: Grouped JSON Deserialization Variants
final BenchmarkGroup jsonDeserializationGroup = BenchmarkGroup(
  'JSON Deserialization',
  [
    BenchmarkVariant(
      'dart_convert',
      () {
        final decoded = jsonDecode(_sampleJsonString);
        Blackhole.consume(decoded);
      },
      isBaseline: true,
      throughput: Throughput.bytes(_sampleJsonString.length),
    ),
    BenchmarkVariant('typed_model', () {
      final map = jsonDecode(_sampleJsonString) as Map<String, Object?>;
      final user = UserProfile.fromJson(map);
      Blackhole.consume(user);
    }, throughput: Throughput.bytes(_sampleJsonString.length)),
  ],
);

/// Discovered benchmark collection for `bench_press run` / `validate`.
final List<Object> benchmarks = [
  jsonSerializationGroup,
  jsonDeserializationGroup,
];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
