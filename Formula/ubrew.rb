class Ubrew < Formula
  desc "The fastest macOS package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "0.1.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v0.1.0/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: replace with real SHA256 before merging/releasing
    else
      url "https://github.com/rjallais/ubrew/releases/download/v0.1.0/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER" # TODO: replace with real SHA256 before merging/releasing
    end
  end

  on_linux do
    url "https://github.com/rjallais/ubrew/archive/1ea1d82192b9e02031a54bd3a6e716cae0f8378d.tar.gz"
    sha256 "e1853061890a2f43327681b1a2918c1437d45113be2aded1bdbb7e8492e52e58"

    depends_on "odin" => :build
    depends_on "patchelf" => :build

    resource "sqlite-amalgamation" do
      url "https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip"
      sha256 "6cebd1d8403fc58c30e93939b246f3e6e58d0765a5cd50546f16c00fd805d2c3"
    end
  end

  def install
    if OS.linux?
      # Build libsqlite3-fts5.so from the SQLite amalgamation with FTS5 support
      odin_sqlite_dir = buildpath/"src/vendor/odin-sqlite3"
      odin_sqlite_dir.mkpath # ensure the target dir exists (defensive)
      resource("sqlite-amalgamation").stage do
        system ENV.cc, "-c", "-O2", "-fPIC", "-DSQLITE_ENABLE_FTS5",
               "sqlite3.c", "-o", "sqlite3-fts5.o"
        system ENV.cc, "-shared", "sqlite3-fts5.o", "-lm",
               "-o", odin_sqlite_dir/"libsqlite3-fts5.so"
        system "strip", odin_sqlite_dir/"libsqlite3-fts5.so"
      end

      # Build ubrew with the custom FTS5 library.
      # Odin embeds the absolute build-path of the .so as DT_NEEDED.
      # We add an explicit RUNPATH for #{lib} and fix up the NEEDED entry
      # with patchelf so the binary finds the .so at its installed location.
      system "odin", "build", "src", "-out:ubrew",
             "-define:SQLITE3_CUSTOM_FTS5=true",
             "-o:speed", "-no-bounds-check",
             "-extra-linker-flags:-Wl,-rpath,#{lib}"

      # Fix the DT_NEEDED from absolute build path -> bare library name
      old_needed = odin_sqlite_dir/"libsqlite3-fts5.so"
      system "patchelf", "--replace-needed", old_needed.to_s, "libsqlite3-fts5.so",
             "ubrew"

      bin.install "ubrew"
      lib.install odin_sqlite_dir/"libsqlite3-fts5.so"
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
