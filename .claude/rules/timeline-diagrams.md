---
paths:
  - "**/geschaeftsjahr/*Test*.java"
  - "**/geschaeftsjahr/*Calculator*.java"
---

# Timeline Diagrams for Geschaeftsjahre Tests

## Overview

ASCII timeline diagrams in Javadoc comments visualize fiscal year (Geschaeftsjahr/GJ) calculations. They show the relationship between dates, fund periods, and calculated GJ results.

## Diagram Structure

A complete diagram has these layers (top to bottom):

```
*                                                               Stichtag
*                                                                  ▼
* Dates:       2022-04-01          2023-03-31          2024-03-31  2024-06-15          2025-03-31
* Timeline: ───┼───────────────────┼───────────────────┼───────────┼───────────────────┼─────▶
*              │                   │                   │           │                   │
* Fonds:    ◀──┴───────────────────┴───────────────────┴───────────┴───────────────────┴────▶
*              │                   │                   │                               │
* Result:      ├───────────────────┼───────────────────┼───────────────────────────────┤
*              │    lastBut1Gj     │      lastGj       │           nextGj              │
*              │   (Apr22-Mar23)   │   (Apr23-Mar24)   │        (Apr24-Mar25)          │
*              └───────────────────┴───────────────────┴───────────────────────────────┘
```

### Layer Descriptions

1. **Stichtag label + arrow**: Shows the reference date position
2. **Dates line**: All relevant dates (GJ start dates, end dates, Stichtag)
3. **Timeline line**: Horizontal line with `┼` markers at each date position
4. **Vertical connectors**: `│` lines connecting Timeline to layers below
5. **Fonds line**: Fund period with `◀──` and `──▶` for far past/future
6. **Result line**: GJ periods with boundaries (`├`, `┼`, `┤`) and labels

## Positioning Rules

### Base Positions

- `"* "` prefix = 2 characters (positions 0-1)
- `"* Dates:       "` = 15 characters, first date starts at **position 15**
- `"* Timeline: ───┼"` = first `┼` at **position 15**

### Spacing Patterns

**Calendar Year GJs (12-character spacing):**
- Date format: 10-char date + 2 spaces = 12 characters
- Timeline: 11 dashes + 1 `┼` marker = 12 characters
- Positions: 15, 27, 39, 51, 63, 75...

**Non-Calendar Year GJs (20-character spacing):**
- Date format: 10-char date + 10 spaces = 20 characters
- Timeline: 19 dashes + 1 `┼` marker = 20 characters
- Positions: 15, 35, 55, 75, 95...

**Compressed spacing** (for dates close together like Stichtag near GJ end):
- Use 2 spaces instead of 10 between adjacent dates
- Adjust Timeline dashes accordingly (11 dashes + 1 `┼`)

## Alignment Rules

### CRITICAL: Arrow (`▼`) Alignment for ALL Labels

**THIS IS THE MOST IMPORTANT RULE. ALWAYS VERIFY THIS ALIGNMENT.**

**This rule applies to ALL labeled arrows, not just Stichtag:**
- `Stichtag` - reference date for calculation
- `fondsBeginn` - fund start date
- `fondsEnde` - fund end date
- `lastChance` - deadline date
- `mahnungAb` - reminder start date
- `snBeginn` - SN period start date

**Every `▼` arrow MUST align exactly with:**
1. The corresponding `┼` marker on the Timeline line
2. The **first character** of the labeled date on the Dates line

**Why this matters:** Misaligned arrows make diagrams confusing and defeat their purpose of showing temporal relationships clearly.

**How to verify alignment:**
1. Count the character position of the labeled date on the Dates line
2. The `▼` must be at exactly the same position
3. The `┼` on Timeline must also be at exactly the same position

**Calculation method:**
```
Position of ▼ = Position of labeled date on Dates line
             = "* " (2 chars) + spaces to reach date position

Step-by-step:
1. Find where the labeled date starts on Dates line
2. Count characters from line start to first char of date
3. Place ▼ at exactly that position on the line above
4. Place ┼ at exactly that position on the Timeline line
```

**Example with single label:**
```
*                                                                 Stichtag
*                                                                    ▼      ← position 67
* Dates:       2021-07-01          2022-06-30          2023-06-30  2024-05-15  ← starts at position 67
* Timeline: ───┼───────────────────┼───────────────────┼───────────┼─────▶     ← ┼ at position 67
```

