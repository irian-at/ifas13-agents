#!/usr/bin/env python3
"""Plan, and optionally run, the ifas13 tests affected by the current changes.

Without --run it only prints the plan (changed modules, selected tests, databases, Maven command);
that takes about a second and starts no Maven. With --run it executes the command, writes the full
log to a file and prints a summary of the surefire reports.

Selection:
- changed modules = modules owning a changed file under src/ or their pom.xml; a changed aggregator
  or root pom.xml affects every module below it
- affected modules = changed modules plus everything depending on them (all dependency scopes)
- every test class of an affected module runs, except in the slow integration-test modules
  (NARROWED_MODULES): there only tests that reach a changed class through a chain of references
  (import, wildcard import or same package, plus the simple name in the source) are selected;
  changes without such a trail (BROAD_PATHS, SPRING_WIRING, pom.xml) select all of them
- Postgres and Sybase run only when a change is database-relevant (DB_PATHS, DB_TOKENS)
- the libreoffice-container tests run only when a change touches recalc or workbook code
"""
import argparse
import os
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

GROUP_IDS = {"at.oekb.ifas13", "${project.groupId}", "${groupId}"}

NARROWED_MODULES = {
    "ifas-testing/ifas-integration-tests",
    "ifas-testing/ifas-integration-tests-multidbctx",
}
# above this share of a narrowed module's tests the selection is pointless: run the whole module
NARROW_MAX_SHARE = 0.7

# changes here reach (nearly) every integration test without an import trail
BROAD_PATHS = [
    r"^support-libs/core-test-support/",
    r"^support-libs/multidbctx-support/",
    r"^ifas-database/ifas-database-config/",
    r"^ifas-database/ifas-database-flyway/",
    r"^ifas-testing/ifas-integration-tests[^/]*/src/test/java/at/oekb/ifas/integrationtest/",
    r"^ifas-testing/ifas-integration-tests[^/]*/src/test/resources/[^/]+$",
    r"/src/main/resources/(META-INF/|application[^/]*$)",
    r"/(\w*Config\w*|\w*Configuration\w*|DatabaseContext\w*|package-info)\.java$",
]
# Spring wires these by type, annotation or proxy, so no reference trail leads to their users
SPRING_WIRING = re.compile(
    r"@(Configuration|AutoConfiguration|Aspect|ControllerAdvice|RestControllerAdvice|EnableJpaRepositories"
    r"|EnableTransactionManagement|ConditionalOn\w+)\b|implements\s+[\w<>, ]*\b(BeanPostProcessor"
    r"|BeanFactoryPostProcessor|ApplicationContextInitializer|HandlerInterceptor|Filter)\b"
)

DB_PATHS = [
    r"^ifas-database/",
    r"^support-libs/multidbctx-support/",
    r"^support-libs/sybase-testcontainer/",
    r"^support-libs/core-test-support/src/main/java/at/oekb/ifas/testsupport/db/",
    r"^ifas-testing/ifas-integration-tests[^/]*/src/test/java/at/oekb/ifas/integrationtest/config/",
    r"\.sql$",
    r"/db/migration/",
    r"(Repository|Entity|Dao)\w*\.java$",
    r"/DatabaseContext\w*\.java$",
]
DB_TOKENS = re.compile(
    r"@(Query|Modifying|Entity|Embeddable|Table|Column|JoinColumn|Id|Convert|Lob|Version|Lock|Formula"
    r"|OneToMany|ManyToOne|ManyToMany|OneToOne|ElementCollection|SqlResultSetMapping|Procedure)\b"
    r"|nativeQuery|createNativeQuery|createQuery|JdbcTemplate|EntityManager|CriteriaBuilder"
    r"|LockModeType|PreparedStatement|ResultSet\b|isolation\s*="
)
DB_POM_TOKENS = re.compile(
    r"postgresql|jtds|jconn|sybase|h2database|hibernate|flyway|spring-data|data-jpa|testcontainers|hikari"
)
LIBREOFFICE_PATHS = re.compile(r"recalc|workbook|libreoffice|xls-support", re.IGNORECASE)

