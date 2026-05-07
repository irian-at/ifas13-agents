---
name: code-review-ifas
description: Reviews local git diff using 4 parallel agents with confidence-based scoring (80+ threshold). Checks CLAUDE.md compliance, bugs, and git history context. Filters false positives automatically. Invoked with /code-review-ifas.
---

# Code Review Skill

Automated local diff review using multiple specialized agents with confidence-based scoring to filter false positives.

**Scope**: Local uncommitted changes (NOT pull requests)

## How It Works

```
┌─────────────────────────────────────────┐
│   Code Review Orchestrator              │
└────────────┬────────────────────────────┘
             │
    ┌────────┼────────┬──────────┐
    │        │        │          │
    ▼        ▼        ▼          ▼
┌────────┐┌────────┐┌────────┐┌────────┐
│Agent 1 ││Agent 2 ││Agent 3 ││Agent 4 │
│CLAUDE  ││CLAUDE  ││Bug     ││History │
│.md     ││.md     ││Detector││Analyzer│
│(sonnet)││(sonnet)││(opus)  ││(sonnet)│
└────────┘└────────┘└────────┘└────────┘
    │        │        │          │
    └────────┼────────┼──────────┘
             │
    ┌────────▼────────┐
    │ Validation      │
    │ Subagents       │
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │ Filter (<80)    │
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │ Output Review   │
    └─────────────────┘
```

## Workflow

### Step 0: Validation Check

Launch a **haiku** agent to verify review is needed. **Skip review** if ANY of these are true:
- No uncommitted changes (`git status` is clean)
- Only trivial changes (whitespace, formatting, comments only)
- Only non-code files changed (config files, test resources like .csv/.json, IDE settings)

**Still review** even if changes appear Claude-generated.

### Step 1: Gather Context

```bash
# Get CLAUDE.md files
cat CLAUDE.md .claude/CLAUDE.md 2>/dev/null

# Get changed files
git status --porcelain

# Get full diff
git diff HEAD

# Get staged changes (if --staged flag)
git diff --cached
```

### Step 2: Summarize Changes

Launch a **haiku** agent to return a brief summary of what's being changed (2-3 sentences).

### Step 3: Launch 4 Parallel Agents

Use `Task` tool with `run_in_background: true` for parallel execution.

**Agent 1 & 2: CLAUDE.md Compliance** (use **sonnet** model)

Redundant agents for guideline checks. Prompt for both:
```
Audit the git diff for CLAUDE.md compliance.

CRITICAL: Only flag HIGH SIGNAL issues:
✅ Clear, unambiguous CLAUDE.md violations with exact rule quotes
❌ Subjective concerns or suggestions
❌ Style preferences not explicitly in CLAUDE.md
❌ Potential "might be" issues
❌ Anything requiring interpretation or judgment calls

For each potential issue:
1. Verify the guideline EXPLICITLY mentions the concern
2. Quote the EXACT rule from CLAUDE.md being violated
3. Only report if guideline is clear and explicit
4. Do NOT report general best practices unless in CLAUDE.md

For each issue found, provide:
- File path and line number
- Description of violation
- Exact quote from CLAUDE.md
- Confidence score (0-100)
```

**Agent 3: Bug Detector** (use **opus** model for complex logic analysis)

```
Scan for obvious bugs in the changed code.

CRITICAL: Only flag HIGH SIGNAL issues:
✅ Objective bugs causing incorrect runtime behavior
❌ Subjective concerns or suggestions
❌ Potential "might be" issues
❌ False positives

Focus on:
- Null pointer risks
- Resource leaks (unclosed streams, connections)
- Off-by-one errors
- Logic errors (incorrect conditionals, wrong operators)
- Security vulnerabilities (injection, hardcoded secrets)
- Exception handling issues

IMPORTANT:
- Focus ONLY on code being changed, not pre-existing issues
- Verify the bug is real, not just suspicious-looking code
- Consider context and how the code is actually used
- Don't flag issues that require context outside the git diff

For each issue found, provide:
- File path and line number
- Description of bug
- Why it's a real bug (not false positive)
- Confidence score (0-100)
```

