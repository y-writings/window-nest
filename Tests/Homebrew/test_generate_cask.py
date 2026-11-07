"""The release Cask must identify and verify the archive users install."""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

GENERATOR = pathlib.Path(__file__).resolve().parents[2] / "scripts/generate-cask.py"


class GenerateCaskTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.archive = pathlib.Path(directory.name) / "WindowNest release.zip"
        self.contents = b"published release archive"
        self.archive.write_bytes(self.contents)

    def generate(self, tag, archive=None):
        return subprocess.run(
            [sys.executable, str(GENERATOR), tag, str(archive or self.archive)],
            capture_output=True,
            text=True,
        )

    def test_channels_use_the_tag_and_downloaded_archive(self):
        for channel, version, token, conflict in [
            ("weekly", "2026.11.03", "window-nest", "window-nest-nightly"),
            ("nightly", "2026.11.03", "window-nest-nightly", "window-nest"),
            ("nightly", "2024.02.29-B2", "window-nest-nightly", "window-nest"),
        ]:
            with self.subTest(channel=channel, version=version):
                result = self.generate(f"{channel}-{version}")
                self.assertEqual(result.returncode, 0, result.stderr)
                cask = result.stdout
                self.assertIn(f'cask "{token}" do', cask)
                self.assertIn(f'version "{version}"', cask)
                self.assertIn(
                    f'sha256 "{hashlib.sha256(self.contents).hexdigest()}"', cask
                )
                self.assertIn(
                    f"releases/download/{channel}-#{{version}}/WindowNest.zip", cask
                )
                self.assertIn(f'conflicts_with cask: "{conflict}"', cask)

    def test_invalid_tags_do_not_generate_a_cask(self):
        for tag in [
            "main",
            "weekly-2026.02.30",
            "nightly-2026.02.29",
            "weekly-2026.11.03-2",
            "nightly-2026.11.03-unsafe_text",
            'nightly-2026.11.03"',
        ]:
            with self.subTest(tag=tag):
                result = self.generate(tag, "unused.zip")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("tag must", result.stderr)

    @unittest.skipUnless(shutil.which("brew"), "Homebrew is required for the DSL check")
    def test_homebrew_loads_default_and_custom_appdirs(self):
        result = self.generate("nightly-2024.02.29-B2")
        self.assertEqual(result.returncode, 0, result.stderr)
        ruby = '''require "cask/cask_loader"
payload = JSON.parse($stdin.read)
source = payload.fetch("source")
custom_appdir = payload.fetch("appdir")
["/Applications", custom_appdir].each do |appdir|
  config = Cask::Config.new(explicit: { appdir: appdir })
  cask = Cask::CaskLoader::FromContentLoader.new(source).load(config: config)
  app = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::App) }
  wrapper = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::CommandWrapper) }
  expected = File.join(appdir, "WindowNest.app")
  abort "wrong app target" unless app.target.to_s == expected
  abort "wrong launcher" unless wrapper.to_args == ["window-nest", { executable: "/usr/bin/open", args: [expected] }]
end
'''
        loaded = subprocess.run(
            ["brew", "ruby", "-e", ruby],
            env={
                **os.environ,
                "HOMEBREW_DEVELOPER": "1",
                "HOMEBREW_NO_AUTO_UPDATE": "1",
            },
            input=json.dumps({
                "source": result.stdout,
                "appdir": str(self.archive.parent / "Applications with spaces"),
            }),
            capture_output=True,
            text=True,
        )
        self.assertEqual(loaded.returncode, 0, loaded.stderr)

    def test_missing_archive_does_not_generate_a_cask(self):
        result = self.generate("nightly-2026.11.03", self.archive.parent / "missing.zip")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
