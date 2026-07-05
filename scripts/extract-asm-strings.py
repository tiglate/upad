#!/usr/bin/env python3
# Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
# assistance. Licensed under the Apache License, Version 2.0; see
# LICENSE at the repo root for the full text.
#
# extract-asm-strings.py -- xgettext has no NASM support, so translatable
# strings living in src/*.asm are marked with a trailing "; i18n:" comment
# on their `db "...", 0` line (see CLAUDE.md's i18n section) and this
# script picks them up by hand, emitting a .pot-format fragment on stdout.
# Combined with xgettext's own --language=Glade pass over ui/*.ui (which
# handles GtkBuilder/GMenu translatable="yes" strings just fine on its
# own) via msgcat -- see the Makefile's `pot` target.

import glob
import re
import sys

# Matches e.g.:  lbl_cancel   db "_Cancel", 0  ; i18n: optional note
STRING_RE = re.compile(r'db\s+"((?:[^"]|"")*)"\s*,\s*0\b.*;\s*i18n:')


def po_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    entries = []  # (path, lineno, text)
    for path in sorted(glob.glob("src/*.asm")):
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, start=1):
                m = STRING_RE.search(line)
                if not m:
                    continue
                text = m.group(1).replace('""', '"')  # NASM's own quote-doubling escape
                entries.append((path, lineno, text))

    seen = {}
    for path, lineno, text in entries:
        seen.setdefault(text, []).append(f"{path}:{lineno}")

    out = sys.stdout
    for text, refs in seen.items():
        out.write(f"#: {' '.join(refs)}\n")
        out.write(f'msgid "{po_escape(text)}"\n')
        out.write('msgstr ""\n\n')


if __name__ == "__main__":
    main()
