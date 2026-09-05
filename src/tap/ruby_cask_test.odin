package tap

import "core:strings"
import "core:testing"

@(test)
test_parse_ruby_cask_preflight_file_writes :: proc(t: ^testing.T) {
	fixture := `cask "antigravity-linux" do
  arch arm: "arm", intel: "x64"
  arch_dir = on_arch_conditional arm: "arm64", intel: "x64"
  os linux: "linux"

  version "2.12.2,6298742303883264"
  sha256 intel: "fc2e2af49a45aefee9558bce56aaa4bbde00d560d354357af1b834a9dd43cd33"

  url "https://storage.googleapis.com/antigravity-public/antigravity-hub/#{version.csv.first}-#{version.csv.second}/linux-#{arch}/Antigravity.tar.gz"
  name "Google Antigravity"

  binary "#{staged_path}/Antigravity-#{arch_dir}/antigravity"
  artifact "antigravity.desktop",
           target: "#{Dir.home}/.local/share/applications/antigravity.desktop"
  artifact "antigravity-url-handler.desktop",
           target: "#{Dir.home}/.local/share/applications/antigravity-url-handler.desktop"
  artifact "antigravity.png",
           target: "#{Dir.home}/.local/share/icons/hicolor/512x512/apps/antigravity.png"

  preflight do
    File.write("#{staged_path}/antigravity.desktop", <<~EOS)
      [Desktop Entry]
      Name=Antigravity
      Comment=Agent orchestration platform
      GenericName=AI Agent Platform
      Exec="#{HOMEBREW_PREFIX}/bin/antigravity" %F
      Icon=#{Dir.home}/.local/share/icons/hicolor/512x512/apps/antigravity.png
      Type=Application
      StartupNotify=false
      StartupWMClass=Antigravity
      Categories=Development;Utility;
      Keywords=antigravity;agent;ai;
    EOS

    File.write("#{staged_path}/antigravity-url-handler.desktop", <<~EOS)
      [Desktop Entry]
      Name=Antigravity - URL Handler
      Comment=Agent orchestration platform
      GenericName=AI Agent Platform
      Exec="#{HOMEBREW_PREFIX}/bin/antigravity" "%U"
      Icon=#{Dir.home}/.local/share/icons/hicolor/512x512/apps/antigravity.png
      Type=Application
      NoDisplay=true
      Terminal=false
      StartupNotify=true
      StartupWMClass=Antigravity
      Categories=Utility;Development;
      MimeType=x-scheme-handler/antigravity;
      Keywords=antigravity;
    EOS
  end
end
`

	c, ok := parse_ruby_cask(fixture, "antigravity-linux")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, c.token, "antigravity-linux")
	testing.expect_value(t, len(c.preflight_files), 2)

	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "antigravity.desktop")
		testing.expect(t, strings.contains(c.preflight_files[0].content, "[Desktop Entry]"), "desktop entry header")
		testing.expect(t, strings.contains(c.preflight_files[0].content, "Name=Antigravity"), "desktop app name")
		testing.expect(t, !strings.contains(c.preflight_files[0].content, "#{HOMEBREW_PREFIX}"), "HOMEBREW_PREFIX should be interpolated")

		testing.expect_value(t, c.preflight_files[1].path, "antigravity-url-handler.desktop")
		testing.expect(t, strings.contains(c.preflight_files[1].content, "MimeType=x-scheme-handler/antigravity;"), "mime handler scheme")
	}
}

@(test)
test_parse_ruby_cask_preflight_steps_write_file :: proc(t: ^testing.T) {
	fixture := `cask "antigravity-ide-linux" do
  version "2.5.5,4923483625488384"
  url "https://example.com/ide.tar.gz"

  preflight_steps do
    write_file "antigravity-ide.desktop", <<~EOS
      [Desktop Entry]
      Name=Antigravity IDE
      Comment=AI Coding Agent IDE
      Exec="{{HOMEBREW_PREFIX}}/bin/antigravity-ide" %F
      Icon=antigravity-ide
      Type=Application
    EOS
  end
end
`

	c, ok := parse_ruby_cask(fixture, "antigravity-ide-linux")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "antigravity-ide.desktop")
		testing.expect(t, strings.contains(c.preflight_files[0].content, "Name=Antigravity IDE"), "desktop app name")
		testing.expect(t, !strings.contains(c.preflight_files[0].content, "{{HOMEBREW_PREFIX}}"), "{{HOMEBREW_PREFIX}} should be interpolated")
	}
}