TEST_FILE = re.compile(r"^(Test\w*|\w+Test|\w+Tests|\w+TestCase)\.java$")
PACKAGE = re.compile(r"^\s*package\s+([\w.]+)\s*;", re.MULTILINE)
IMPORT = re.compile(r"^\s*import\s+(static\s+)?([\w.]+?)(\.\*)?\s*;", re.MULTILINE)
CAPITALISED = re.compile(r"\b[A-Z][A-Za-z0-9_]*\b")


@dataclass
class Module:
    path: str
    artifact: str
    packaging: str
    deps: set
    children: list


@dataclass
class JavaClass:
    fqn: str
    simple: str
    package: str
    module: str
    path: str
    is_test: bool
    has_nested: bool
    explicit_imports: set = field(default_factory=set)
    wildcard_imports: set = field(default_factory=set)
    idents: set = field(default_factory=set)
    text: str = ""

    def references(self, other):
        if other.simple not in self.idents:
            return False
        return (other.fqn in self.explicit_imports
                or other.package in self.wildcard_imports
                or other.package == self.package)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                          text=True).stdout


def find_root():
    return Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True,
                               capture_output=True, text=True).stdout.strip())


# ---------------------------------------------------------------- reactor

def load_reactor(root):
    modules = {}

    def visit(rel):
        tree = ET.parse(root / rel / "pom.xml").getroot()
        ns = tree.tag[: tree.tag.index("}") + 1] if tree.tag.startswith("{") else ""

        def text(el, name):
            child = el.find(ns + name)
            return child.text.strip() if child is not None and child.text else None

        deps = set()
        dep_lists = [tree.find(ns + "dependencies")]
        dep_lists += [p.find(ns + "dependencies") for p in tree.findall(f"{ns}profiles/{ns}profile")]
        for dep_list in filter(lambda d: d is not None, dep_lists):
            for dep in dep_list.findall(ns + "dependency"):
                if text(dep, "groupId") in GROUP_IDS:
                    deps.add(text(dep, "artifactId"))
        children = [os.path.normpath(os.path.join(rel, m.text.strip()))
                    for m in tree.findall(f"{ns}modules/{ns}module")]
        modules[rel] = Module(rel, text(tree, "artifactId"), text(tree, "packaging") or "jar", deps,
                              children)
        for child in children:
            visit(child)

    visit(".")
    return modules


def leaf_modules(modules):
    return {p: m for p, m in modules.items() if m.packaging != "pom"}


def descendants(modules, path):
    result, todo = set(), [path]
    while todo:
        module = modules[todo.pop()]
        for child in module.children:
            result.add(child)
            todo.append(child)
    return {p for p in result if modules[p].packaging != "pom"}


def owning_module(modules, file):
    best = "."
    for path in modules:
        if path != "." and (file == path or file.startswith(path + "/")) and len(path) > len(best):
            best = path
    return best


def downstream(leaves, changed):
    by_artifact = {m.artifact: p for p, m in leaves.items()}
    dependents = {p: set() for p in leaves}
    for path, module in leaves.items():
        for dep in module.deps:
            if dep in by_artifact:
                dependents[by_artifact[dep]].add(path)
    result, todo = set(changed), list(changed)
    while todo:
        for dependent in dependents.get(todo.pop(), ()):
            if dependent not in result:
                result.add(dependent)
                todo.append(dependent)
    return result


# ---------------------------------------------------------------- changes

def changed_files(root, base):
    ref = git(root, "merge-base", base, "HEAD").strip() if base else "HEAD"
    tracked = git(root, "diff", "--name-only", ref).split()
    untracked = git(root, "ls-files", "--others", "--exclude-standard").split()
    diff = git(root, "diff", "-U0", ref)
    changed_lines = {}
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
            changed_lines.setdefault(current, [])
        elif line.startswith("--- a/") and current is None:
            continue
        elif current and line[:1] in ("+", "-") and not line.startswith(("+++", "---")):
            changed_lines[current].append(line[1:])
        elif line.startswith("diff --git"):
            current = None
    for file in untracked:
        try:
            changed_lines[file] = (root / file).read_text(encoding="utf-8", errors="replace").splitlines()
        except (IsADirectoryError, FileNotFoundError):
            pass
    return sorted(set(tracked) | set(untracked)), changed_lines, ref


