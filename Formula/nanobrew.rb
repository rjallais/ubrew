class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.193"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.193/nb-arm64-apple-darwin.tar.gz"
      sha256 "e9d6e74ab7de52c368687a28c333210439167331014c417b3108fbb8631ab70f"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.193/nb-x86_64-apple-darwin.tar.gz"
      sha256 "b03b6a26f23652f8a7fbbddec1c62aa5b7a079693ccf80b55de5742e1a526bfc"
    end
  end


  def install
    bin.install "nb"
  end

  def post_install
    ohai "Run 'nb init' to create the nanobrew directory tree"
  end

  test do
    assert_match "nanobrew", shell_output("#{bin}/nb help")
  end
end
