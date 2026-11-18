"""Checks for the release scripts in macos/scripts: the unmount retry in release-lib.sh and the
publish confirmation in publish-release.sh.

Run from the repository root:

    python3 -m unittest discover -s .github/checks/tests -v

Python 3 standard library only. Nothing here touches the network, the real origin or a real disk
image: hdiutil, git, gh, curl, sleep, mount and diskutil are fakes first on PATH that record every
call, and every fixture lives in a temp dir that is removed on every exit.

INTERFACE UNDER TEST

1. release-lib.sh `detach_mount <mountpoint>`: tries `hdiutil detach` up to three times with a short
   wait between tries, returns success on the first try that works, stops early once the mount is
   gone, and fails (nonzero) after the third failed try. The mount counts as gone when its
   directory no longer exists and neither `hdiutil info`, `mount` nor `diskutil info` lists it; the
   fakes keep those four in agreement. release.sh unmounts its own mount only through it.

2. publish-release.sh `X.Y.Z [--confirm X.Y.Z]`: with `--confirm` equal to the version it needs no
   terminal; with no `--confirm` it asks on the terminal as before. A confirm value that differs
   from the version, or is empty, and a run with no terminal and no `--confirm`, refuse before any
   tag, push, ls-remote or gh call, with no prompt. The test-only refusal still comes first.
"""

import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SCRIPTS = os.path.join(REPO_ROOT, "macos", "scripts")

# Only a call that hangs ends at this; no check waits on a time.
HANG_CEILING_SECONDS = 120

VERSION = "1.2.3"
COMMIT = "0123456789abcdef0123456789abcdef01234567"

FAKE_COMMON = """#!/bin/bash
name="$(basename "$0")"
{ printf '%s\\t' "$name" "$@"; printf '\\n'; } >> "$CALLS_LOG"
"""

FAKES = {
    "hdiutil": FAKE_COMMON
    + """
case "${1:-}" in
  detach)
    n=$(cat "$STATE_DIR/detach_count" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/detach_count"
    # A runaway loop ends here with a wrong count rather than hanging.
    [ "$n" -le 10 ] || exit 0
    result="$(echo "$HDIUTIL_DETACH_PLAN" | awk -v n="$n" '{print $n}')"
    case "${result:-ok}" in
      ok) rmdir "$MOUNT_DIR"; exit 0 ;;
      failgone) rmdir "$MOUNT_DIR"; echo "hdiutil: couldn't unmount" >&2; exit 1 ;;
      *) echo "hdiutil: couldn't unmount: Resource busy" >&2; exit 1 ;;
    esac
    ;;
  info)
    echo "framework       : 1"
    if [ -d "$MOUNT_DIR" ]; then
      echo "================================================"
      echo "image-path      : /tmp/fake.dmg"
      echo "/dev/disk4          	GUID_partition_scheme"
      echo "/dev/disk4s1        	Apple_HFS           	$MOUNT_DIR"
    fi
    exit 0
    ;;
esac
exit 0
""",
    "mount": FAKE_COMMON
    + """
[ ! -d "$MOUNT_DIR" ] || echo "/dev/disk4s1 on $MOUNT_DIR (hfs, local, nodev, nosuid, read-only)"
exit 0
""",
    "diskutil": FAKE_COMMON
    + """
[ -d "$MOUNT_DIR" ]
""",
    "sleep": FAKE_COMMON + "exit 0\n",
    "curl": FAKE_COMMON + "exit 22\n",
    "gh": FAKE_COMMON + "echo 'release not found' >&2\nexit 1\n",
    "git": FAKE_COMMON
    + """
[ "${1:-}" != "-C" ] || shift 2
case "${1:-}" in
  rev-parse) [ "${2:-}" = HEAD ] && { echo "$FAKE_HEAD"; exit 0; }; exit 1 ;;
  status) exit 0 ;;
  ls-remote) exit 1 ;;
esac
exit 0
""",
}


