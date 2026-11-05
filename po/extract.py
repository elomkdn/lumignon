#!/usr/bin/env python3
"""Writes po/template.pot from the i18n() and i18nc() calls in the QML files.

xgettext's JavaScript lexer drops non-ASCII characters (…, “ ”, ·) from QML strings,
so the strings are read here instead. Then, to bring the French catalog up to date:
    msgmerge --update --no-wrap po/fr.po po/template.pot
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRING = r'"((?:[^"\\]|\\.)*)"'
CALL = re.compile(r'\bi18n\(\s*' + STRING + r'|\bi18nc\(\s*' + STRING + r'\s*,\s*' + STRING)


def po_string(text):
    return json.dumps(text, ensure_ascii=False)


entries = {}
for path in sorted((ROOT / "package/contents/ui").glob("*.qml")):
    source = path.read_text(encoding="utf-8")
    for match in CALL.finditer(source):
        line = source.count("\n", 0, match.start()) + 1
        if match.group(1) is not None:
            key = (None, json.loads('"' + match.group(1) + '"'))
        else:
            key = (json.loads('"' + match.group(2) + '"'), json.loads('"' + match.group(3) + '"'))
        entries.setdefault(key, []).append(f"{path.relative_to(ROOT)}:{line}")

out = ['msgid ""', 'msgstr ""', '"Content-Type: text/plain; charset=UTF-8\\n"', ""]
for (context, msgid), places in entries.items():
    out.append("#: " + " ".join(places))
    if "%" in msgid:
        out.append("#, kde-format")
    if context is not None:
        out.append("msgctxt " + po_string(context))
    out += ["msgid " + po_string(msgid), 'msgstr ""', ""]
(ROOT / "po/template.pot").write_text("\n".join(out), encoding="utf-8")
print(f"{len(entries)} strings")
