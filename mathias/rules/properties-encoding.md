---
paths:
  - "**/*.properties"
---

# Properties Files Are ISO-8859-1

`*.properties` in this repo are ISO-8859-1 (`forbidden-apis.md`). The Edit and Write tools re-save a
file as UTF-8, so touching one line of a file that holds non-ASCII bytes (`Temporäre Test-DB`, `0xE4`)
silently rewrites every umlaut in it (`0xC3 0xA4`). Mathias has had to revert exactly that.

- Pure-ASCII append: `cat >> file << 'EOF'`.
- Anything else: `sed -i` or a Python `open(path, 'rb')` / `'wb'` round-trip — byte-preserving.
- Check before and after: `tr -dc '\200-\377' < file | od -An -tx1`.
- Never offer `git checkout --` or a self-replacing edit to repair a corrupted file unasked; he
  prefers to revert manually.
