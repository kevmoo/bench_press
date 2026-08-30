import 'dart:io';

import 'package:bench_press/src/cli/command_runner.dart';

Future<void> main(List<String> args) async {
  final runner = BenchPressCommandRunner();
  final exitCode = await runner.run(args);
  exit(exitCode);
}
