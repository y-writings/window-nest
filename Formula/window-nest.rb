class WindowNest < Formula
  desc "Keyboard-driven window switcher for macOS"
  homepage "https://github.com/y-writings/window-nest"
  url "https://github.com/y-writings/window-nest/archive/refs/tags/weekly-2026.10.26.tar.gz"
  sha256 "11b2b1b217253229f786723aea460f0af9476c301af40b0e04af6336c0224996"
  license "MIT"
  head "https://github.com/y-writings/window-nest.git", branch: "main"

  # Snapshots are weekly CalVer tags. This repository has no GitHub Releases.
  livecheck do
    url :stable
    regex(/^weekly[._-]v?(\d{4}\.\d{2}\.\d{2})$/i)
  end

  depends_on macos: :sonoma

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
