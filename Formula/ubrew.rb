class Ubrew < Formula
  desc "The fastest package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "2026.9.2"

  on_macos do
    # macOS binaries are built in CI (arm64 on macos-14, x86_64 on macos-15-intel)
    # and the SHA256 values below are filled automatically from the release
    # assets. They are unsigned for now (see docs/RELEASING.md). Until the
    # assets exist for a given version these stay PLACEHOLDER so installs
    # fail loudly instead of silently downloading an invalid archive.
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v2026.9.2/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "12108bb7d5affad64cd867773949e396fe3e8e873bc9ff825f6662368984f40c" # set from the macOS arm64 release asset
    else
      url "https://github.com/rjallais/ubrew/releases/download/v2026.9.2/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "46278d6d5b2b2a65433dc105f744e1b3e2f23d22b93f3404b02748dfa9256dcc" # set from the macOS x86_64 release asset
    end
  end

  on_linux do
    # Self-contained prebuilt binary (ubrew + libsqlite3-fts5.so); the
    # tarball's binary already carries a bare libsqlite3-fts5.so DT_NEEDED.
    url "https://github.com/rjallais/ubrew/releases/download/v2026.9.2/ubrew-linux-x86_64.tar.gz"
    sha256 "8e552eeb1b1cbf5fb77dbe2f3ce601d78569dc72475bf9af9556727471bdda84"
  end

  def install
    if OS.linux?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.so"
    elsif OS.mac?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.dylib"
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
