import 'dart:convert';

import 'package:bench_press/bench_press.dart';

/// A realistic structured data record for JSON serialization benchmarks.
final class UserProfile {
  final int id;
  final String name;
  final String email;
  final bool isActive;
  final double score;
  final List<String> tags;

  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.isActive,
    required this.score,
    required this.tags,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'isActive': isActive,
    'score': score,
    'tags': tags,
  };

  factory UserProfile.fromJson(Map<String, Object?> json) => UserProfile(
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

/// Standard JSON encode using dart:convert.
final class JsonEncodeStandardBenchmark extends Benchmark {
  JsonEncodeStandardBenchmark() : super('json_encode/dart_convert');

  @override
  void run() {
    final encoded = jsonEncode(_sampleMap);
    Blackhole.consume(encoded);
  }
}

/// Custom direct buffer JSON serialization.
final class JsonEncodeCustomBenchmark extends Benchmark {
  JsonEncodeCustomBenchmark() : super('json_encode/custom_buffer');

  @override
  void run() {
    final encoded = _sampleUser.toCustomJson();
    Blackhole.consume(encoded);
  }
}

/// Standard JSON decode using dart:convert.
final class JsonDecodeStandardBenchmark extends Benchmark {
  JsonDecodeStandardBenchmark() : super('json_decode/dart_convert');

  @override
  void run() {
    final decoded = jsonDecode(_sampleJsonString);
    Blackhole.consume(decoded);
  }
}

/// Custom JSON parsing into structured model.
final class JsonDecodeModelBenchmark extends Benchmark {
  JsonDecodeModelBenchmark() : super('json_decode/typed_model');

  @override
  void run() {
    final map = jsonDecode(_sampleJsonString) as Map<String, Object?>;
    final user = UserProfile.fromJson(map);
    Blackhole.consume(user);
  }
}

/// Showcase variants comparing serialization approaches.
final BenchmarkVariant jsonVariantBenchmark = BenchmarkVariant(
  'json_variant/encode_comparison',
  () {
    final std = jsonEncode(_sampleMap);
    final custom = _sampleUser.toCustomJson();
    Blackhole.consume(std);
    Blackhole.consume(custom);
  },
);

/// Discovered benchmark collection for `bench_press run` / `validate`.
final List<Object> benchmarks = [
  JsonEncodeStandardBenchmark(),
  JsonEncodeCustomBenchmark(),
  JsonDecodeStandardBenchmark(),
  JsonDecodeModelBenchmark(),
  jsonVariantBenchmark,
];

void main(List<String> args) => mainBenchmarkSuite(benchmarks, args);
