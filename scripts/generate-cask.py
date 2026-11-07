#!/usr/bin/env python3
"""Generate a Homebrew Cask for a published WindowNest release archive."""

import argparse
import datetime
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("tag", help="Published weekly or nightly tag")
parser.add_argument("archive", type=pathlib.Path, help="Downloaded WindowNest.zip")
args = parser.parse_args()
match = re.fullmatch(r"(weekly|nightly)-(\d{4}\.\d{2}\.\d{2})(-[A-Za-z0-9]{1,32})?", args.tag)
if not match or (match[1] == "weekly" and match[3]):
    parser.error("tag must be weekly-YYYY.MM.DD or nightly-YYYY.MM.DD[-suffix]")
channel, date, suffix = match.groups()
version = date + (suffix or "")
try:
    datetime.datetime.strptime(date, "%Y.%m.%d")
except ValueError:
    parser.error("tag must contain a valid calendar date")
checksum = hashlib.sha256(args.archive.read_bytes()).hexdigest()
token = "window-nest-nightly" if channel == "nightly" else "window-nest"
conflict = "window-nest" if channel == "nightly" else "window-nest-nightly"

print(f'''cask "{token}" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/y-writings/window-nest/releases/download/{channel}-#{{version}}/WindowNest.zip"
  name "WindowNest"
  desc "Keyboard-driven window switcher for macOS"
  homepage "https://github.com/y-writings/window-nest"

  conflicts_with cask: "{conflict}"
  depends_on macos: :sonoma

  app "WindowNest.app"
  command_wrapper "window-nest",
                  executable: "/usr/bin/open",
                  args:       ["#{{appdir}}/WindowNest.app"]

  uninstall quit: "dev.ywritings.WindowNest"

  zap trash: "~/Library/Preferences/dev.ywritings.WindowNest.plist"

  caveats <<~EOS
    Grant Accessibility and Screen Recording to WindowNest.app in your Applications folder, then relaunch.
  EOS
end''')
