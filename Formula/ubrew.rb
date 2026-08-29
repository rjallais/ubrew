class Ubrew < Formula
  desc "The fastest package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "2026.8.4"

  on_macos do
    # macOS binaries are built in CI (arm64 on macos-14, x86_64 on macos-15-intel)
    # and the SHA256 values below are filled automatically from the release
    # assets. They are unsigned for now (see docs/RELEASING.md). Until the
    # assets exist for a given version these stay PLACEHOLDER so installs
    # fail loudly instead of silently downloading an invalid archive.
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v2026.8.4/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "3966991a2fb51ebfaa18891c89c4237c12188275ed7a647aecf04ffc7f4cfa90" # set from the macOS arm64 release asset
    else
      url "https://github.com/rjallais/ubrew/releases/download/v2026.8.4/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "682d2c8169e6db44bbb28a4174ae3884b3988e4c36d7b512f0a545f8d6774dce" # set from the macOS x86_64 release asset
    end
  end

  on_linux do
    # Self-contained prebuilt binary (ubrew + libsqlite3-fts5.so); the
    # tarball's binary already carries a bare libsqlite3-fts5.so DT_NEEDED.
    url "https://github.com/rjallais/ubrew/releases/download/v2026.8.4/ubrew-linux-x86_64.tar.gz"
    sha256 "9aef65a0d1cfe124c1af502a6746d3b10999f1a588177d86036adf39ce856081"
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