**Example with multiple labels:**
```
*                         fondsBeginn                 Stichtag
*                              ▼                         ▼
* Dates:       2023-01-01  2023-06-15  2023-12-31  2024-06-15  2024-12-31
* Timeline: ───┼───────────┼───────────┼───────────┼───────────┼─────▶
```
Both ▼ arrows must align with their respective dates and ┼ markers.

**Common alignment errors:**
- Off by 1-2 characters due to miscounting spaces
- Forgetting that `"* "` prefix is 2 characters
- Not accounting for variable-width spacing between dates
- Aligning label text instead of the ▼ arrow

### Vertical Line Alignment

All vertical elements must align with `┼` markers:
- `│` (vertical line)
- `┴` (bottom connector in Fonds line)
- `├` (left edge of Result)
- `┼` (internal boundary in Result)
- `┤` (right edge of Result)

### GJ Boundaries in Result Section

**Always create vertical lines between GJs:**
- Each GJ must have clear boundaries
- For N GJs, you need N+1 vertical markers (left edge + N-1 internal + right edge)

**Example with 3 GJs:**
```
* Result:      ├───────────────────┼───────────────────┼───────────────────────────────┤
*              │    lastBut1Gj     │      lastGj       │           nextGj              │
```
- `├` at position 15 (left edge / end of first GJ)
- `┼` at position 35 (boundary between GJ 1 and GJ 2)
- `┼` at position 55 (boundary between GJ 2 and GJ 3)
- `┤` at end (right edge / end of last GJ)

## Date Selection

### Include These Dates

1. **Start date of first GJ** (to properly show all GJs in Result section)
2. **End dates of all GJs** (these are the GJ boundaries)
3. **Stichtag** (reference date for calculation)

### Skip Stichtag in Result Section

The Stichtag position should NOT have a `┼` in the Result section if it's not a GJ boundary (i.e., when Stichtag falls inside a GJ period).

## Box-Drawing Characters Reference

```
─  Horizontal line
│  Vertical line
┼  Cross (date marker on Timeline)
├  Left T (Result left edge)
┤  Right T (Result right edge)
┴  Bottom T (Fonds connectors)
└  Bottom-left corner
┘  Bottom-right corner
▼  Down arrow (Stichtag pointer)
◀  Left arrow (far past)
▶  Right arrow (far future / timeline continuation)
═  Double horizontal (alternative for emphasis)
```

## Verification Checklist

1. [ ] First `┼` is at position 15
2. [ ] All dates have consistent spacing (12 or 20 chars, or compressed where needed)
3. [ ] `▼` aligns exactly with Stichtag date and corresponding `┼`
4. [ ] All `│`, `┴`, `├`, `┤` align with `┼` markers above
5. [ ] Result section has vertical lines between ALL adjacent GJs
6. [ ] Stichtag position in Result has `┼` only if it's a GJ boundary

## Common Mistakes

1. **Off-by-one `▼`**: Count spaces carefully - position = 2 + number_of_spaces
2. **Missing GJ boundary**: Always show vertical separator between adjacent GJs
3. **Inconsistent spacing**: Mix of 12-char and 20-char spacing causes misalignment
4. **Wrong first position**: First marker must be at position 15
5. **Stichtag as boundary**: Don't add `┼` in Result for Stichtag unless it's actually a GJ end date
6. **Dates out of chronological order**: ALL dates on the Dates line MUST be in chronological order from left to right. Never place Stichtag before earlier GJ end dates just because you want to align it with a label.
7. **Spaces in Existing line**: The `═` characters must be continuous with no spaces. Use `╞═══2024═══╡` not `│   ═══2024═══╡`
8. **Inconsistent cell widths in Result**: Each cell must be exactly 12 characters (calendar year) or 20 characters (non-calendar year). Check that `│` characters align with `┼` markers above.
9. **Missing dates causing structural mismatch**: If the Result section shows N GJs, ensure the Dates line includes all N+1 boundary dates. A missing date (like 2024-03-31) will cause vertical lines to not align.
10. **Malformed connector lines**: Lines between Fonds and Result must have `│` at every date position, not arbitrary text like `(2010)`.

## Existing Line Format

When showing existing GJs with the `═` double-line character:

