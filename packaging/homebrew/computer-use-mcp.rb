# DRAFT — groundwork for a future Homebrew tap. NOT published or tapped yet.
#
# This formula is a placeholder committed as scaffolding. It cannot be installed
# until the first GitHub release ships a stable source tarball and the `url`,
# `sha256`, and `version` below are filled in for that release. Presented in the
# README as "coming".
#
# When the first release is cut:
#   1. Point `url` at the release tarball
#      (https://github.com/minghinmatthewlam/computer-use-mcp/archive/refs/tags/vX.Y.Z.tar.gz).
#   2. Set `sha256` to `shasum -a 256` of that tarball.
#   3. Bump `version` to match the tag.
#   4. Move this file into a homebrew-tap repo (e.g. minghinmatthewlam/homebrew-tap)
#      so users can `brew install minghinmatthewlam/tap/computer-use-mcp`.
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

  # TODO(release): replace with the real release tarball + checksum + version.
  version "0.3.0"
  url "https://github.com/minghinmatthewlam/computer-use-mcp/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