def write_executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class Sandbox:
    """A temp dir holding fake tools, their call log, and a place for scratch files."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="release-scripts-test.")
        self.bin = os.path.join(self.root, "bin")
        self.state = os.path.join(self.root, "state")
        self.tmp = os.path.join(self.root, "tmp")
        for d in (self.bin, self.state, self.tmp):
            os.mkdir(d)
        self.calls_log = os.path.join(self.root, "calls.log")
        open(self.calls_log, "w").close()
        for name, text in FAKES.items():
            write_executable(os.path.join(self.bin, name), text)

    def env(self, **extra):
        env = {
            "PATH": self.bin + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.root,
            "TMPDIR": self.tmp,
            "CALLS_LOG": self.calls_log,
            "STATE_DIR": self.state,
            "FAKE_HEAD": COMMIT,
        }
        env.update(extra)
        return env

    def calls(self):
        with open(self.calls_log) as f:
            return [line.rstrip("\n").split("\t")[:-1] for line in f if line.strip()]

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def run(cmd, env, cwd):
    # No controlling terminal, no stdin: a prompt on /dev/tty cannot be answered.
    return subprocess.run(
        cmd,
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=HANG_CEILING_SECONDS,
        start_new_session=True,
    )


class DetachMountTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        # A path with a space, as the real mount has, so quoting is exercised too.
        self.mount_dir = os.path.join(self.box.root, "CGM Relay")
        os.mkdir(self.mount_dir)

    def detach(self, plan):
        script = (
            "set -euo pipefail\n"
            f"SCRIPT_DIR={SCRIPTS!r}; MACOS_DIR={os.path.join(REPO_ROOT, 'macos')!r}; REPO_ROOT={REPO_ROOT!r}\n"
            f"source {os.path.join(SCRIPTS, 'release-lib.sh')!r}\n"
            'detach_mount "$MOUNT_DIR"\n'
        )
        result = run(
            ["bash", "-c", script],
            self.box.env(MOUNT_DIR=self.mount_dir, HDIUTIL_DETACH_PLAN=plan),
            REPO_ROOT,
        )
        detaches = [c for c in self.box.calls() if c[0] == "hdiutil" and len(c) > 1 and c[1] == "detach"]
        return result, detaches

    def test_a_clean_unmount_is_tried_once(self):
        result, detaches = self.detach("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(detaches), 1)

    def test_a_busy_first_try_is_retried_and_the_step_succeeds(self):
        result, detaches = self.detach("fail ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(detaches), 2)
        for call in detaches:
            self.assertIn(self.mount_dir, call, "every try names the mount")

    def test_a_mount_that_never_lets_go_fails_after_exactly_three_tries(self):
        result, detaches = self.detach("fail fail fail fail fail fail")
        self.assertNotEqual(result.returncode, 0, "the last failure is reported, not swallowed")
        self.assertEqual(len(detaches), 3)

    def test_a_mount_that_is_gone_after_a_failed_try_is_not_tried_again(self):
        _, detaches = self.detach("failgone ok ok")
        self.assertEqual(len(detaches), 1)

    def test_the_release_script_unmounts_its_own_mount_only_through_the_retry(self):
        with open(os.path.join(SCRIPTS, "release.sh")) as f:
            lines = f.read().splitlines()
        direct = [l for l in lines if "hdiutil detach" in l and not l.lstrip().startswith("#")]
        # The cleanup trap keeps its single forced detach as the last resort; nothing else may.
        self.assertEqual(len(direct), 1, direct)
        self.assertIn("-force", direct[0])
        retried = [l for l in lines if "detach_mount" in l and not l.lstrip().startswith("#")]
        self.assertEqual(len(retried), 2, "the layout mount and the final image mount each use it")
        for l in retried:
            self.assertIn("die", l, "a failed retry still ends the build with a message")


class PublishConfirmTests(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        self.repo = os.path.join(self.box.root, "repo")
        scripts = os.path.join(self.repo, "macos", "scripts")
        os.makedirs(scripts)
        for name in ("publish-release.sh", "release-lib.sh"):
            shutil.copy(os.path.join(SCRIPTS, name), scripts)
        self.script = os.path.join(scripts, "publish-release.sh")
        self.out = os.path.join(self.repo, "macos", ".build", "release", VERSION)
        os.makedirs(self.out)
        self.write_record(test_only="no")

    def write_record(self, test_only):
        files = {
            f"CGM-Relay-{VERSION}.dmg": b"disk image",
            "appcast.xml": b"<rss/>",
            f"CGM-Relay-{VERSION}.md": b"notes",
        }
        lines = [f"version: {VERSION}", "build: 7", f"commit: {COMMIT}", f"test_only: {test_only}"]
        for name, data in files.items():
            with open(os.path.join(self.out, name), "wb") as f:
                f.write(data)
            lines.append(f"file: {hashlib.sha256(data).hexdigest()} {name}")
        with open(os.path.join(self.out, "RELEASE.md"), "w") as f:
            f.write("\n".join(lines) + "\n")

    def publish(self, *args):
        return run(["bash", self.script, *args], self.box.env(), self.repo)

    def surfaces_touched(self):
        """Every recorded call except the read-only record checks."""
        touched = []
        for call in self.box.calls():
            tool, args = call[0], call[1:]
            if tool == "git":
                if args[:1] == ["-C"]:
                    args = args[2:]
                if args[:1] in (["rev-parse"], ["status"]):
                    continue
            touched.append(call)
        return touched

    def assert_refused_untouched(self, result):
        self.assertEqual(result.returncode, 1, f"a refusal, not a usage error or a run: {result.stderr}")
        self.assertIn("FAILED", result.stderr)
        self.assertNotIn("usage:", result.stderr)
        self.assertEqual(self.surfaces_touched(), [], "no tag, push, ls-remote, gh or curl call")
        self.assertNotIn(f"Type {VERSION} to publish", result.stdout + result.stderr, "no prompt was shown")
        self.assertEqual(os.listdir(self.box.tmp), [], "the refusal removes its own scratch directory")

    def test_a_different_confirm_value_refuses_before_anything_is_touched(self):
        for wrong in ("1.2.4", "v1.2.3", "1.2.3 ", "1.2", "1.2.3.0"):
            with self.subTest(confirm=wrong):
                open(self.box.calls_log, "w").close()
                result = self.publish(VERSION, "--confirm", wrong)
                self.assert_refused_untouched(result)
                self.assertNotIn("no terminal", result.stderr, "refused for the value, not for lack of a terminal")

    def test_an_empty_confirm_value_refuses_before_anything_is_touched(self):
        result = self.publish(VERSION, "--confirm", "")
        self.assert_refused_untouched(result)
        self.assertNotIn("no terminal", result.stderr, "an empty value is not the same as no flag")

    def test_no_terminal_and_no_confirm_refuses_before_anything_is_touched(self):
        result = self.publish(VERSION)
        self.assert_refused_untouched(result)

    def test_a_matching_confirm_goes_ahead_with_no_terminal(self):
        for args in ((VERSION, "--confirm", VERSION), ("--confirm", VERSION, VERSION)):
            with self.subTest(args=args):
                open(self.box.calls_log, "w").close()
                result = self.publish(*args)
                self.assertNotIn("no terminal", result.stderr)
                self.assertNotIn("usage:", result.stderr)
                # The fake origin cannot be asked, so the run stops at its first surface:
                # reaching that query is what shows the confirmation was accepted.
                git_args = [c[1:] for c in self.box.calls() if c[0] == "git"]
                self.assertTrue(
                    any("ls-remote" in a for a in git_args),
                    f"the first publish surface was reached: {self.box.calls()}",
                )

    def test_a_test_only_record_is_refused_first_whatever_the_confirm(self):
        self.write_record(test_only="yes")
        for confirm in (VERSION, "1.2.4", ""):
            with self.subTest(confirm=confirm):
                open(self.box.calls_log, "w").close()
                result = self.publish(VERSION, "--confirm", confirm)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("test-only", result.stderr)
                self.assertEqual(self.surfaces_touched(), [])


if __name__ == "__main__":
    unittest.main()
