class WindowNestNightly < Formula
  desc "Keyboard-driven window switcher for macOS (nightly)"
  homepage "https://github.com/y-writings/window-nest"
  # The Nightly workflow replaces this pin with the latest nightly-* tag archive.
  # nightly-pin: begin
  url "https://github.com/y-writings/window-nest/archive/595b6cf6f842287c595f50a5a41fdde946bf5101.tar.gz"
  version "2026.11.03"
  sha256 "38ed61b26195b31c3d9983f691fba57621698c267ba6899a10add388db9a715c"
  # nightly-pin: end
  license "MIT"

  # No head spec: this formula tracks published nightly tags, not main.
  # Use the window-nest formula with --HEAD to build the main branch.
  livecheck do
    url :stable
    regex(/^nightly[._-]v?(\d{4}\.\d{2}\.\d{2}(?:-[A-Za-z0-9]{1,32})?)$/i)
  end

  depends_on macos: :sonoma

  conflicts_with "window-nest", because: "both install WindowNest.app and the window-nest command"

  def install
    unless which("swift")
      odie "WindowNest requires Swift 6 or newer. Install Xcode 16 or the Command Line Tools."
    end

    swift_major = Utils.safe_popen_read("swift", "--version")[/Swift version (\d+)/, 1]&.to_i
    if swift_major.nil? || swift_major < 6
      odie "WindowNest requires Swift 6 or newer. Install Xcode 16 or the Command Line Tools."
    end

    # SwiftPM evaluates Package.swift inside its own sandbox, which cannot
    # nest inside Homebrew's sandbox.
    system "swift", "build",
           "--disable-sandbox",
           "--configuration", "release",
           "--jobs", ENV.make_jobs.to_s,
           "--product", "WindowNest"

    binary = Pathname(".build/release/WindowNest")
    unless binary.file?
      binary = Pathname.glob(".build/**/release/WindowNest").select(&:file?).max_by(&:mtime)
    end
    odie "Swift build did not produce a WindowNest executable." if binary.nil?

    app = prefix/"WindowNest.app"
    (app/"Contents/MacOS").install binary.realpath
    (app/"Contents").install "Resources/Info.plist"
    inreplace app/"Contents/Info.plist" do |s|
      s.gsub!(
        "<key>CFBundleShortVersionString</key><string>0.1.0</string>",
        "<key>CFBundleShortVersionString</key><string>#{version}</string>",
      )
      s.gsub!(
        "<key>CFBundleVersion</key><string>1</string>",
        "<key>CFBundleVersion</key><string>#{version}</string>",
      )
    end

    # Ad-hoc signature, matching `make app` when CODE_SIGN_IDENTITY is unset.
    # A Developer ID would keep the TCC identity stable across upgrades.
    system "codesign", "--force", "--sign", "-", app

    (bin/"window-nest").write <<~SH
      #!/bin/bash
      open "#{prefix}/WindowNest.app"
    SH
    chmod 0755, bin/"window-nest"
  end

  def caveats
    <<~EOS
      WindowNest is a menu-bar app. Start it with:

        window-nest

      The bundle is:

        #{opt_prefix}/WindowNest.app

      This is the nightly formula, pinned to a nightly-* tag. It cannot be
      installed beside the stable window-nest formula.

      Grant Accessibility and Screen Recording to that bundle, then relaunch.
      This formula ad-hoc signs the app. After `brew upgrade`, macOS may
      require those permissions again. See README.md for the tccutil steps.
    EOS
  end

  test do
    app = prefix/"WindowNest.app"
    plist = app/"Contents/Info.plist"
    assert_predicate app/"Contents/MacOS/WindowNest", :executable?
    assert_equal "dev.ywritings.WindowNest",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{plist}").strip
    assert_equal version.to_s,
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' #{plist}").strip
    system "codesign", "--verify", app
    assert_predicate bin/"window-nest", :executable?
  end
end