def classify(modules, files):
    """Returns (changed leaf modules, files that count, everything_changed)."""
    leaves = leaf_modules(modules)
    changed, relevant, everything = set(), [], False
    for file in files:
        if file == "pom.xml" or file.startswith(".mvn/"):
            everything = True
            relevant.append(file)
            continue
        owner = owning_module(modules, file)
        if owner == ".":
            continue
        inside = file[len(owner) + 1:]
        if modules[owner].packaging == "pom":
            if inside == "pom.xml":
                changed |= descendants(modules, owner)
                relevant.append(file)
            continue
        if inside == "pom.xml" or inside.startswith("src/"):
            changed.add(owner)
            relevant.append(file)
    if everything:
        changed = set(leaves)
    return changed, relevant, everything


def db_reasons(files, changed_lines):
    reasons = []
    for file in files:
        if any(re.search(p, file) for p in DB_PATHS):
            reasons.append(f"{file} (database path)")
            continue
        lines = "\n".join(changed_lines.get(file, []))
        if file.endswith("pom.xml") and DB_POM_TOKENS.search(lines):
            reasons.append(f"{file} (database dependency)")
        elif file.endswith(".java"):
            match = DB_TOKENS.search(lines)
            if match:
                reasons.append(f"{file} ({match.group(0).strip()} in the diff)")
    return reasons


# ---------------------------------------------------------------- java index

def index_classes(root, leaves):
    classes = []
    for module in leaves:
        for kind in ("main", "test"):
            src = root / module / "src" / kind / "java"
            if not src.is_dir():
                continue
            for file in src.rglob("*.java"):
                text = file.read_text(encoding="utf-8", errors="replace")
                package_match = PACKAGE.search(text)
                package = package_match.group(1) if package_match else ""
                explicit, wildcard = set(), set()
                for static, name, star in IMPORT.findall(text):
                    if static:
                        explicit.add(name if star else name.rsplit(".", 1)[0])
                    elif star:
                        wildcard.add(name)
                    else:
                        explicit.add(name)
                simple = file.stem
                is_test = (kind == "test" and TEST_FILE.match(file.name) is not None
                           and not re.search(r"\babstract\s+class\s+" + simple + r"\b", text))
                classes.append(JavaClass(
                    fqn=f"{package}.{simple}" if package else simple, simple=simple, package=package,
                    module=module, path=str(file.relative_to(root)), is_test=is_test,
                    has_nested="@Nested" in text, explicit_imports=explicit, wildcard_imports=wildcard,
                    idents=set(CAPITALISED.findall(text)), text=text))
    return classes


def impacted_classes(classes, files, hops):
    """Classes reaching a changed file by references (all hops when `hops` is None); None means "cannot tell"."""
    by_path = {c.path: c for c in classes}
    by_simple = {}
    for c in classes:
        for ident in c.idents:
            by_simple.setdefault(ident, []).append(c)
    impacted = set()
    for file in files:
        if file in by_path:
            impacted.add(by_path[file].fqn)
        elif file.endswith("pom.xml"):
            return None
        elif "/src/" in file and not file.endswith(".java"):
            name = Path(file).name
            users = {c.fqn for c in classes if name in c.text}
            if not users:
                return None
            impacted |= users
    by_fqn = {c.fqn: c for c in classes}
    frontier = set(impacted)
    hop = 0
    while frontier and (hops is None or hop < hops):
        hop += 1
        reached = set()
        for fqn in frontier:
            target = by_fqn[fqn]
            for candidate in by_simple.get(target.simple, ()):
                if candidate.fqn not in impacted and candidate.references(target):
                    reached.add(candidate.fqn)
        impacted |= reached
        frontier = reached
    return impacted


