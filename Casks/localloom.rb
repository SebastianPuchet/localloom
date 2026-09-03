cask "localloom" do
  version "1.0"
  sha256 :no_check

  url "https://example.com/releases/LocalLoom-#{version}.dmg"
  name "LocalLoom"
  desc "Local-only menu bar screen recorder with a webcam bubble"
  homepage "https://example.com/localloom"

  app "LocalLoom.app"

  # LocalLoom is self-signed, not notarized. `--no-quarantine` is deprecated, so the
  # quarantine flag has to be cleared here instead.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/LocalLoom.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.sebastianpuchet.localloom.plist",
  ]
end
