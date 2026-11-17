"""Checks for the scoped CI legs: the selector, the workflow shape, the gate decision and the
nightly skip decision.

Run from the repository root:

    python3 -m unittest discover -s .github/checks/tests -v

Python 3 standard library only. Nothing here touches the network: the runs API is a stand-in HTTP
server bound to 127.0.0.1, and every git repository is built in a temp dir that is removed on
every exit.

INTERFACE UNDER TEST (the implementation must match this; every command is run as
`bash .github/checks/ci-legs.sh ...`, a thin wrapper over .github/checks/ci-legs.py that finds the
python file next to itself, so it can be run from any working directory):

Legs, in this order: checks, go-checks, go-test-macos, swift-test, mac-app-build.
A leg's flag name is its id with '-' replaced by '_' (go-checks -> go_checks).

1. Selector:  ci-legs.sh --legs-for <base>
   Run with the working directory inside the git repository to judge. It compares <base> with HEAD
   (committed changes, `<base>...HEAD`, the merge base on the base side) with rename detection, and
   counts both sides of a rename and the path of a deletion.
   stdout, one line each:
     leg <id>             for every planned leg
     skip <id>: <reason>  for every leg left out, with a non-empty reason
     all-legs: <reason>   exactly once, and only when the change cannot be told (empty base,
                          a base that is not a commit, no single merge base, a failed diff);
                          every leg is then planned and no skip line is printed
   Exit status 0 in every case above.

2. Gate decision:  ci-legs.sh gate --event <github.event_name>   (the `needs` context as JSON on stdin)
   The JSON is toJSON(needs): {"<job>": {"result": "...", "outputs": {...}}, ...}. The plan job's
   outputs are `legs` (space separated ids of the planned legs, empty on a nightly skip), `skip`
   ("true" or "false"), `verdict` (the conclusion of the earlier nightly that a skip rests on),
   `run` (that nightly's run id) and one `<flag>` per leg ("true" when planned).
   Exit 0 and a line starting `ok` when green; exit 1 and a line starting `red:` naming the rule and
   the job otherwise. Green only when plan succeeded, every planned leg succeeded, every unplanned
   leg was skipped, and every planned name has a job in needs. A skip (skip == "true") is green only
   on event "schedule", with verdict "success" and a non-empty run, and every leg skipped.
   Unreadable input is red.

3. Nightly decision:  ci-legs.sh nightly --event <name> --head <sha> --run-id <id> --runs-url <url>
   The token comes from the environment variable GITHUB_TOKEN, sent as `Authorization: Bearer
   <token>`, never in argv. The tool GETs <url> with `page=N` (and `per_page`) added to its query,
   N from 1, reading pages until one has an empty `workflow_runs` list or a bounded page count is
   reached. Each page is {"workflow_runs": [{"id", "head_sha", "status", "conclusion"}, ...]}.
   It keeps runs with status "completed", conclusion "success" or "failure", and an id smaller
   than --run-id; if any has head_sha equal to --head, the verdict is the conclusion of the one with
   the smallest id (never list position).
   stdout, `key=value` per line, exit 0 always:
     skip=true|false
     legs=<ids>        every leg, space separated, when skip=false; empty when skip=true
     verdict=<success|failure>   only when skip=true
     run=<id>                    only when skip=true: the run the verdict rests on
     reason=<text>               non-empty when skip=false: why every leg runs
   skip=false (every leg runs) for: event other than "schedule", no earlier finished run, no run on
   this head, an empty or non-40-hex head, a failed read (HTTP error, refused connection, a bad token)
   on any page, and a malformed page (not JSON, or workflow_runs not a list of objects).
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".github" / "checks" / "ci-legs.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

# The repo's one hang ceiling for a check, in seconds.
HANG = 120

LEGS = ["checks", "go-checks", "go-test-macos", "swift-test", "mac-app-build"]


def flag(leg):
    return leg.replace("-", "_")


def run_script(args, cwd=None, stdin=None, env_extra=None):
    env = dict(os.environ)
    env.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})
    env.pop("GITHUB_TOKEN", None)
    env.update(env_extra or {})
    return subprocess.run(
        ["bash", str(SCRIPT)] + list(args),
        cwd=cwd,
        input=stdin,
        capture_output=True,
        text=True,
        timeout=HANG,
        env=env,
    )


# ---------------------------------------------------------------- the selector


class Repo:
    """A throwaway git repository in a temp dir."""

    def __init__(self, test):
        self.dir = Path(tempfile.mkdtemp(prefix="ci-legs-repo-"))
        test.addCleanup(shutil.rmtree, self.dir, True)
        self.env = dict(os.environ)
        self.env.update(
            {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.com",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.com",
            }
        )
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        r = subprocess.run(
            ["git", *args], cwd=self.dir, env=self.env, capture_output=True, text=True, timeout=HANG
        )
        if r.returncode != 0:
            raise AssertionError("git %s failed: %s" % (" ".join(args), r.stderr))
        return r.stdout.strip()

    def write(self, path, text=None):
        p = self.dir / path
        p.parent.mkdir(parents=True, exist_ok=True)
        # Enough content that rename detection pairs the old and new path.
        p.write_text(text if text is not None else ("content of %s\n" % path) * 20)

    def commit(self, msg="c"):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD")


def select(test, base_files=(), change=None, base=None):
    """Build base commit from base_files, apply change(repo) and commit, run the selector.

    Returns (result, repo, base_sha)."""
    repo = Repo(test)
    repo.write("seed.txt")
    for f in base_files:
        repo.write(f)
    base_sha = repo.commit("base")
    if change:
        change(repo)
    repo.commit("change")
    r = run_script(["--legs-for", base_sha if base is None else base], cwd=repo.dir)
    return r, repo, base_sha


def parse_plan(out):
    planned, skipped, all_legs = [], {}, []
    for line in out.splitlines():
        m = re.match(r"^leg (\S+)$", line)
        if m:
            planned.append(m.group(1))
            continue
        m = re.match(r"^skip (\S+): (.+)$", line)
        if m:
            skipped[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^all-legs: (.+)$", line)
        if m:
            all_legs.append(m.group(1))
    return planned, skipped, all_legs


CHECKS = {"checks"}
GO = {"checks", "go-checks", "go-test-macos", "mac-app-build"}
SWIFT = {"checks", "swift-test", "mac-app-build"}
APP = {"checks", "mac-app-build"}
EVERY = set(LEGS)

# One or more sample paths for every row of the path map.
ROWS = {
    "every leg: workflows": (EVERY, [".github/workflows/ci.yml", ".github/workflows/other.yml"]),
    "every leg: ignore and dependabot": (EVERY, [".gitignore", ".github/dependabot.yml"]),
    "every leg: shared check scripts": (
        EVERY,
        [
            ".github/checks/lib.sh",
            ".github/checks/annotate-go-output.sh",
            ".github/checks/annotate-swift-output.sh",
            ".github/checks/select-xcode.sh",
        ],
    ),
    "every leg: the selector": (EVERY, [".github/checks/ci-legs.py", ".github/checks/ci-legs.sh"]),
    "every leg: unknown paths": (
        EVERY,
        ["tools/unknown.txt", "Makefile", "macos/scripts/other.sh", ".github/checks/new-check.sh"],
    ),
    "checks only: check scripts": (
        CHECKS,
        [".github/checks/go-format.sh", ".github/checks/changelog-entry.sh"],
    ),
    "checks only: templates": (
        CHECKS,
        [".github/ISSUE_TEMPLATE/bug_report.yml", ".github/ISSUE_TEMPLATE/deep/x.yml", ".github/PULL_REQUEST_TEMPLATE.md"],
    ),
    "checks only: top-level docs": (
        CHECKS,
        ["CHANGELOG.md", "README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "LICENSE"],
    ),
    "checks only: docs tree": (CHECKS, ["docs/a.md", "docs/deep/er/b.md"]),
    "checks only: release scripts": (
        CHECKS,
        [
            "macos/scripts/release.sh",
            "macos/scripts/publish-release.sh",
            "macos/scripts/release-lib.sh",
            "macos/scripts/verify-release.sh",
            "macos/scripts/dmg/background.png",
            "macos/scripts/dmg/deep/x.txt",
        ],
    ),
    "go legs: sources": (
        GO,
        ["cmd/relay/main.go", "cmd/a/b/c.go", "internal/x/y.go", "internal/z.go", "go.mod", "go.sum"],
    ),
    "go legs: check scripts": (
        GO,
        [".github/checks/go-vet.sh", ".github/checks/go-build.sh", ".github/checks/go-test.sh"],
    ),
    "swift legs: package": (
        SWIFT,
        ["macos/Packages/CGMRelayCore/Package.swift", "macos/Packages/CGMRelayCore/Sources/A/b.swift"],
    ),
    "swift legs: check script": (SWIFT, [".github/checks/swift-test.sh"]),
    "app leg: sources": (
        APP,
        [
            "macos/App/a.swift",
            "macos/App/deep/b.swift",
            "macos/Helper/h.swift",
            "macos/project.yml",
            "macos/scripts/build.sh",
            "macos/CGMRelay.xcodeproj/project.pbxproj",
        ],
    ),
    "app leg: check script": (APP, [".github/checks/mac-app-build.sh"]),
}


class SelectorTests(unittest.TestCase):
    def assert_plan(self, r, expected):
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        planned, skipped, all_legs = parse_plan(r.stdout)
        self.assertEqual(set(planned), set(expected), r.stdout)
        self.assertEqual(len(planned), len(set(planned)), "a leg printed twice: " + r.stdout)
        self.assertEqual(set(skipped), EVERY - set(expected), r.stdout)
        for leg, why in skipped.items():
            self.assertTrue(why.strip(), "no reason for " + leg)
        self.assertEqual(all_legs, [], "a tellable change must not say all-legs: " + r.stdout)

    def assert_all_with_reason(self, r):
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        planned, skipped, all_legs = parse_plan(r.stdout)
        self.assertEqual(set(planned), EVERY, r.stdout)
        self.assertEqual(skipped, {}, r.stdout)
        self.assertEqual(len(all_legs), 1, r.stdout)
        self.assertTrue(all_legs[0].strip())

    def test_each_map_row_plans_its_legs(self):
        for row, (expected, paths) in ROWS.items():
            for path in paths:
                with self.subTest(row=row, path=path):
                    r, _, _ = select(self, change=lambda repo, p=path: repo.write(p, "new\n"))
                    self.assert_plan(r, expected)

    def test_modified_file_counts_like_an_added_one(self):
        r, _, _ = select(
            self,
            base_files=["docs/a.md", "internal/x.go"],
            change=lambda repo: repo.write("docs/a.md", "edited\n"),
        )
        self.assert_plan(r, CHECKS)

    def test_several_paths_plan_the_union(self):
        def change(repo):
            repo.write("docs/a.md", "x\n")
            repo.write("macos/App/a.swift", "x\n")
            repo.write("macos/Packages/CGMRelayCore/Sources/a.swift", "x\n")

        r, _, _ = select(self, change=change)
        self.assert_plan(r, SWIFT | APP)

    def test_one_unknown_path_among_known_plans_every_leg(self):
        def change(repo):
            repo.write("docs/a.md", "x\n")
            repo.write("somewhere/else.bin", "x\n")

        r, _, _ = select(self, change=change)
        self.assert_plan(r, EVERY)

    def test_rename_counts_both_sides(self):
        # docs -> Go source: the new side alone would plan Go legs, the old side alone checks only;
        # the plan is the union either way, so rename a Go file into docs as well.
        def into_docs(repo):
            (repo.dir / "docs").mkdir(exist_ok=True)
            repo.git("mv", "internal/x.go", "docs/x.go.md")

        r, _, _ = select(self, base_files=["internal/x.go"], change=into_docs)
        self.assert_plan(r, GO)

        def out_of_docs(repo):
            (repo.dir / "macos" / "App").mkdir(parents=True, exist_ok=True)
            repo.git("mv", "docs/x.md", "macos/App/x.swift")

        r, _, _ = select(self, base_files=["docs/x.md"], change=out_of_docs)
        self.assert_plan(r, APP)

    def test_rename_across_unknown_side_plans_every_leg(self):
        def change(repo):
            (repo.dir / "elsewhere").mkdir(exist_ok=True)
            repo.git("mv", "docs/x.md", "elsewhere/x.md")

        r, _, _ = select(self, base_files=["docs/x.md"], change=change)
        self.assert_plan(r, EVERY)

    def test_deletion_plans_by_its_own_path(self):
        def delete(path):
            def change(repo):
                repo.git("rm", "-q", path)

            return change

        for path, expected in [
            ("docs/x.md", CHECKS),
            ("internal/x.go", GO),
            ("macos/Packages/CGMRelayCore/Sources/a.swift", SWIFT),
            ("macos/App/a.swift", APP),
            (".github/workflows/ci.yml", EVERY),
            ("tools/unknown.txt", EVERY),
        ]:
            with self.subTest(path=path):
                r, _, _ = select(self, base_files=[path], change=delete(path))
                self.assert_plan(r, expected)

    def test_diff_is_taken_from_the_merge_base(self):
        # The base branch moved on in Go code after this branch left it; only this branch's own
        # change (docs) counts.
        repo = Repo(self)
        repo.write("seed.txt")
        fork = repo.commit("fork")
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("docs/a.md", "x\n")
        repo.commit("docs")
        repo.git("checkout", "-q", "main")
        repo.write("internal/x.go", "x\n")
        base = repo.commit("main moved")
        repo.git("checkout", "-q", "feature")
        self.assertNotEqual(fork, base)
        r = run_script(["--legs-for", base], cwd=repo.dir)
        self.assert_plan(r, CHECKS)

    def test_base_given_as_a_branch_name_works(self):
        repo = Repo(self)
        repo.write("seed.txt")
        repo.commit("base")
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("macos/App/a.swift", "x\n")
        repo.commit("app")
        r = run_script(["--legs-for", "main"], cwd=repo.dir)
        self.assert_plan(r, APP)

    def test_no_change_plans_checks_only(self):
        repo = Repo(self)
        repo.write("seed.txt")
        base = repo.commit("base")
        r = run_script(["--legs-for", base], cwd=repo.dir)
        self.assert_plan(r, CHECKS)

    def test_no_base_plans_every_leg_with_a_reason(self):
        r, repo, _ = select(self, change=lambda repo: repo.write("docs/a.md", "x\n"), base="")
        self.assert_all_with_reason(r)

    def test_missing_base_argument_plans_every_leg_with_a_reason(self):
        repo = Repo(self)
        repo.write("seed.txt")
        repo.commit("base")
        r = run_script(["--legs-for"], cwd=repo.dir)
        self.assert_all_with_reason(r)

    def test_non_commit_base_plans_every_leg_with_a_reason(self):
        repo = Repo(self)
        repo.write("seed.txt")
        repo.commit("base")
        repo.write("docs/a.md", "x\n")
        repo.commit("docs")
        tree = repo.git("rev-parse", "HEAD^{tree}")
        blob = repo.git("rev-parse", "HEAD:docs/a.md")
        for base in [tree, blob, "no-such-ref", "0" * 40]:
            with self.subTest(base=base):
                r = run_script(["--legs-for", base], cwd=repo.dir)
                self.assert_all_with_reason(r)

    def test_no_single_merge_base_plans_every_leg_with_a_reason(self):
        repo = Repo(self)
        repo.write("seed.txt")
        repo.commit("base")
        repo.git("checkout", "-q", "--orphan", "unrelated")
        repo.git("rm", "-rfq", ".")
        repo.write("docs/a.md", "x\n")
        repo.commit("unrelated root")
        r = run_script(["--legs-for", "main"], cwd=repo.dir)
        self.assert_all_with_reason(r)

    def test_failed_diff_plans_every_leg_with_a_reason(self):
        repo = Repo(self)
        repo.write("seed.txt")
        base = repo.commit("base")
        repo.write("docs/a.md", "x\n")
        repo.commit("docs")
        # Remove HEAD's root tree object: the commits resolve, so the base is a commit with a
        # merge base, and only reading the tree for the diff fails.
        tree = repo.git("rev-parse", "HEAD^{tree}")
        obj = repo.dir / ".git" / "objects" / tree[:2] / tree[2:]
        self.assertTrue(obj.exists(), "tree should be a loose object")
        os.chmod(obj, 0o644)
        obj.unlink()
        check = subprocess.run(
            ["git", "diff", "--name-status", base, "HEAD"],
            cwd=repo.dir, env=repo.env, capture_output=True, text=True,
        )
        self.assertNotEqual(check.returncode, 0, "setup must make the diff fail")
        r = run_script(["--legs-for", base], cwd=repo.dir)
        self.assert_all_with_reason(r)

    def test_outside_a_repository_plans_every_leg_with_a_reason(self):
        d = Path(tempfile.mkdtemp(prefix="ci-legs-norepo-"))
        self.addCleanup(shutil.rmtree, d, True)
        r = run_script(["--legs-for", "main"], cwd=d, env_extra={"GIT_CEILING_DIRECTORIES": str(d.parent)})
        self.assert_all_with_reason(r)

    def test_union_does_not_depend_on_path_order(self):
        # "aaa-unknown.txt" sorts before docs/: the last path's legs must not win.
        def change(repo):
            repo.write("aaa-unknown.txt", "x\n")
            repo.write("docs/a.md", "x\n")

        r, _, _ = select(self, change=change)
        self.assert_plan(r, EVERY)

    def test_two_merge_bases_plan_every_leg_with_a_reason(self):
        repo = Repo(self)
        repo.write("seed.txt")
        repo.commit("a")
        repo.git("branch", "x")
        repo.git("branch", "y")
        repo.git("checkout", "-q", "x")
        repo.write("docs/x.md", "x\n")
        repo.commit("bx")
        repo.git("checkout", "-q", "y")
        repo.write("docs/y.md", "y\n")
        repo.commit("by")
        repo.git("checkout", "-q", "-b", "mx", "x")
        repo.git("merge", "-q", "--no-edit", "y")
        repo.git("checkout", "-q", "-b", "my", "y")
        repo.git("merge", "-q", "--no-edit", "x")
        self.assertEqual(len(repo.git("merge-base", "--all", "mx", "my").split()), 2)
        r = run_script(["--legs-for", "mx"], cwd=repo.dir)
        self.assert_all_with_reason(r)


# ---------------------------------------------------------------- workflow read as data


def parse_workflow(text):
    """A small reader for the structure ci.yml is fixed to, instead of a YAML library.

    Reads: top-level keys at column 0; under `on:` the trigger names at indent 2; under `jobs:` each
    job id at indent 2 and its keys at indent 4. For a job it keeps `if` (a one-line scalar), `needs`
    (an inline list `[a, b]`, one scalar, or `- item` lines at indent 6) and `outputs` (`key: value`
    lines at indent 6). Everything else (steps and so on) is skipped. Comments and blank lines are
    dropped. A block scalar or a flow map where one of those keys is read is a parse failure.
    """
    on_keys, jobs = [], {}
    top = job = jobkey = None
    for raw in text.splitlines():
        line = re.sub(r"(^|\s)#.*$", "", raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()
        if indent == 0:
            top = body.split(":", 1)[0].strip("\"'")
            job = jobkey = None
            continue
        if top in ("on", "true") and indent == 2:
            on_keys.append(body.split(":", 1)[0].strip("\"'"))
        elif top == "jobs":
            if indent == 2 and body.endswith(":"):
                job = body[:-1]
                jobs[job] = {"if": None, "needs": [], "outputs": {}}
                jobkey = None
            elif indent == 4 and job is not None:
                key, _, val = body.partition(":")
                val = val.strip()
                jobkey = key
                if key == "if":
                    if val in ("|", ">", "|-", ">-", ""):
                        raise AssertionError("block `if` not supported by the reader: " + job)
                    jobs[job]["if"] = val.strip("\"'")
                elif key == "needs":
                    if val.startswith("["):
                        jobs[job]["needs"] = [x.strip() for x in val.strip("[]").split(",") if x.strip()]
                    elif val:
                        jobs[job]["needs"] = [val]
            elif indent >= 6 and job is not None and jobkey == "needs" and body.startswith("- "):
                jobs[job]["needs"].append(body[2:].strip())
            elif indent == 6 and job is not None and jobkey == "outputs" and ":" in body:
                k, _, v = body.partition(":")
                jobs[job]["outputs"][k.strip()] = v.strip()
    return {"on": on_keys, "jobs": jobs}


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.wf = parse_workflow(WORKFLOW.read_text())

    def job(self, name):
        self.assertIn(name, self.wf["jobs"], "no job " + name)
        return self.wf["jobs"][name]

    def test_there_is_a_job_for_every_leg_plan_and_gate(self):
        for job in LEGS + ["plan", "gate"]:
            self.assertIn(job, self.wf["jobs"])

    def test_each_leg_needs_plan(self):
        for leg in LEGS:
            with self.subTest(leg=leg):
                self.assertIn("plan", self.job(leg)["needs"])

    def test_each_leg_if_reads_only_its_own_plan_flag(self):
        for leg in LEGS:
            with self.subTest(leg=leg):
                cond = (self.job(leg)["if"] or "").strip()
                self.assertTrue(cond, "leg has no if")
                cond = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", cond).strip()
                m = re.fullmatch(r"needs\.plan\.outputs\.([A-Za-z0-9_-]+)(\s*==\s*['\"]true['\"])?", cond)
                self.assertIsNotNone(m, "if reads more than one plan flag, or something else: " + cond)
                self.assertEqual(m.group(1), flag(leg))

    def test_plan_declares_a_flag_for_every_leg_and_the_legs_list(self):
        outputs = self.job("plan")["outputs"]
        for leg in LEGS:
            self.assertIn(flag(leg), outputs)
        for name in ("legs", "skip", "verdict", "run"):
            self.assertIn(name, outputs)

    def test_gate_needs_plan_and_every_leg_and_nothing_else(self):
        self.assertEqual(sorted(self.job("gate")["needs"]), sorted(["plan"] + LEGS))

    def test_gate_runs_always(self):
        cond = (self.job("gate")["if"] or "").strip()
        cond = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", cond).strip()
        self.assertEqual(cond, "always()")

    def test_no_push_trigger(self):
        self.assertNotIn("push", self.wf["on"])

    def test_triggers_are_pull_request_schedule_and_dispatch(self):
        self.assertEqual(sorted(self.wf["on"]), ["pull_request", "schedule", "workflow_dispatch"])

    def test_the_reader_sees_a_planted_push_trigger_and_a_shared_flag(self):
        # The reader itself must be able to tell the wrong shapes apart.
        bad = "on:\n  push:\n    branches: [main]\njobs:\n  a:\n    if: needs.plan.outputs.a && needs.plan.outputs.b\n    needs: [plan]\n"
        wf = parse_workflow(bad)
        self.assertIn("push", wf["on"])
        self.assertIn("needs.plan.outputs.b", wf["jobs"]["a"]["if"])


# ---------------------------------------------------------------- gate decision


def needs_fixture(planned, results=None, plan_result="success", extra_jobs=(), skip=False,
                  verdict="", run="", plan_legs=None, drop=()):
    """A needs context where each planned leg succeeded and each other leg was skipped."""
    results = results or {}
    legs_out = " ".join(plan_legs if plan_legs is not None else planned)
    outputs = {"legs": legs_out, "skip": "true" if skip else "false", "verdict": verdict, "run": run}
    for leg in LEGS:
        outputs[flag(leg)] = "true" if leg in planned else "false"
    needs = {"plan": {"result": plan_result, "outputs": outputs}}
    for leg in LEGS:
        if leg in drop:
            continue
        needs[leg] = {"result": results.get(leg, "success" if leg in planned else "skipped"), "outputs": {}}
    for j in extra_jobs:
        needs[j] = {"result": "success", "outputs": {}}
    return needs


def gate(needs, event="pull_request", raw=None):
    stdin = raw if raw is not None else json.dumps(needs)
    return run_script(["gate", "--event", event], stdin=stdin)


class GateTests(unittest.TestCase):
    def green(self, needs, event="pull_request"):
        r = gate(needs, event)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(any(l.startswith("ok") for l in r.stdout.splitlines()), r.stdout)

    def red(self, needs, mention=None, event="pull_request", raw=None):
        r = gate(needs, event, raw=raw)
        self.assertEqual(r.returncode, 1, "expected red: " + r.stdout + r.stderr)
        lines = [l for l in r.stdout.splitlines() if l.startswith("red:")]
        self.assertTrue(lines, "no `red:` line: " + r.stdout)
        if mention:
            self.assertIn(mention, "\n".join(lines))

    def test_green_for_the_exact_match(self):
        for planned in (["checks"], ["checks", "go-checks", "go-test-macos", "mac-app-build"], LEGS):
            with self.subTest(planned=planned):
                self.green(needs_fixture(planned))

    def test_green_on_every_event_with_every_leg_run(self):
        for event in ("pull_request", "schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                self.green(needs_fixture(LEGS), event=event)

    def test_red_for_a_failed_planned_leg(self):
        for bad in ("failure", "cancelled"):
            with self.subTest(result=bad):
                self.red(needs_fixture(["checks", "go-checks"], {"go-checks": bad}), "go-checks")

    def test_red_for_a_skipped_planned_leg(self):
        self.red(needs_fixture(["checks", "swift-test"], {"swift-test": "skipped"}), "swift-test")

    def test_red_for_an_unplanned_leg_that_ran(self):
        for result in ("success", "failure"):
            with self.subTest(result=result):
                self.red(needs_fixture(["checks"], {"mac-app-build": result}), "mac-app-build")

    def test_red_for_a_plan_naming_a_leg_with_no_job(self):
        needs = needs_fixture(["checks"], plan_legs=["checks", "windows-test"])
        self.red(needs, "windows-test")

    def test_red_for_a_leg_missing_from_needs(self):
        self.red(needs_fixture(["checks"], drop=["swift-test"]), "swift-test")
        self.red(needs_fixture(["checks", "swift-test"], drop=["swift-test"]), "swift-test")

    def test_red_for_a_failed_plan(self):
        for result in ("failure", "cancelled", "skipped"):
            with self.subTest(result=result):
                self.red(needs_fixture(["checks"], plan_result=result), "plan")

    def test_red_for_a_failed_plan_even_when_the_legs_look_right(self):
        needs = needs_fixture(LEGS, plan_result="failure")
        self.red(needs, "plan")

    def test_red_for_unreadable_input(self):
        self.red(None, raw="")
        self.red(None, raw="not json")
        self.red(None, raw="{}")
        self.red(None, raw="[]")

    def test_red_when_plan_is_absent(self):
        needs = needs_fixture(["checks"])
        del needs["plan"]
        self.red(needs, "plan")

    def test_a_skip_is_green_only_on_a_success_verdict_on_schedule(self):
        ok = needs_fixture([], skip=True, verdict="success", run="42")
        self.green(ok, event="schedule")

    def test_red_over_a_skip_whose_verdict_was_a_failure(self):
        self.red(needs_fixture([], skip=True, verdict="failure", run="42"), "42", event="schedule")

    def test_red_over_a_skip_on_any_event_but_schedule(self):
        ok = needs_fixture([], skip=True, verdict="success", run="42")
        for event in ("workflow_dispatch", "pull_request"):
            with self.subTest(event=event):
                self.red(ok, event=event)

    def test_red_over_a_skip_naming_no_earlier_run(self):
        self.red(needs_fixture([], skip=True, verdict="success", run=""), event="schedule")

    def test_red_over_a_skip_where_a_leg_ran(self):
        needs = needs_fixture([], skip=True, verdict="success", run="42", results={"checks": "success"})
        self.red(needs, "checks", event="schedule")

    def test_red_over_a_skip_whose_verdict_is_not_exactly_success(self):
        for verdict in ("", "cancelled", "skipped", "Success"):
            with self.subTest(verdict=verdict):
                self.red(needs_fixture([], skip=True, verdict=verdict, run="42"), event="schedule")

    def test_red_for_a_plan_that_names_no_legs_without_a_skip(self):
        # Every job skipped and nothing planned: nothing ran, so it must not read as green.
        self.red(needs_fixture([]), event="pull_request")


# ---------------------------------------------------------------- nightly skip


HEAD = "a" * 40
OTHER = "b" * 40
THIS_RUN = 100


def run_obj(rid, head=HEAD, conclusion="success", status="completed"):
    return {"id": rid, "head_sha": head, "status": status, "conclusion": conclusion}


class FakeRunsApi:
    """A stand-in for the workflow runs list: serves fixture pages on 127.0.0.1."""

    def __init__(self, pages, endless=None):
        # pages: list of (status, body) where body is a dict (sent as JSON) or a str (sent as is).
        # endless: a page body served for every page number, forever.
        self.pages = pages
        self.endless = endless
        self.requests = []
        self.auth = []
        api = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                q = parse_qs(urlparse(self.path).query)
                page = int(q.get("page", ["1"])[0])
                api.requests.append(page)
                api.auth.append(self.headers.get("Authorization"))
                if api.endless is not None:
                    status, body = 200, api.endless
                elif page <= len(api.pages):
                    status, body = api.pages[page - 1]
                else:
                    status, body = 200, {"workflow_runs": []}
                data = body if isinstance(body, str) else json.dumps(body)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data.encode())

            def log_message(self, *a):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:%d/repos/o/r/actions/workflows/ci.yml/runs?branch=main&event=schedule" % self.server.server_port

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.server.shutdown()
        self.server.server_close()


def page(*runs):
    return (200, {"workflow_runs": list(runs)})


def nightly(pages=None, event="schedule", head=HEAD, run_id=THIS_RUN, url=None, endless=None, token="test-token"):
    api = FakeRunsApi(pages or [], endless=endless)
    with api:
        r = run_script(
            ["nightly", "--event", event, "--head", head, "--run-id", str(run_id), "--runs-url", url or api.url],
            env_extra={"GITHUB_TOKEN": token} if token else {},
        )
    out = {}
    for line in r.stdout.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            out[k] = v
    return r, out, api


class NightlySkipTests(unittest.TestCase):
    def assert_runs_everything(self, r, out):
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(out.get("skip"), "false", r.stdout)
        self.assertEqual(out.get("legs", "").split(), LEGS, r.stdout)
        self.assertTrue(out.get("reason", "").strip(), "no reason: " + r.stdout)
        self.assertNotIn("verdict", out)

    def assert_skips(self, r, out, verdict, run):
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(out.get("skip"), "true", r.stdout)
        self.assertEqual(out.get("legs", ""), "", r.stdout)
        self.assertEqual(out.get("verdict"), verdict, r.stdout)
        self.assertEqual(out.get("run"), str(run), r.stdout)

    def gate_over(self, out, event="schedule"):
        """Feed the nightly's decision to the gate over matching job results."""
        planned = out["legs"].split()
        needs = needs_fixture(
            planned, skip=out["skip"] == "true", verdict=out.get("verdict", ""), run=out.get("run", "")
        )
        return gate(needs, event)

    def test_matched_head_skips_every_leg_with_a_success_verdict(self):
        r, out, _ = nightly([page(run_obj(90))])
        self.assert_skips(r, out, "success", 90)
        g = self.gate_over(out)
        self.assertEqual(g.returncode, 0, g.stdout)

    def test_matched_head_with_a_failed_oldest_run_is_red(self):
        r, out, _ = nightly([page(run_obj(90, conclusion="failure"))])
        self.assert_skips(r, out, "failure", 90)
        g = self.gate_over(out)
        self.assertEqual(g.returncode, 1, g.stdout)

    def test_the_same_run_re_run_green_turns_the_gate_green(self):
        # A re-run keeps its run id; only the conclusion changes.
        r, out, _ = nightly([page(run_obj(90, conclusion="success"))])
        self.assert_skips(r, out, "success", 90)
        self.assertEqual(self.gate_over(out).returncode, 0)

    def test_verdict_is_the_oldest_by_id_not_by_position(self):
        newest_first = [page(run_obj(95, conclusion="success"), run_obj(90, conclusion="failure"))]
        oldest_first = [page(run_obj(90, conclusion="failure"), run_obj(95, conclusion="success"))]
        for pages in (newest_first, oldest_first):
            with self.subTest(order=[x["id"] for x in pages[0][1]["workflow_runs"]]):
                r, out, _ = nightly(pages)
                self.assert_skips(r, out, "failure", 90)
        newest_red = [page(run_obj(95, conclusion="failure"), run_obj(90, conclusion="success"))]
        r, out, _ = nightly(newest_red)
        self.assert_skips(r, out, "success", 90)

    def test_oldest_run_may_sit_on_a_later_page(self):
        pages = [page(run_obj(97), run_obj(95)), page(run_obj(91, head=OTHER), run_obj(90, conclusion="failure"))]
        r, out, api = nightly(pages)
        self.assert_skips(r, out, "failure", 90)
        self.assertGreaterEqual(max(api.requests), 2)

    def test_runs_that_are_not_finished_or_not_earlier_are_looked_past(self):
        pages = [
            page(
                run_obj(99, conclusion="cancelled"),
                run_obj(98, conclusion=None, status="in_progress"),
                run_obj(97, conclusion="skipped"),
                run_obj(THIS_RUN, conclusion="success"),
                run_obj(THIS_RUN + 5, conclusion="success"),
                run_obj(80, head=OTHER, conclusion="failure"),
            )
        ]
        r, out, _ = nightly(pages)
        self.assert_runs_everything(r, out)

    def test_looked_past_runs_do_not_become_the_verdict(self):
        pages = [page(run_obj(70, conclusion="cancelled"), run_obj(90, conclusion="success"))]
        r, out, _ = nightly(pages)
        self.assert_skips(r, out, "success", 90)

    def test_no_earlier_run_runs_every_leg(self):
        r, out, _ = nightly([page()])
        self.assert_runs_everything(r, out)
        r, out, _ = nightly([])
        self.assert_runs_everything(r, out)

    def test_no_run_on_this_head_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90, head=OTHER), run_obj(91, head=OTHER, conclusion="failure"))])
        self.assert_runs_everything(r, out)

    def test_an_unreadable_head_runs_every_leg(self):
        for head in ("", "not-a-sha", "abc", HEAD[:39]):
            with self.subTest(head=head):
                r, out, _ = nightly([page(run_obj(90))], head=head)
                self.assert_runs_everything(r, out)

    def test_a_failed_read_runs_every_leg(self):
        for status in (500, 404, 403):
            with self.subTest(status=status):
                r, out, _ = nightly([(status, {"message": "no"})])
                self.assert_runs_everything(r, out)

    def test_a_failed_read_on_a_later_page_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90)), (500, {"message": "no"})])
        self.assert_runs_everything(r, out)

    def test_a_refused_connection_runs_every_leg(self):
        # Port 1 on localhost has nothing listening.
        r, out, _ = nightly([page(run_obj(90))], url="http://127.0.0.1:1/runs")
        self.assert_runs_everything(r, out)

    def test_a_malformed_page_runs_every_leg(self):
        bad_bodies = [
            "this is not json",
            "",
            "[]",
            {"workflow_runs": "nope"},
            {"total_count": 1},
            {"workflow_runs": [None]},
            {"workflow_runs": [{"id": "x", "head_sha": HEAD, "status": "completed", "conclusion": "success"}]},
        ]
        for body in bad_bodies:
            with self.subTest(body=body):
                r, out, _ = nightly([(200, body)])
                self.assert_runs_everything(r, out)

    def test_a_malformed_later_page_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90)), (200, "not json")])
        self.assert_runs_everything(r, out)

    def test_a_dispatch_runs_every_leg_even_over_a_matched_head(self):
        r, out, api = nightly([page(run_obj(90))], event="workflow_dispatch")
        self.assert_runs_everything(r, out)

    def test_the_pull_request_event_runs_every_leg_over_a_matched_head(self):
        r, out, _ = nightly([page(run_obj(90))], event="pull_request")
        self.assert_runs_everything(r, out)

    def test_the_token_is_read_from_the_environment_and_sent_as_a_bearer(self):
        r, out, api = nightly([page(run_obj(90))], token="s3cret-token")
        self.assert_skips(r, out, "success", 90)
        self.assertTrue(api.auth)
        self.assertTrue(all(a == "Bearer s3cret-token" for a in api.auth), api.auth)
        self.assertNotIn("s3cret-token", r.stdout + r.stderr)

    def test_a_missing_token_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90))], token=None)
        self.assert_runs_everything(r, out)

    def test_pages_read_are_bounded(self):
        busy = {"workflow_runs": [run_obj(50, head=OTHER)]}
        r, out, api = nightly(endless=busy)
        self.assert_runs_everything(r, out)
        self.assertLessEqual(len(api.requests), 50)

    def test_every_decision_exits_zero(self):
        cases = [
            nightly([page(run_obj(90))]),
            nightly([page(run_obj(90, conclusion="failure"))]),
            nightly([(500, "x")]),
            nightly([(200, "garbage")]),
            nightly(head=""),
        ]
        for r, _, _ in cases:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_skip_never_reaches_green_on_a_failed_nightly_by_dispatch(self):
        # A skip decision fed to the gate on a dispatch is red whatever the verdict.
        r, out, _ = nightly([page(run_obj(90))])
        self.assert_skips(r, out, "success", 90)
        self.assertEqual(self.gate_over(out, event="workflow_dispatch").returncode, 1)

    def test_only_a_full_lowercase_hex_head_is_read(self):
        # The run list carries a run on exactly the odd head, so only the head check can refuse it.
        for head in (HEAD[:39], HEAD + "a", "A" * 40, "z" * 40, ""):
            with self.subTest(head=head):
                r, out, _ = nightly([page(run_obj(90, head=head))], head=head)
                self.assert_runs_everything(r, out)

    def test_an_unreadable_run_id_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90))], run_id="abc")
        self.assert_runs_everything(r, out)

    def test_a_read_cut_at_the_page_bound_runs_every_leg(self):
        # Every page holds a run on this head and none is empty, so the end of the list is never seen.
        endless = {"workflow_runs": [run_obj(90), run_obj(50, head=OTHER)]}
        r, out, api = nightly(endless=endless)
        self.assert_runs_everything(r, out)
        self.assertLessEqual(len(api.requests), 50)

    def test_a_run_with_a_conclusion_but_not_completed_is_not_counted(self):
        r, out, _ = nightly([page(run_obj(90, status="in_progress", conclusion="success"))])
        self.assert_runs_everything(r, out)

    def test_a_malformed_run_beside_a_matching_one_runs_every_leg(self):
        bad = {"id": "x", "head_sha": OTHER, "status": "in_progress", "conclusion": None}
        r, out, _ = nightly([page(run_obj(90), bad)])
        self.assert_runs_everything(r, out)

    def test_a_later_page_whose_runs_are_not_a_list_runs_every_leg(self):
        r, out, _ = nightly([page(run_obj(90)), (200, {"workflow_runs": {}})])
        self.assert_runs_everything(r, out)



if __name__ == "__main__":
    unittest.main()
