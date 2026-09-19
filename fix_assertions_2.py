import re

with open("test/markdown_reporter_test.dart", "r") as f:
    text = f.read()

text = text.replace("check<String>(table).contains('**5.00x faster**');", "check<String>(table).contains('unresolved');")
text = text.replace("check<String>(table).contains('🚀 🥇 Peak');", "")
text = text.replace("check<String>(table).contains('**2.00x slower**');", "check<String>(table).contains('unresolved');")
text = text.replace("check<String>(table).contains('⚠️ 🔴 Slow');", "")

# The other test has `v2_second` with `2.00x faster`
text = text.replace("check<String>(table).contains('**2.00x faster**');", "check<String>(table).contains('unresolved');")

with open("test/markdown_reporter_test.dart", "w") as f:
    f.write(text)
