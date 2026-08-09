class Ubrew < Formula
  desc "The fastest package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "2026.8.1"

  on_macos do
    # macOS artifacts are not built by CI yet. The URLs below track the
    # release layout and get real SHAs once a macOS build exists; until
    # then macOS installs fail loudly at download time.
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v2026.8.1/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: real SHA256 once a macOS v2026.8.1 asset ships
    else
      url "https://github.com/rjallais/ubrew/releases/download/v2026.8.1/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: real SHA256 once a macOS v2026.8.1 asset ships
    end
  end

  on_linux do
    # Self-contained prebuilt binary (ubrew + libsqlite3-fts5.so); the
    # tarball's binary already carries a bare libsqlite3-fts5.so DT_NEEDED.
    url "https://github.com/rjallais/ubrew/releases/download/v2026.8.1/ubrew-linux-x86_64.tar.gz"
    sha256 "ea7dd7d52268f7814669025f8825d8c72b76fb06cd6c511e02bfabd429b81b88"
  end

  def install
    if OS.linux?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.so"
    else
      bin.install "ubrew"
    end
  end

  def post_install
    ohai "Run 'ubrew init' to create the ubrew directory tree"
  end

  test do
    assert_match "ubrew", shell_output("#{bin}/ubrew help")
  end
end
