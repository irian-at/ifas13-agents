# Java Variable Declarations

**Never use `var` for Java variable declarations. Always use explicit, concrete types.**

```java
// WRONG
var job = submitStmRecalcJobFromSingleResource(setting, createdBy, r);
var list = new ArrayList<String>();
var stream = resources.stream();

// CORRECT
StmRecalcJob job = submitStmRecalcJobFromSingleResource(setting, createdBy, r);
ArrayList<String> list = new ArrayList<>();
Stream<NamedContentTypeResource> stream = resources.stream();
```