**Agent 4: History Analyzer** (use **sonnet** model)

```
Use git blame and git log to analyze context.

Check for:
- Is this change consistent with file's established patterns?
- Are there related changes that should be included?
- Does this break conventions established in the codebase?
- Are similar patterns elsewhere that should also change?

For each issue found, provide:
- File path and line number
- Description of concern
- Historical context from git blame/log
- Confidence score (0-100)
```

### Step 4: Validation Subagents

**For each issue found in Step 3**, launch a validation subagent:

- Use **opus** for bug/logic issues
- Use **sonnet** for CLAUDE.md violations

Validation prompt:
```
Validate this potential issue found during code review.

Issue: [issue description]
File: [file path]
Line: [line number]
Original confidence: [score]

Context:
[relevant code snippet]

Determine if this is a TRUE issue or FALSE POSITIVE.
Consider:
- Is this actually a problem in context?
- Could this be intentional?
- Is there information that invalidates this concern?

Return:
- VALIDATED or REJECTED
- Reason for decision
- Adjusted confidence score (0-100)
```

### Step 5: Filter Issues

**Default threshold: 80**

1. Remove all issues REJECTED by validation subagents
2. Remove all issues with confidence < 80
3. Issues confirmed by multiple agents get +10 confidence bonus

### Step 6: Output Review

## Output Format

**If NO issues found:**
```markdown
## Code Review

No issues found. Checked for bugs and CLAUDE.md compliance.

**Summary**: [brief description of changes reviewed]
```

**If issues found:**
```markdown
## Code Review

**Summary**: [brief description of changes reviewed]

Found [N] issues:

### Issue 1: [Brief title] (confidence: 85)

**CLAUDE.md violation**: "[exact quote from guideline]"

`path/to/file.java:67`
```java
// problematic code snippet
```

**Suggested fix** (≤5 lines):
```suggestion
// corrected code here
```

### Issue 2: [Bug title] (confidence: 92)

`path/to/file.java:88-95`
```java
// buggy code snippet
```

**How to fix**: [High-level explanation for larger fixes]
```
Fix path/to/file.java:88: [brief description of issue and suggested fix]
```

---

**Filtered**: [N] issues below 80 confidence (likely false positives)
```

## False Positives to Filter

**DO NOT report:**
- Pre-existing issues not introduced in this change
- Code that looks like a bug but isn't (verify usage!)
- Pedantic nitpicks that senior engineers wouldn't flag
- Issues linters/formatters will catch
- General code quality concerns (unless EXPLICITLY in CLAUDE.md)
- Issues mentioned in CLAUDE.md but explicitly silenced in code (lint ignore comments)
- Stylistic preferences not in CLAUDE.md

## Usage

```bash
# Review all uncommitted changes
/code-review-ifas

# Review specific file
/code-review-ifas path/to/file.java

# Review staged changes only
/code-review-ifas --staged

# Adjust confidence threshold
/code-review-ifas --threshold 70
```

## Model Selection Guide

| Agent Type | Model | Reason |
|------------|-------|--------|
| Validation check | haiku | Fast, simple decision |
| Change summary | haiku | Quick summarization |
| CLAUDE.md compliance | sonnet | Rule matching, text analysis |
| Bug detection | opus | Complex logic analysis |
| History analysis | sonnet | Pattern matching |
| Bug validation | opus | Deep reasoning |
| CLAUDE.md validation | sonnet | Rule verification |

## IFAS13-Specific Checks

Agents should verify these CLAUDE.md rules (see [IFAS13_CONVENTIONS.md](./IFAS13_CONVENTIONS.md)):
- `@NullMarked` on all classes
- Temporal utilities (`Instants.now()`, not `Instant.now()`)
- No `System.out`/`System.err`
- AssertJ assertions (not JUnit)
- Given-when-then test naming
- `@Inject` not `@Autowired`