**Correct format:**
```
* Existing:    │           │           │           ╞═══════════2024═══════╡
```

**Wrong format (spaces before ═):**
```
* Existing:    │           │           │           │           ═══2024════╡
```

**Key rules:**
- Use `╞` (left vertical with horizontal) at the start of an existing GJ span
- Use `╡` (right vertical with horizontal) at the end of an existing GJ span
- Use `╪` (cross with double horizontal) at internal boundaries
- Fill the entire cell width with `═` characters, centering the year label
- No spaces between `│` and `═` - the `═` must start immediately

## Cell Width Consistency

**Calendar Year GJs (12-char cells):**
```
* Result:      ├───────────┼───────────┼───────────┼───────────────────────┤
*              │ lastBut2Gj│ lastBut1Gj│   lastGj  │        nextGj         │
*              │   (2021)  │   (2022)  │   (2023)  │        (2024)         │
```

Each cell between `│` markers must be exactly 11 characters (+ 1 for the `│` = 12 total):
- `│ lastBut2Gj│` = 12 chars
- `│ lastBut1Gj│` = 12 chars
- `│   lastGj  │` = 12 chars

**Wrong (inconsistent widths):**
```
*              │   (2021)  │  (2022)   │  (2023)   │        (2024)         │
```
Here `(2022)` and `(2023)` cells are 11 chars instead of 12.

## Structural Integrity

**Rule: Number of GJs must match number of boundaries**

If Result shows 4 GJs (lastBut2Gj, lastBut1Gj, lastGj, nextGj), you need 5 boundary markers:
- `├` at left edge
- `┼` between lastBut2Gj and lastBut1Gj
- `┼` between lastBut1Gj and lastGj
- `┼` between lastGj and nextGj
- `┤` at right edge

**The Dates line must include all boundary dates:**
```
* Dates:       2021-01-01  2021-12-31  2022-12-31  2023-12-31  2024-03-15  2024-12-31
```
If you show 4 GJs but only 3 GJ-end dates on the Dates line, the diagram will be structurally broken.

## Verification Scripts

### Python Script: Verify Arrow Alignment

```python
#!/usr/bin/env python3
"""Verify that all ▼ arrows align with their corresponding dates."""

import re

def verify_arrow_alignment(file_path):
    with open(file_path, 'r') as f:
        lines = f.readlines()

    errors = []
    i = 0
    while i < len(lines) - 1:
        line = lines[i]
        # Find lines with ▼ arrow
        if '▼' in line:
            arrow_pos = line.index('▼')
            # Next non-empty line should be Dates line
            j = i + 1
            while j < len(lines) and 'Dates:' not in lines[j]:
                j += 1
            if j < len(lines):
                dates_line = lines[j]
                # Find the date at arrow position
                if arrow_pos < len(dates_line):
                    char_at_pos = dates_line[arrow_pos:arrow_pos+10]
                    # Check if it's a date (YYYY-MM-DD)
                    if not re.match(r'\d{4}-\d{2}-\d{2}', char_at_pos):
                        errors.append(f"Line {i+1}: Arrow at pos {arrow_pos} doesn't align with date. Found: '{char_at_pos[:10]}'")
        i += 1

    return errors

# Usage:
# errors = verify_arrow_alignment('GeschaeftsjahreCalculatorTest.java')
# for e in errors: print(e)
```

### Python Script: Verify Cell Widths

```python
#!/usr/bin/env python3
"""Verify that Result section cells have consistent widths."""

def verify_cell_widths(line, expected_width=12):
    """Check if │ characters are spaced consistently."""
    positions = [i for i, c in enumerate(line) if c == '│']
    errors = []
    for i in range(1, len(positions)):
        width = positions[i] - positions[i-1]
        if width != expected_width and width != expected_width * 2:  # Allow double-width for last cell
            errors.append(f"Cell {i}: width {width}, expected {expected_width}")
    return errors
```

### Grep Commands for Finding Issues

```bash
# Find Existing lines with potential spacing issues
grep -n "Existing:.*│.*  ═" GeschaeftsjahreCalculatorTest.java

# Find Result lines to check cell widths
grep -n "│.*Gj.*│" GeschaeftsjahreCalculatorTest.java

# Find all arrow lines
grep -n "▼" GeschaeftsjahreCalculatorTest.java
```