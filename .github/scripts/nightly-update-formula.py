#!/usr/bin/env python3
"""Replace the nightly-pin block in Formula/window-nest-nightly.rb."""

import os
import re
import sys
from pathlib import Path


def main() -> None:
    url = os.environ["NIGHTLY_URL"]
    version = os.environ["NIGHTLY_VERSION"]
    sha256 = os.environ["NIGHTLY_SHA256"]
    for name, value in (("url", url), ("version", version), ("sha256", sha256)):
        if "\n" in value or '"' in value:
            sys.exit(f"invalid {name}")
    if re.fullmatch(r"[0-9a-f]{64}", sha256) is None:
        sys.exit("sha256 must be 64 hex characters")

    path = Path(os.environ.get("NIGHTLY_FORMULA", "Formula/window-nest-nightly.rb"))
    text = path.read_text()
    block = (
        "  # nightly-pin: begin\n"
        f'  url "{url}"\n'
        f'  version "{version}"\n'
        f'  sha256 "{sha256}"\n'
        "  # nightly-pin: end\n"
    )
    pattern = re.compile(r"  # nightly-pin: begin\n.*?  # nightly-pin: end\n", re.S)
    new, count = pattern.subn(block, text, count=1)
    if count != 1:
        sys.exit("nightly-pin markers not found in formula")
    path.write_text(new)


if __name__ == "__main__":
    main()
