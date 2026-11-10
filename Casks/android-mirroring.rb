cask "android-mirroring" do
  version "1.0.0"
  sha256 "c092ef980659cbd0d8782f4ab91b67c94241c297ca79b2b0f552f707bd5fc48e"

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
