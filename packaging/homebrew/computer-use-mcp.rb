# DRAFT — groundwork for a future Homebrew tap. NOT published or tapped yet.
#
# Filled in for the v0.4.1 release tarball (url/sha256/version below). The one
# remaining step to make it installable: copy this file into a homebrew-tap repo
# (e.g. minghinmatthewlam/homebrew-tap) so users can
# `brew install minghinmatthewlam/tap/computer-use-mcp`. On each new release,
# update url/version and set `sha256` to `shasum -a 256` of the new tarball.
#
# Note on permissions: Homebrew installs an ad-hoc-signed build from source, which
# is fine for local use but means macOS attributes Accessibility / Screen Recording
# grants to the launching host process, and grants may need re-approval on upgrade.
# For a stable signing identity across upgrades, prefer the notarized release
# artifact (see docs/release/permissions.md).

class ComputerUseMcp < Formula
  desc "Background-safe macOS computer-use MCP server (agent-agnostic, Swift)"
  homepage "https://github.com/minghinmatthewlam/computer-use-mcp"
  license "MIT"

  version "0.4.1"
  url "https://github.com/minghinmatthewlam/computer-use-mcp/archive/refs/tags/v0.4.1.tar.gz"
  sha256 "f779fe77302980ee898a94dc4ba93b888cdfc2f9324a4d510784a575f7a3a279"

  depends_on :macos
  depends_on macos: :sonoma # macOS 14+
  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/computer-use-mcp"
  end

  def caveats
    <<~EOS
      computer-use-mcp needs Accessibility and Screen Recording permission for the
      terminal or app that launches it. Verify with:
        computer-use-mcp doctor
      For a stable signing identity across upgrades, prefer the notarized release
      build over this from-source install.
    EOS
  end

  test do
    assert_match "computer-use-mcp", shell_output("#{bin}/computer-use-mcp version")
  end
end
