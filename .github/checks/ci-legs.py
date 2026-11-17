#!/usr/bin/env python3
"""Decides which CI jobs ("legs") a change needs, whether the gate is green, and whether the
nightly run can be skipped. Python 3 standard library only. Run it through ci-legs.sh.

    ci-legs.sh --legs-for <base>
        Prints `leg <id>` for each leg the change between <base> and HEAD can reach and
        `skip <id>: <reason>` for each leg left out. A change that cannot be told prints one
        `all-legs: <reason>` line and every leg. Exit 0 always.

    ci-legs.sh gate --event <event name>      (the `needs` context as JSON on stdin)
        Prints `ok ...` and exits 0 when exactly the planned legs ran and passed; prints
        `red: ...` lines and exits 1 otherwise.

    ci-legs.sh nightly --event <name> --head <sha> --run-id <id> --runs-url <url>
        Reads GITHUB_TOKEN from the environment and prints `key=value` lines: whether every leg
        is skipped because an earlier nightly already ran this head, or every leg runs and why.
        Exit 0 always.

The path rules below are the one place a path is mapped to legs. A path no rule names runs every
leg, so a new kind of file is never skipped by accident.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

LEGS = ["checks", "go-checks", "go-test-macos", "swift-test", "mac-app-build"]

GO = ["checks", "go-checks", "go-test-macos", "mac-app-build"]
SWIFT = ["checks", "swift-test", "mac-app-build"]
APP = ["checks", "mac-app-build"]
CHECKS = ["checks"]

# (kind, path or prefix, legs). `file` is an exact path, `dir` a directory prefix ending in "/".
# Workflows, the ignore file, dependabot.yml, the shared check scripts (lib.sh, annotate-*.sh,
# select-xcode.sh), this selector, its tests and any other path match no row and run every leg.
RULES = [
    ("file", ".github/checks/go-format.sh", CHECKS),
    ("file", ".github/checks/changelog-entry.sh", CHECKS),
    ("dir", ".github/ISSUE_TEMPLATE/", CHECKS),
    ("file", ".github/PULL_REQUEST_TEMPLATE.md", CHECKS),
    ("file", "CHANGELOG.md", CHECKS),
    ("file", "README.md", CHECKS),
    ("file", "CONTRIBUTING.md", CHECKS),
    ("file", "SECURITY.md", CHECKS),
    ("file", "CODE_OF_CONDUCT.md", CHECKS),
    ("file", "LICENSE", CHECKS),
    ("dir", "docs/", CHECKS),
    ("file", "macos/scripts/release.sh", CHECKS),
    ("file", "macos/scripts/publish-release.sh", CHECKS),
    ("file", "macos/scripts/release-lib.sh", CHECKS),
    ("file", "macos/scripts/verify-release.sh", CHECKS),
    ("dir", "macos/scripts/dmg/", CHECKS),
    ("dir", "cmd/", GO),
    ("dir", "internal/", GO),
    ("file", "go.mod", GO),
    ("file", "go.sum", GO),
    ("file", ".github/checks/go-vet.sh", GO),
    ("file", ".github/checks/go-build.sh", GO),
    ("file", ".github/checks/go-test.sh", GO),
    ("dir", "macos/Packages/CGMRelayCore/", SWIFT),
    ("file", ".github/checks/swift-test.sh", SWIFT),
    ("dir", "macos/App/", APP),
    ("dir", "macos/Helper/", APP),
    ("file", "macos/project.yml", APP),
    ("file", "macos/scripts/build.sh", APP),
    ("dir", "macos/CGMRelay.xcodeproj/", APP),
    ("file", ".github/checks/mac-app-build.sh", APP),
]

WHY_LEFT_OUT = {
    "checks": "always planned",
    "go-checks": "no Go source, module file or Go check script changed",
    "go-test-macos": "no Go source, module file or Go check script changed",
    "swift-test": "no Swift package or Swift test script changed",
    "mac-app-build": "no Go, Swift, app or app build file changed",
}

GIT_TIMEOUT = 120
MAX_PAGES = 10
PER_PAGE = 100
HTTP_TIMEOUT = 30
MAX_BODY = 16 * 1024 * 1024


# ---------------------------------------------------------------- the selector


def legs_for_path(path):
    """The legs one path reaches; every leg when no rule names it."""
    for kind, pattern, legs in RULES:
        if kind == "file" and path == pattern:
            return legs
        if kind == "dir" and path.startswith(pattern):
            return legs
    return LEGS


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, timeout=GIT_TIMEOUT, errors="replace"
    )


def changed_paths(base):
    """(paths, None) for the change from the merge base of <base> and HEAD to HEAD, or
    (None, reason) when it cannot be told."""
    r = git("rev-parse", "--verify", "--quiet", base + "^{commit}")
    if r.returncode != 0:
        return None, "base %r is not a commit here" % base
    r = git("merge-base", "--all", base, "HEAD")
    bases = r.stdout.split()
    if len(bases) != 1:
        return None, "base %r has no single merge base with HEAD" % base
    # No rename detection: a rename shows as the deletion of the old path and the addition of the
    # new one, so both sides count.
    r = git("diff", "--name-status", "-z", "--no-renames", "--no-ext-diff", bases[0], "HEAD")
    if r.returncode != 0:
        return None, "the diff against %r failed" % base
    fields = [f for f in r.stdout.split("\0") if f]
    return fields[1::2], None


def select(base):
    try:
        paths, why = changed_paths(base)
    except Exception as e:  # git missing, timed out, unreadable output
        paths, why = None, "the change could not be read (%s)" % type(e).__name__
    if paths is None:
        return ["all-legs: %s; every leg runs" % why] + ["leg " + leg for leg in LEGS]
    planned = {"checks"}
    for p in paths:
        planned.update(legs_for_path(p))
    lines = []
    for leg in LEGS:
        if leg in planned:
            lines.append("leg " + leg)
        else:
            lines.append("skip %s: %s" % (leg, WHY_LEFT_OUT[leg]))
    return lines


# ---------------------------------------------------------------- the gate


def gate_decision(needs, event):
    """(reds, ok_line): reds is a list of reasons, empty when green."""
    if not isinstance(needs, dict):
        return ["no job results to check"], None
    plan = needs.get("plan")
    if not isinstance(plan, dict):
        return ["plan is missing from the job results"], None
    if plan.get("result") != "success":
        return ["plan did not succeed (%s)" % plan.get("result")], None
    outputs = plan.get("outputs")
    if not isinstance(outputs, dict):
        return ["plan reported no outputs"], None
    planned = str(outputs.get("legs") or "").split()
    results = {}
    reds = []
    for leg in LEGS + planned:
        job = needs.get(leg)
        if not isinstance(job, dict):
            reds.append("%s has no job result, so the plan and the workflow disagree" % leg)
        else:
            results[leg] = job.get("result")
    if outputs.get("skip") == "true":
        if event != "schedule":
            reds.append("every leg was skipped on a %s run, which only the nightly may do" % event)
        if outputs.get("verdict") != "success":
            reds.append(
                "every leg was skipped over run %s, whose verdict was %s"
                % (outputs.get("run"), outputs.get("verdict") or "missing")
            )
        if not str(outputs.get("run") or "").strip():
            reds.append("every leg was skipped without naming the earlier run it rests on")
        for leg, result in results.items():
            if result != "skipped":
                reds.append("%s was %s but every leg should be skipped" % (leg, result))
        if planned:
            reds.append("the plan skips every leg yet names %s" % " ".join(planned))
        return reds, "ok: every leg skipped, resting on run %s (%s)" % (
            outputs.get("run"), outputs.get("verdict"))
    if not planned:
        reds.append("plan names no legs")
    for leg, result in results.items():
        if leg in planned and result != "success":
            reds.append("%s was planned and finished %s" % (leg, result))
        if leg not in planned and result != "skipped":
            reds.append("%s was not planned and finished %s" % (leg, result))
    return reds, "ok: %d planned legs passed (%s)" % (len(planned), " ".join(planned))


def gate(event):
    try:
        needs = json.loads(sys.stdin.read())
    except ValueError:
        needs = None
    reds, ok_line = gate_decision(needs, event)
    if reds:
        for r in reds:
            print("red: " + r)
        return 1
    print(ok_line)
    return 0


# ---------------------------------------------------------------- the nightly skip


def every_leg(reason):
    return ["skip=false", "legs=" + " ".join(LEGS), "reason=" + reason]


class ReadFailed(Exception):
    pass


def fetch_page(url, n, token):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ReadFailed("runs url is not http or https")
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query) if k not in ("page", "per_page")]
    query += [("per_page", str(PER_PAGE)), ("page", str(n))]
    full = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))
    req = urllib.request.Request(
        full, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        body = json.loads(resp.read(MAX_BODY).decode("utf-8"))
    runs = body.get("workflow_runs") if isinstance(body, dict) else None
    if not isinstance(runs, list):
        raise ReadFailed("page %d has no workflow_runs list" % n)
    for run in runs:
        if not isinstance(run, dict) or type(run.get("id")) is not int:
            raise ReadFailed("page %d holds a run that is not an object with an id" % n)
    return runs


def nightly(event, head, run_id, url):
    if event != "schedule":
        return every_leg("a %s run always runs every leg" % (event or "unnamed"))
    if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
        return every_leg("the head commit is unreadable")
    try:
        this_run = int(run_id)
    except (TypeError, ValueError):
        return every_leg("this run's id is unreadable")
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        return every_leg("no token to read the earlier runs with")
    on_head = []
    try:
        for n in range(1, MAX_PAGES + 1):
            runs = fetch_page(url, n, token)
            if not runs:
                break
            for run in runs:
                if (
                    run.get("status") == "completed"
                    and run.get("conclusion") in ("success", "failure")
                    and run["id"] < this_run
                    and run.get("head_sha") == head
                ):
                    on_head.append(run)
        else:
            return every_leg("the earlier runs were not all read in %d pages" % MAX_PAGES)
    except Exception as e:  # HTTP error, refused connection, bad token, malformed page
        return every_leg("the earlier runs could not be read (%s)" % type(e).__name__)
    if not on_head:
        return every_leg("no earlier finished nightly ran this head")
    oldest = min(on_head, key=lambda run: run["id"])
    return ["skip=true", "legs=", "verdict=" + oldest["conclusion"], "run=%d" % oldest["id"]]


# ---------------------------------------------------------------- command line


def option(args, name):
    """The value after --name, or "" when absent."""
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return ""


def main(argv):
    args = argv[1:]
    if args[:1] == ["--legs-for"]:
        print("\n".join(select(args[1] if len(args) > 1 else "")))
        return 0
    if args[:1] == ["gate"]:
        return gate(option(args, "--event"))
    if args[:1] == ["nightly"]:
        print("\n".join(nightly(
            option(args, "--event"), option(args, "--head"),
            option(args, "--run-id"), option(args, "--runs-url"))))
        return 0
    print("usage: ci-legs.sh --legs-for <base> | gate --event <name> | nightly --event <name> "
          "--head <sha> --run-id <id> --runs-url <url>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
