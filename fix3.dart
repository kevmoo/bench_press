import 'dart:io';

void main() {
  var file = File('test/markdown_reporter_test.dart');
  var content = file.readAsStringSync();
  content = content.replaceAll(
    'MarkdownReporter.renderGroupComparisonTable(\n        group,\n      )',
    'MarkdownReporter.renderGroupComparisonTable(\n        group, gate: false,\n      )',
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
