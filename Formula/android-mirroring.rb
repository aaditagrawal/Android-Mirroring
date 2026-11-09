class AndroidMirroring < Formula
  desc "Native Android screen mirroring and agent control for macOS"
  homepage "https://github.com/aaditagrawal/Android-Mirroring"
  license all_of: ["MIT", "Apache-2.0"]
  head "https://github.com/aaditagrawal/Android-Mirroring.git", branch: "main"

  depends_on macos: :sonoma

  uses_from_macos "swift" => :build

  def install
    system "scripts/build-app.sh", "--homebrew"
    libexec.install "build/Android Mirroring.app"
    bin.install_symlink libexec/"Android Mirroring.app/Contents/MacOS/droidctl"
    pkgshare.install "README.md", "THIRD_PARTY_NOTICES.md", "LICENSE", "docs"
  end

  def caveats
    <<~EOS
      Install ADB separately for pairing and local server startup:
        brew install --cask android-platform-tools

      Launch the app with:
        open "#{opt_libexec}/Android Mirroring.app"

      Optional Finder shortcut:
        mkdir -p ~/Applications
        ln -s "#{opt_libexec}/Android Mirroring.app" ~/Applications/

      droidctl is already on your Homebrew PATH. For MCP clients use:
        #{HOMEBREW_PREFIX}/bin/droidctl mcp

      Source builds require Swift 6 or later from Xcode or its Command Line Tools.
      This formula belongs in this project's tap, not homebrew/core.
    EOS
  end

  test do
    require "json"
    tools = JSON.parse(shell_output("#{bin}/droidctl tools"))
    assert_includes tools.map { |tool| tool.fetch("name") }, "screenshot"
    assert_includes tools.map { |tool| tool.fetch("name") }, "tap_element"
    request = { jsonrpc: "2.0", id: 1, method: "ping" }.to_json
    response = JSON.parse(pipe_output("#{bin}/droidctl mcp", "#{request}\n", 0))
    assert_equal 1, response.fetch("id")
    assert_equal({}, response.fetch("result"))
  end
end
