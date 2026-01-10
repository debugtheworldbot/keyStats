cask "keystats" do
  version "1.7"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"  # TODO: Will be auto-updated by GitHub Actions on first release

  url "https://github.com/debugtheworldbot/keyStats/releases/download/v#{version}/KeyStats.dmg"
  name "KeyStats"
  desc "macOS menu bar app for tracking keyboard and mouse statistics"
  homepage "https://github.com/debugtheworldbot/keyStats"

  depends_on macos: ">= :ventura"

  app "KeyStats.app"

  zap trash: [
    "~/Library/Preferences/com.keystats.app.plist",
  ]

  caveats <<~EOS
    KeyStats requires Accessibility permissions to function.

    On first launch:
    1. Click "Open System Settings" in the permission dialog
    2. Enable KeyStats in System Settings > Privacy & Security > Accessibility

    If you encounter the "App is damaged" error (due to ad-hoc signing), run:
      sudo xattr -rd com.apple.quarantine "/Applications/KeyStats.app"

    Or install with the --no-quarantine flag:
      brew install --cask --no-quarantine keystats

    Note: All statistics are stored locally and never uploaded to any server.
  EOS
end
