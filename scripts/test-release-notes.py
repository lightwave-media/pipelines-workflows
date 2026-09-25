"""Execute the reusable workflow's real helper against temporary Git histories."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/release-core.yml"
WORKFLOW_TEXT = WORKFLOW.read_text(encoding="utf-8")
HELPER = textwrap.dedent(
    WORKFLOW_TEXT.split("# BEGIN RELEASE NOTES HELPER (executed verbatim by local CI)\n", 1)[1]
    .split("          # END RELEASE NOTES HELPER", 1)[0]
)
# Every git this suite spawns, directly or through HELPER, runs in this
# environment. git exports GIT_DIR and GIT_INDEX_FILE to its hooks and neither
# cwd nor -C outranks them, and `git config` honours GIT_CONFIG, so an inherited
# selector would build the fixture in the repo that set it. Identity travels as
# environment because `git config user.*` is a write, and a write lands
# wherever git resolves the repo. scripts/fixture-isolation-test.sh proves it.
GIT_REPO_SELECTORS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG",
)
FIXTURE_GIT_ENV = {
    **{key: value for key, value in os.environ.items() if key not in GIT_REPO_SELECTORS},
    "GIT_AUTHOR_NAME": "Release Test",
    "GIT_AUTHOR_EMAIL": "release-test@example.com",
    "GIT_COMMITTER_NAME": "Release Test",
    "GIT_COMMITTER_EMAIL": "release-test@example.com",
}


class ReleaseNotesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-notes-test-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "consumer"
        self.repo.mkdir()
        self.runner_temp = Path(self.temporary.name) / "runner"
        self.runner_temp.mkdir()
        self.output = self.runner_temp / "output"
        self.git("init", "--quiet")

    def git(self, *args, input=None):
        # Signing is disabled in command scope, never written to a config file.
        return subprocess.check_output(
            ["git", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
            cwd=self.repo, env=FIXTURE_GIT_ENV, text=True, input=input, stderr=subprocess.PIPE,
        ).strip()

    def commit(self, subject):
        self.git("commit", "--quiet", "--allow-empty", "-F", "-", input=subject)
        return self.git("rev-parse", "HEAD")

    def generate(self, tag, success=True):
        self.output.write_text("", encoding="utf-8")
        result = subprocess.run(
            ["bash", "-c", HELPER], cwd=self.repo, capture_output=True, text=True,
            env={**FIXTURE_GIT_ENV, "TAG": tag, "RUNNER_TEMP": str(self.runner_temp),
                 "GITHUB_OUTPUT": str(self.output), "GITHUB_SERVER_URL": "https://github.com",
                 "GITHUB_REPOSITORY": "example/consumer"},
        )
        if not success:
            self.assertNotEqual(result.returncode, 0)
            return None
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        body = Path(outputs["path"]).read_text(encoding="utf-8")
        self.assertLessEqual(len(body.encode("utf-8")), 120000)
        return body, outputs["range"]

    def test_module_range_excludes_old_history_and_reruns_ignore_newer_tags(self):
        self.commit("feat: OLD-HISTORY")
        self.git("tag", "nullboiler/v1.0.0")
        self.commit("fix: BETWEEN-TAGS")
        self.git("tag", "v90.0.0")
        self.git("tag", "nullhub/v90.0.0")
        target = self.commit("feat: CURRENT-CHANGE")
        self.git("tag", "-a", "nullboiler/v2.0.0", "-m", "module release")
        first = self.generate("nullboiler/v2.0.0")
        self.assertEqual(first[1], f"nullboiler/v1.0.0..{target}")
        self.assertNotIn("OLD-HISTORY", first[0])
        self.assertIn("BETWEEN-TAGS", first[0])
        self.assertIn("CURRENT-CHANGE", first[0])
        self.assertIn("/compare/nullboiler%2Fv1.0.0...nullboiler%2Fv2.0.0", first[0])
        self.commit("feat: FUTURE-CHANGE")
        self.git("tag", "nullboiler/v3.0.0")
        self.assertEqual(self.generate("nullboiler/v2.0.0"), first)

    def test_root_tags_do_not_take_a_module_tag_as_the_previous_release(self):
        self.commit("feat: ROOT-OLD")
        self.git("tag", "v1.0.0")
        self.commit("fix: ROOT-INCLUDED")
        self.git("tag", "v9module/v100.0.0")
        self.commit("fix: ROOT-CURRENT")
        self.git("tag", "v2.0.0")
        body, revision_range = self.generate("v2.0.0")
        self.assertTrue(revision_range.startswith("v1.0.0.."))
        self.assertNotIn("ROOT-OLD", body)
        self.assertIn("ROOT-INCLUDED", body)
        self.assertIn("ROOT-CURRENT", body)

    def test_first_module_release_retains_history_and_links_to_tag_history(self):
        self.commit("feat: FIRST-HISTORY")
        self.git("tag", "v1.0.0")
        target = self.commit("fix: FIRST-MODULE")
        self.git("tag", "module/v1.0.0")
        body, revision_range = self.generate("module/v1.0.0")
        self.assertEqual(revision_range, target)
        self.assertIn("FIRST-HISTORY", body)
        self.assertIn("FIRST-MODULE", body)
        self.assertIn("/commits/module%2Fv1.0.0", body)

    def test_oversized_unicode_notes_are_bounded_with_an_honest_history_link(self):
        self.commit("feat: " + "界" * 130000)
        self.git("tag", "module/v1.0.0")
        body, _ = self.generate("module/v1.0.0")
        self.assertIn("Release notes abbreviated", body)
        self.assertIn("Full commit history", body)
        self.assertIn("/commits/module%2Fv1.0.0", body)
        full = (self.runner_temp / "release-notes/full-notes.md").read_bytes()
        self.assertGreater(len(full), 125000)
        self.assertNotIn("\ufffd", body)

    def test_missing_target_fails_before_publication(self):
        self.commit("feat: initial")
        self.generate("module/v9.9.9", success=False)
        self.assertEqual(self.output.read_text(), "")

    def test_dry_run_and_publication_use_the_same_unconditional_notes(self):
        notes_step = WORKFLOW_TEXT.split("      - name: Generate release notes", 1)[1]
        notes_step = notes_step.split("      - name: Create GitHub Release", 1)[0]
        self.assertNotIn("if:", notes_step)
        self.assertIn("NOTES_PATH: ${{ steps.notes.outputs.path }}", WORKFLOW_TEXT)
        self.assertIn('--notes-file "$NOTES_PATH"', WORKFLOW_TEXT)
        self.assertIn("RANGE: ${{ steps.notes.outputs.range }}", WORKFLOW_TEXT)


if __name__ == "__main__":
    unittest.main()
