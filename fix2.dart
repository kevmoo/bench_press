import 'dart:io';

void main() {
  var file = File('test/markdown_reporter_test.dart');
  var content = file.readAsStringSync();
  content = content.replaceAll(
    'MarkdownReporter.renderDeltaTable(baseSuite, currentSuite)',
    'MarkdownReporter.renderDeltaTable(baseSuite, currentSuite, gate: false)',
  );
  content = content.replaceAll(
    'MarkdownReporter.renderGroupComparisonTable(group)',
    'MarkdownReporter.renderGroupComparisonTable(group, gate: false)',
  );
  content = content.replaceAll(
    'MarkdownReporter.renderSuite(suite)',
    'MarkdownReporter.renderSuite(suite, gate: false)',
  );
  file.writeAsStringSync(content);
}