# ---------------------------------------------------------------- plan

@dataclass
class Plan:
    changed: set
    affected: set
    tests: dict          # module -> list of test classes to run
    totals: dict         # module -> number of test classes in the module
    notes: dict          # module -> why it was narrowed or not
    db_reasons: list
    run_dbs: bool
    run_libreoffice: bool
    full_reactor: bool


def make_plan(root, args):
    modules = load_reactor(root)
    leaves = leaf_modules(modules)
    classes = index_classes(root, leaves)
    tests_by_module = {}
    for c in classes:
        if c.is_test:
            tests_by_module.setdefault(c.module, []).append(c)

    files, changed_lines, _ = changed_files(root, args.base)
    changed, relevant, everything = classify(modules, files)
    reasons = db_reasons(relevant, changed_lines)

    tests, notes = {}, {}
    if args.test:
        for pattern in args.test:
            class_part = pattern.split("#", 1)[0]
            matches = [c for c in classes if c.is_test and (c.fqn == class_part or c.simple == class_part)]
            if not matches:
                sys.exit(f"no test class matches {class_part!r}")
            for c in matches:
                method = pattern[len(class_part):]
                tests.setdefault(c.module, []).append((c, method))
        affected = set(tests)
        for module in affected:
            notes[module] = "requested with --test"
    elif args.module:
        affected = {os.path.normpath(m) for m in args.module}
        unknown = affected - set(leaves)
        if unknown:
            sys.exit(f"not a reactor module: {', '.join(sorted(unknown))}")
        for module in affected:
            tests[module] = [(c, "") for c in tests_by_module.get(module, [])]
            notes[module] = "requested with --module"
    else:
        affected = downstream(leaves, changed)
        broad = everything or any(re.search(p, f) for f in relevant for p in BROAD_PATHS)
        by_path = {c.path: c for c in classes}
        broad = broad or any(f in by_path and SPRING_WIRING.search(by_path[f].text) for f in relevant)
        impacted = None if broad or args.no_narrow else impacted_classes(classes, relevant, args.hops)
        reach = "a change" if args.hops is None else f"a change within {args.hops} references"
        for module in sorted(affected):
            module_tests = tests_by_module.get(module, [])
            if not module_tests:
                continue
            if module not in NARROWED_MODULES or args.no_narrow:
                tests[module] = [(c, "") for c in module_tests]
                notes[module] = "all"
                continue
            if impacted is None:
                tests[module] = [(c, "") for c in module_tests]
                notes[module] = ("all (a change has no reference trail: pom, Spring wiring, shared test "
                                 "infrastructure or an unreferenced resource)")
                continue
            selected = [c for c in module_tests if c.fqn in impacted]
            if len(selected) > NARROW_MAX_SHARE * len(module_tests):
                tests[module] = [(c, "") for c in module_tests]
                notes[module] = f"all ({len(selected)} reached, more than {NARROW_MAX_SHARE:.0%})"
            elif selected:
                tests[module] = [(c, "") for c in selected]
                notes[module] = f"narrowed to the tests that reach {reach}"
            else:
                notes[module] = f"none of its tests reaches {reach}"

    run_dbs = bool(reasons) if args.dbs == "auto" else args.dbs == "all"
    run_libreoffice = (args.libreoffice == "with" or args.libreoffice == "auto"
                       and any(LIBREOFFICE_PATHS.search(f) for f in relevant))
    totals = {m: len(tests_by_module.get(m, [])) for m in affected}
    # a root pom or .mvn change reaches every module: the plain reactor run is simpler than a test list
    full = args.all or (everything and not (args.test or args.module))
    return Plan(changed, affected, tests, totals, notes, reasons, run_dbs, run_libreoffice, full)


