---
name: refactor
description: Analyze Java code and suggest refactoring improvements for naming, structure, patterns, and code quality
argument-hint: "[file-path or class-name]"
allowed-tools: Read, Grep, Glob, mcp__jetbrains__get_file_text_by_path, mcp__jetbrains__get_file_problems, mcp__jetbrains__search_in_files_by_text, mcp__jetbrains__rename_refactoring
---

# Refactor Skill

Analyze the specified code and suggest refactoring improvements.

## Target

- If `$ARGUMENTS` is provided: analyze the specified file path or find the class by name
- If no arguments: analyze the currently open file in the editor (use `mcp__jetbrains__get_all_open_file_paths`)

## Analysis Checklist

Evaluate the code against these refactoring categories:

### 1. Naming Improvements
- Class names: Should clearly describe purpose (nouns for entities, verbs for actions)
- Method names: Should describe what they do, use camelCase
- Variable names: Should be descriptive, avoid single letters except for loops
- Constants: Should be SCREAMING_SNAKE_CASE
- Boolean variables/methods: Should read naturally (e.g., `isValid`, `hasPermission`)

### 2. Method-Level Refactoring
- **Extract Method**: Long methods (>20 lines) or repeated code blocks
- **Inline Method**: Methods that just delegate to another method
- **Replace Temp with Query**: Temporary variables that could be method calls
- **Decompose Conditional**: Complex if/else chains
- **Consolidate Conditional**: Multiple conditionals with same result

### 3. Class-Level Refactoring
- **Extract Class**: Classes with too many responsibilities (>5 main concerns)
- **Move Method/Field**: Methods/fields used more by another class
- **Extract Interface**: When multiple implementations are possible
- **Replace Inheritance with Delegation**: When inheritance doesn't fit "is-a"

### 4. Code Smells to Address
- Long Parameter Lists (>3-4 parameters): Consider parameter object
- Data Clumps: Groups of data that appear together repeatedly
- Feature Envy: Method uses data from another class extensively
- Duplicate Code: Similar code in multiple places
- Dead Code: Unused variables, methods, or imports
- Magic Numbers/Strings: Hard-coded values without explanation

### 5. Java-Specific Patterns
- Use `Optional` instead of null returns
- Prefer streams for collection transformations
- do NOT Use `var` for obvious local variable types (Java 10+)
- Use records for immutable data carriers (Java 16+)
- Use sealed classes for restricted hierarchies (Java 17+)
- Use pattern matching for instanceof (Java 16+)

### 6. Project-Specific Conventions (IFAS13)
- Use Lombok annotations (`@Getter`, `@Setter`, `@UtilityClass`)
- Use `Instants.now()` instead of `Instant.now()`
- Use `LocalDates.now()` instead of `LocalDate.now()`
- Test methods should follow `given_when_then` naming
- Use AssertJ for test assertions

## Output Format

Present findings as:

```
## Refactoring Suggestions for [filename]

### High Priority
1. **[Refactoring Type]**: [Description]
   - Current: `[code snippet]`
   - Suggested: `[improved code snippet]`
   - Reason: [why this improves the code]

### Medium Priority
...

### Low Priority (Nice to Have)
...

## Summary
- Total suggestions: X
- Estimated impact: [brief assessment]
```

## Important Notes

- Do NOT make changes automatically - only suggest and explain
- Focus on substantive improvements, not style nitpicks
- Consider the broader context before suggesting extractions
- Respect existing project patterns and conventions
- Use IntelliJ refactoring tools when implementing changes (never bash commands)
