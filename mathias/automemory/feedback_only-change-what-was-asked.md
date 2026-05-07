---
name: Only change what was asked
description: Do not modify file content the user did not ask about. Especially watch for silent encoding/whitespace/format drift caused by tooling.
type: feedback
---

Stay strictly within the scope of the user's request. Never silently change unrelated content — including encoding, whitespace, line endings, or character substitutions in lines you did not need to touch.

**Why:** When editing `application-TEST.properties`, `application-QAS.properties`, and `application-PROD.properties`, the Edit tool re-saved the files in UTF-8 even though the project requires ISO-8859-1 for properties files (per `.claude/rules/forbidden-apis.md`). The byte `0xE4` (`ä`) in `Temporäre Test-DB` got rewritten as the UTF-8 sequence `0xC3 0xA4`. The user noticed and was annoyed: "never ever change something like this if I did not explicitly ask for it." They reverted the encoding themselves and refused offered cleanup edits.

**How to apply:**
- For IFAS13 properties files specifically: they MUST stay ISO-8859-1. Do not write to them with the Edit/Write tools when they contain non-ASCII bytes — those tools normalize to UTF-8. Use `cat >> ... << 'EOF'` for pure-ASCII appends, or a Python `open(..., 'rb')` round-trip when fixing bytes.
- More generally: when an edit's diff would include lines you did not need to change, stop and rewrite the edit to be narrower. If a tool insists on rewriting unrelated bytes, switch to a different tool rather than accepting collateral changes.
- If you have already corrupted something, do not propose `git checkout --` or self-replacement edits without explicit permission — the user may prefer to revert manually.