def maven_command(plan, args):
    arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "amd64"
    profiles = ["no-proxy", "dev-build", f"platform-{arch}"]
    if not plan.run_dbs:
        profiles += ["skip-postgres15-tests", "skip-sybase16-tests"]
    cmd = ["mvn", "-B", "-Dstyle.color=never", "-T", args.threads, "-P" + ",".join(profiles)]
    if not plan.full_reactor:
        patterns = []
        for module in sorted(plan.tests):
            for c, method in plan.tests[module]:
                patterns.append(c.fqn + method)
                if c.has_nested and not method:
                    patterns.append(c.fqn + "$*")
        cmd += ["-pl", ",".join(sorted(plan.tests)), "-am"]
        cmd += ["-Dtest=" + ",".join(patterns), "-Dsurefire.failIfNoSpecifiedTests=false"]
    cmd.append("test")
    if not args.coverage:
        cmd.append("-DargLine=")
    if not plan.run_libreoffice:
        cmd.append("-DexcludedGroups=libreoffice-container")
    return cmd


def print_plan(root, plan, cmd, args):
    print(f"repo: {root}")
    if plan.changed:
        print(f"changed modules ({len(plan.changed)}):")
        for module in sorted(plan.changed):
            print(f"  {module}")
    elif not (args.test or args.module or args.all):
        print("no module changes (only files outside src/ and pom.xml) - nothing to test")
        return False
    if plan.full_reactor:
        print("tests: every module" + (" (--all)" if args.all else " (root pom.xml or .mvn/ changed)"))
    else:
        if not plan.tests:
            print("tests: none selected")
            return False
        count = sum(len(t) for t in plan.tests.values())
        print(f"tests ({count} classes in {len(plan.tests)} modules):")
        for module in sorted(plan.affected):
            selected = len(plan.tests.get(module, []))
            if not plan.totals.get(module):
                continue
            print(f"  {module}: {selected}/{plan.totals[module]} - {plan.notes.get(module, '')}")
            if args.verbose or (module in NARROWED_MODULES and 0 < selected < plan.totals[module]):
                for c, method in plan.tests.get(module, []):
                    print(f"      {c.fqn}{method}")
    if plan.run_dbs:
        print("databases: H2 + Postgres + Sybase" + (" (forced)" if args.dbs == "all" else ""))
        for reason in plan.db_reasons[:10]:
            print(f"  - {reason}")
        if len(plan.db_reasons) > 10:
            print(f"  - ... {len(plan.db_reasons) - 10} more")
    else:
        print("databases: H2 only" + (" (forced)" if args.dbs == "h2" else " (no database-relevant change)"))
    print("libreoffice-container tests: " + ("included" if plan.run_libreoffice else "excluded"))
    for warning in environment_warnings(root, plan):
        print(f"WARNING: {warning}")
    shown = [a if not a.startswith("-Dtest=") or len(a) < 300
             else f"-Dtest=<{a.count(',') + 1} patterns, use --print-command>" for a in cmd]
    print("command:\n  " + shlex.join(shown))
    return True


def environment_warnings(root, plan):
    warnings = []
    if plan.run_dbs and not (root / ".env").is_file():
        warnings.append(".env missing at the repo root - the Sybase Testcontainer has no credentials")
    if plan.run_dbs or plan.run_libreoffice:
        props = Path.home() / ".testcontainers.properties"
        host = os.environ.get("DOCKER_HOST", "")
        if not host and props.is_file():
            match = re.search(r"docker\.host\s*=\s*(\S+)", props.read_text())
            host = match.group(1) if match else ""
        if host.startswith("unix://") and not Path(host[7:]).exists():
            warnings.append(f"container socket {host[7:]} does not exist - start podman")
    return warnings


# ---------------------------------------------------------------- run

def other_maven_in(root):
    if not Path("/proc").is_dir():
        return []
    busy = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
        except OSError:
            continue
        if b"plexus.classworlds.launcher.Launcher" in cmdline and (cwd == str(root) or cwd.startswith(f"{root}/")):
            busy.append(pid)
    return busy


