import 'dart:io';

/// Whether ANSI color and cursor escapes should be used on standard output.
///
/// Evaluates whether standard output is connected to a terminal, supports ANSI
/// escapes, and respects the `NO_COLOR` environment variable standard.
bool get useAnsi =>
    stdout.hasTerminal &&
    stdout.supportsAnsiEscapes &&
    !Platform.environment.containsKey('NO_COLOR');
