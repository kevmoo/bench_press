import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:bench_press/src/cli/command_runner.dart';
import 'package:io/io.dart';
import 'package:stack_trace/stack_trace.dart';

Future<void> main(List<String> args) async {
  final runner = BenchPressCommandRunner();

  try {
    final status = await runner.run(args);
    exitCode = status ?? ExitCode.success.code;
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln();
    stderr.writeln(e.usage);
    exitCode = ExitCode.usage.code;
  } catch (e, st) {
    stderr.writeln('Fatal error: $e');
    if (args.contains('-v') || args.contains('--verbose')) {
      stderr.writeln(Trace.from(st).terse);
    }
    exitCode = ExitCode.software.code;
  }
}
