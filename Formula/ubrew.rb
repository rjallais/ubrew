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

  def install
    bin.install "ubrew"
  end

  def post_install
    ohai "Run 'ubrew init' to create the ubrew directory tree"
  end

  test do
    assert_match "ubrew", shell_output("#{bin}/ubrew help")
  end
end
