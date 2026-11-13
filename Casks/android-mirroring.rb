cask "android-mirroring" do
  version "1.0.1"
  sha256 "843e45612719b79ef2ea0c6e780b556e697c20a02090d02cb6902ff3ed2b158d"

  url "https://github.com/aaditagrawal/Android-Mirroring/releases/download/v#{version}/Android-Mirroring-#{version}-arm64.dmg"
  name "Android Mirroring"
  desc "Native Android screen mirroring and agent control"
  homepage "https://github.com/aaditagrawal/Android-Mirroring"

  depends_on arch: :arm64
  depends_on cask: "android-platform-tools"
  depends_on macos: :sonoma

  app "Android Mirroring.app"
  binary "#{appdir}/Android Mirroring.app/Contents/MacOS/droidctl", target: "droidctl"
end
