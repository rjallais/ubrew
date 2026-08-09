class Ubrew < Formula
  desc "The fastest package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "0.2.0"

  on_macos do
    # No v0.2.0 macOS artifacts are published yet. The URLs below track the
    # release layout; fill the real SHA256 (and remove the TODO) when a macOS
    # build exists. Until then macOS installs fail loudly at download.
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v0.2.0/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: real SHA256 once a macOS v0.2.0 asset ships
    else
      url "https://github.com/rjallais/ubrew/releases/download/v0.2.0/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: real SHA256 once a macOS v0.2.0 asset ships
    end
  end

  on_linux do
    # v0.2.0 is a prebuilt Linux binary release (ubrew + libsqlite3-fts5.so).
    url "https://github.com/rjallais/ubrew/releases/download/v0.2.0/ubrew-linux-x86_64.tar.gz"
    sha256 "b7beea5d27117447b8593c76a596f1ca1311b9ef1369cf4438bead5acb64b9ca"
    depends_on "patchelf" => :build
  end

  def install
    if OS.linux?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.so"
      # The released binary embeds the *absolute* build-time path of
      # libsqlite3-fts5.so as DT_NEEDED. Rewrite it to a bare name and add
      # #{lib} to the RUNPATH so the loader finds the library at install time.
      # (The NEEDED string is fixed for a given release tarball; if the
      # artifact is rebuilt, this path must be updated to match.)
      system "patchelf", "--replace-needed",
             "/run/media/rjallais/TOSHIBA-500/nanobrew-src/src/vendor/odin-sqlite3/libsqlite3-fts5.so",
             "libsqlite3-fts5.so", bin/"ubrew"
      system "patchelf", "--add-rpath", lib.to_s, bin/"ubrew"
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