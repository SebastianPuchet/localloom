cask "localloom" do
  version "1.0"
  sha256 "ce873001280c51f571d1e050a9b20bf130d22f9053f78271bdda4688199efb1b"

  url "https://github.com/SebastianPuchet/localloom/releases/download/v#{version}/LocalLoom-#{version}.dmg"
  name "LocalLoom"
  desc "Local-only menu bar screen recorder with a webcam bubble"
  homepage "https://github.com/SebastianPuchet/localloom"

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