def run(root, plan, cmd, args):
    busy = other_maven_in(root)
    if busy and not args.force:
        sys.exit(f"another Maven build is running in {root} (pids {', '.join(busy)}); "
                 "two builds in one checkout overwrite each other's target/ - rerun with --force to ignore")
    log = Path(args.log) if args.log else Path(tempfile.gettempdir()) / f"ifas-run-tests-{int(time.time())}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f"log: {log}", flush=True)
    start = time.time()
    with log.open("w") as out:
        rc = subprocess.run(cmd, cwd=root, stdout=out, stderr=subprocess.STDOUT).returncode
    print(f"maven exit code {rc} after {time.time() - start:.0f} s")
    summarize(root, plan, log, start)
    return rc


def summarize(root, plan, log, start):
    if plan.full_reactor:
        candidates = root.glob("**/target/surefire-reports/TEST-*.xml")
    else:
        candidates = [r for m in sorted(plan.tests) for r in (root / m / "target" / "surefire-reports").glob("TEST-*.xml")]
    reports = [r for r in candidates if r.stat().st_mtime >= start - 1]
    totals = dict(tests=0, failures=0, errors=0, skipped=0)
    problems = []
    for report in reports:
        try:
            suite = ET.parse(report).getroot()
        except ET.ParseError:
            problems.append(f"UNREADABLE {report.relative_to(root)}")
            continue
        for key in totals:
            totals[key] += int(float(suite.get(key, "0").replace(",", "")))
        for case in suite.iter("testcase"):
            for kind in ("failure", "error"):
                el = case.find(kind)
                if el is not None:
                    message = (el.get("message") or el.text or "").strip().splitlines()
                    first = message[0][:200] if message else ""
                    problems.append(f"{kind.upper()} {case.get('classname')}#{case.get('name')}: {first}")
    print(f"surefire: {len(reports)} suites, {totals['tests']} tests, {totals['failures']} failures, "
          f"{totals['errors']} errors, {totals['skipped']} skipped")
    for problem in problems[:40]:
        print(f"  {problem}")
    if len(problems) > 40:
        print(f"  ... {len(problems) - 40} more, see the log")
    text = log.read_text(errors="replace")
    if "BUILD FAILURE" in text and not problems:
        errors = [line for line in text.splitlines() if line.startswith("[ERROR]")]
        print("build failed before or outside the tests:")
        for line in errors[:30]:
            print(f"  {line[:240]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--test", action="append", metavar="CLASS[#method]",
                       help="run only this test class (simple name or FQN); repeatable")
    scope.add_argument("--module", action="append", metavar="PATH", help="run all tests of this module; repeatable")
    scope.add_argument("--all", action="store_true", help="run every test of the reactor")
    parser.add_argument("--base", metavar="REF",
                        help="also count commits since the merge-base with REF (default: working tree vs HEAD)")
    parser.add_argument("--dbs", choices=("auto", "all", "h2"), default="auto")
    parser.add_argument("--libreoffice", choices=("auto", "with", "without"), default="auto")
    parser.add_argument("--no-narrow", action="store_true", help="run every test of the integration-test modules")
    parser.add_argument("--hops", type=int, default=None,
                        help="limit the reference chain from a change to a test (default: unlimited)")
    parser.add_argument("--threads", default="1C", help="maven -T value (default 1C)")
    parser.add_argument("--coverage", action="store_true", help="keep the JaCoCo agent (slower)")
    parser.add_argument("--run", action="store_true", help="execute the command and summarise the reports")
    parser.add_argument("--log", help="log file for --run (default: a new file in the temp dir)")
    parser.add_argument("--force", action="store_true", help="run even if another Maven build uses the checkout")
    parser.add_argument("--print-command", action="store_true", help="print only the full maven command")
    parser.add_argument("--verbose", action="store_true", help="list every selected test class")
    args = parser.parse_args()

    root = find_root()
    plan = make_plan(root, args)
    cmd = maven_command(plan, args)
    if args.print_command:
        if not (plan.full_reactor or plan.tests):
            print("no tests selected", file=sys.stderr)
            return 1
        print(shlex.join(cmd))
        return 0
    if not print_plan(root, plan, cmd, args):
        return 0
    if args.run:
        return run(root, plan, cmd, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
