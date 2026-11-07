"""Publication must preserve archives and keep nightlies out of latest releases."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest

PUBLISHER = pathlib.Path(__file__).resolve().parents[2] / "scripts/publish-macos-release.sh"


class PublishMacOSReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = pathlib.Path(directory.name)
        self.calls = self.directory / "calls.jsonl"
        gh = self.directory / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["GH_CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[2] == os.environ.get("GH_FAIL_COMMAND"):
    sys.exit(1)
''')
        gh.chmod(0o755)

    def publish(self, channel="nightly", exists=True, asset=True, draft=False, fail=""):
        result = subprocess.run(
            ["bash", str(PUBLISHER)],
            cwd=self.directory,
            env={
                **os.environ,
                "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
                "GH_CALLS": str(self.calls),
                "GH_FAIL_COMMAND": fail,
                "CHANNEL": channel,
                "RELEASE_VERSION": "2026.11.03",
                "RELEASE_TAG": f"{channel}-2026.11.03",
                "RELEASE_EXISTS": str(exists).lower(),
                "ASSET_EXISTS": str(asset).lower(),
                "IS_DRAFT": str(draft).lower(),
            },
            capture_output=True,
            text=True,
        )
        calls = []
        if self.calls.exists():
            calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def test_new_releases_distinguish_weekly_and_nightly(self):
        for channel, flags in [
            ("weekly", ["--prerelease=false"]),
            ("nightly", ["--prerelease", "--latest=false"]),
        ]:
            with self.subTest(channel=channel):
                self.calls.unlink(missing_ok=True)
                result, calls = self.publish(channel=channel, exists=False, asset=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][:3], ["release", "create", f"{channel}-2026.11.03"])
                self.assertIn("--verify-tag", calls[0])
                self.assertEqual(calls[0][-len(flags):], flags)

    def test_published_archive_is_never_replaced(self):
        result, calls = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_missing_draft_asset_is_uploaded_before_publication(self):
        result, calls = self.publish(asset=False, draft=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["release", "upload", "nightly-2026.11.03", ".build/macos-release/WindowNest.zip"],
            ["release", "edit", "nightly-2026.11.03", "--draft=false", "--prerelease", "--latest=false"],
        ])

    def test_failed_upload_does_not_publish_a_draft(self):
        result, calls = self.publish(asset=False, draft=True, fail="upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[1] for call in calls], ["upload"])

    def test_existing_draft_archive_is_published_without_an_upload(self):
        result, calls = self.publish(draft=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [[
            "release", "edit", "nightly-2026.11.03", "--draft=false",
            "--prerelease", "--latest=false",
        ]])
