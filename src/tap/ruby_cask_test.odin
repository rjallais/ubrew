package tap

import "core:strings"
import "core:testing"
import "../cask"

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

@(test)
test_postflight_write_file_not_staged :: proc(t: ^testing.T) {
	fixture := `cask "test-postflight" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  postflight do
    File.write("#{staged_path}/bad.desktop", <<~EOS)
      [Desktop Entry]
      Name=Bad
    EOS
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-postflight")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 0)
}

@(test)
test_preflight_write_after_unless_block :: proc(t: ^testing.T) {
	fixture := `cask "test-unless" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    unless false
      # nested block
    end
    File.write("#{staged_path}/valid.desktop", <<~EOS)
      [Desktop Entry]
      Name=Valid
    EOS
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-unless")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.desktop")
	}
}

@(test)
test_preflight_write_after_for_block :: proc(t: ^testing.T) {
	fixture := `cask "test-for" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    for item in ["a", "b"]
      # loop
    end
    File.write("#{staged_path}/valid.desktop", <<~EOS)
      [Desktop Entry]
      Name=Valid
    EOS
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-for")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.desktop")
	}
}

@(test)
test_preflight_write_quoted_heredoc_terminator :: proc(t: ^testing.T) {
	fixture := `cask "test-quoted-heredoc" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    File.write("#{staged_path}/single.desktop", <<~'EOS')
      [Desktop Entry]
      Name=Single
      Comment=Version #{version}
    EOS
    File.write("#{staged_path}/double.desktop", <<"EOS")
      [Desktop Entry]
      Name=Double
      Comment=Version #{version}
    EOS
    File.write("#{staged_path}/single-str.txt", 'Literal #{version}')
    File.write("#{staged_path}/double-str.txt", "Expanded #{version}")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-quoted-heredoc")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 4)
	if len(c.preflight_files) == 4 {
		testing.expect_value(t, c.preflight_files[0].path, "single.desktop")
		testing.expect(t, strings.contains(c.preflight_files[0].content, "Comment=Version #{version}"), "single quoted heredoc must not interpolate")

		testing.expect_value(t, c.preflight_files[1].path, "double.desktop")
		testing.expect(t, strings.contains(c.preflight_files[1].content, "Comment=Version 1.0.0"), "double quoted heredoc must interpolate")

		testing.expect_value(t, c.preflight_files[2].path, "single-str.txt")
		testing.expect_value(t, c.preflight_files[2].content, "Literal #{version}")

		testing.expect_value(t, c.preflight_files[3].path, "double-str.txt")
		testing.expect_value(t, c.preflight_files[3].content, "Expanded 1.0.0")
	}
}

@(test)
test_preflight_write_single_quoted_path_and_empty_content :: proc(t: ^testing.T) {
	fixture := `cask "test-path-quote-and-empty" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    File.write('#{version}.desktop', <<~EOS)
      [Desktop Entry]
      Name=LiteralPath
    EOS
    File.write("#{staged_path}/empty-marker.txt", "")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-path-quote-and-empty")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 2)
	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "#{version}.desktop")
		testing.expect(t, strings.contains(c.preflight_files[0].content, "Name=LiteralPath"))

		testing.expect_value(t, c.preflight_files[1].path, "empty-marker.txt")
		testing.expect_value(t, c.preflight_files[1].content, "")
	}
}

@(test)
test_preflight_token_boundaries :: proc(t: ^testing.T) {
	fixture := `cask "test-token-boundaries" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  not_preflight do
    File.write("#{staged_path}/ignored.txt", "should not extract")
  end

  preflight do
    puts "File.write('#{staged_path}/nested.txt', 'ignored')"
    SomeFile.write("#{staged_path}/other.txt", "ignored")
    ::File.write("#{staged_path}/valid.txt", "extracted")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-token-boundaries")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[0].content, "extracted")
	}
}

@(test)
test_preflight_end_with_comment :: proc(t: ^testing.T) {
	fixture := `cask "test-end-comment" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    File.write("#{staged_path}/valid.txt", "valid")
  end # finish preflight

  postflight do
    File.write("#{staged_path}/ignored.txt", "ignored")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-end-comment")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[0].content, "valid")
	}
}

@(test)
test_preflight_comment_in_quoted_string :: proc(t: ^testing.T) {
	fixture := `cask "test-comment-in-string" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    puts " end#literal"
    File.write("#{staged_path}/valid.txt", "valid")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-comment-in-string")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[0].content, "valid")
	}
}

@(test)
test_interpolate_escaped_marker :: proc(t: ^testing.T) {
	res1 := interpolate_cask_string("Literal \\#{version}", "1.0.0", "x64", nil)
	defer delete(res1)
	testing.expect_value(t, res1, "Literal \\#{version}")

	res2 := interpolate_cask_string("Expanded #{version}", "1.0.0", "x64", nil)
	defer delete(res2)
	testing.expect_value(t, res2, "Expanded 1.0.0")

	res3 := interpolate_cask_string("Escaped-Backslash \\\\#{version}", "1.0.0", "x64", nil)
	defer delete(res3)
	testing.expect_value(t, res3, "Escaped-Backslash \\\\1.0.0")

	res4 := interpolate_cask_string("Triple-Backslash \\\\\\#{version}", "1.0.0", "x64", nil)
	defer delete(res4)
	testing.expect_value(t, res4, "Triple-Backslash \\\\\\#{version}")
}

@(test)
test_preflight_block_opener_quotes_and_comments :: proc(t: ^testing.T) {
	fixture := `cask "test-block-detection" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    puts "do |foo|"
    puts " end"
    items = ["a", "b"]
    items.each do # comment on block opener
      File.write("#{staged_path}/inside_each.txt", "from each")
    end
    File.write("#{staged_path}/valid.txt", "valid")
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-block-detection")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 2)
	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "inside_each.txt")
		testing.expect_value(t, c.preflight_files[0].content, "from each")
		testing.expect_value(t, c.preflight_files[1].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[1].content, "valid")
	}
}

@(test)
test_preflight_platform_host_filtering :: proc(t: ^testing.T) {
	fixture := `cask "test-platform-filtering" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  on_macos do
    preflight do
      File.write("#{staged_path}/macos_outer.txt", "macos outer")
    end
  end

  on_linux do
    preflight do
      File.write("#{staged_path}/linux_outer.txt", "linux outer")
    end
  end

  preflight do
    on_macos do
      File.write("#{staged_path}/macos_inner.txt", "macos inner")
    end
    on_linux do
      File.write("#{staged_path}/linux_inner.txt", "linux inner")
    end
    if OS.mac?
      File.write("#{staged_path}/macos_if.txt", "macos if")
    end
    if OS.linux?
      File.write("#{staged_path}/linux_if.txt", "linux if")
    end
    File.write("#{staged_path}/common.txt", "common")
  end
end
`
	// parse_ruby_cask uses current_cask_host().os ("linux")
	c, ok := parse_ruby_cask(fixture, "test-platform-filtering")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 4)
	if len(c.preflight_files) == 4 {
		testing.expect_value(t, c.preflight_files[0].path, "linux_outer.txt")
		testing.expect_value(t, c.preflight_files[0].content, "linux outer")

		testing.expect_value(t, c.preflight_files[1].path, "linux_inner.txt")
		testing.expect_value(t, c.preflight_files[1].content, "linux inner")

		testing.expect_value(t, c.preflight_files[2].path, "linux_if.txt")
		testing.expect_value(t, c.preflight_files[2].content, "linux if")

		testing.expect_value(t, c.preflight_files[3].path, "common.txt")
		testing.expect_value(t, c.preflight_files[3].content, "common")
	}

	// Direct test passing target_os = "macos"
	files_macos := make([dynamic]cask.Preflight_File, context.temp_allocator)
	extract_preflight_file_writes(fixture, &files_macos, "macos")
	defer {
		for pf in files_macos {
			delete(pf.path)
			delete(pf.content)
		}
		delete(files_macos)
	}
	testing.expect_value(t, len(files_macos), 4)
	if len(files_macos) == 4 {
		testing.expect_value(t, files_macos[0].path, "macos_outer.txt")
		testing.expect_value(t, files_macos[1].path, "macos_inner.txt")
		testing.expect_value(t, files_macos[2].path, "macos_if.txt")
		testing.expect_value(t, files_macos[3].path, "common.txt")
	}
}

@(test)
test_preflight_write_file_options :: proc(t: ^testing.T) {
	fixture := `cask "test-write-file-options" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    write_file "#{staged_path}/default.txt", "default"
    write_file "#{staged_path}/no_newline.txt", "no_newline", append_newline: false
    write_file "#{staged_path}/no_overwrite.txt", "no_overwrite", overwrite: false
    write_file "#{staged_path}/both.txt", "both", append_newline: false, overwrite: false
    File.write("#{staged_path}/file_write.txt", "literal")
    write_file "#{staged_path}/heredoc_default.txt", <<~EOS
      first line
      second line
    EOS
    write_file "#{staged_path}/heredoc_no_nl.txt", <<~EOS, append_newline: false
      first line
      second line
    EOS
    write_file "#{staged_path}/heredoc_single_line_no_nl.txt", <<~EOS, append_newline: false
      single line
    EOS
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-write-file-options")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 8)
	if len(c.preflight_files) == 8 {
		// default write_file appends newline, no_overwrite is false
		testing.expect_value(t, c.preflight_files[0].path, "default.txt")
		testing.expect_value(t, c.preflight_files[0].content, "default\n")
		testing.expect_value(t, c.preflight_files[0].no_overwrite, false)

		// append_newline: false prevents appending newline
		testing.expect_value(t, c.preflight_files[1].path, "no_newline.txt")
		testing.expect_value(t, c.preflight_files[1].content, "no_newline")
		testing.expect_value(t, c.preflight_files[1].no_overwrite, false)

		// overwrite: false sets no_overwrite = true
		testing.expect_value(t, c.preflight_files[2].path, "no_overwrite.txt")
		testing.expect_value(t, c.preflight_files[2].content, "no_overwrite\n")
		testing.expect_value(t, c.preflight_files[2].no_overwrite, true)

		// both options together
		testing.expect_value(t, c.preflight_files[3].path, "both.txt")
		testing.expect_value(t, c.preflight_files[3].content, "both")
		testing.expect_value(t, c.preflight_files[3].no_overwrite, true)

		// File.write does not append newline and overwrite defaults to true (no_overwrite false)
		testing.expect_value(t, c.preflight_files[4].path, "file_write.txt")
		testing.expect_value(t, c.preflight_files[4].content, "literal")
		testing.expect_value(t, c.preflight_files[4].no_overwrite, false)

		// heredoc with default append_newline preserves trailing newline
		testing.expect_value(t, c.preflight_files[5].path, "heredoc_default.txt")
		testing.expect_value(t, c.preflight_files[5].content, "first line\nsecond line\n")
		testing.expect_value(t, c.preflight_files[5].no_overwrite, false)

		// heredoc with append_newline: false preserves internal newlines but omits final newline
		testing.expect_value(t, c.preflight_files[6].path, "heredoc_no_nl.txt")
		testing.expect_value(t, c.preflight_files[6].content, "first line\nsecond line")
		testing.expect_value(t, c.preflight_files[6].no_overwrite, false)

		// heredoc single line with append_newline: false omits final newline
		testing.expect_value(t, c.preflight_files[7].path, "heredoc_single_line_no_nl.txt")
		testing.expect_value(t, c.preflight_files[7].content, "single line")
		testing.expect_value(t, c.preflight_files[7].no_overwrite, false)
	}
}

@(test)
test_preflight_else_in_non_os_conditional :: proc(t: ^testing.T) {
	fixture := `cask "test-else-non-os" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  on_linux do
    preflight do
      if Hardware::CPU.arm?
        File.write("#{staged_path}/arm.txt", "arm")
      else
        File.write("#{staged_path}/intel.txt", "intel")
      end
    end
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-else-non-os")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	// Both branches of Hardware::CPU.arm? inside on_linux remain in linux os_scope
	testing.expect_value(t, len(c.preflight_files), 2)
	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "arm.txt")
		testing.expect_value(t, c.preflight_files[1].path, "intel.txt")
	}
}

@(test)
test_preflight_helpers_not_treated_as_preflight_decl :: proc(t: ^testing.T) {
	fixture := `cask "test-helpers" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight_helper do
    write_file "#{staged_path}/ignored1.txt", "ignored"
  end

  preflight_steps_helper do
    write_file "#{staged_path}/ignored2.txt", "ignored"
  end

  preflight do
    write_file "#{staged_path}/actual.txt", "actual"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-helpers")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "actual.txt")
		testing.expect_value(t, c.preflight_files[0].content, "actual\n")
	}
}

@(test)
test_preflight_non_os_elsif_restores_parent_scope :: proc(t: ^testing.T) {
	fixture := `cask "test-elsif" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  on_linux do
    preflight do
      if OS.mac?
        write_file "#{staged_path}/mac.txt", "mac"
      elsif Hardware::CPU.arm?
        write_file "#{staged_path}/linux_arm.txt", "linux arm"
      else
        write_file "#{staged_path}/linux_other.txt", "linux other"
      end
    end
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-elsif")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 2)
	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "linux_arm.txt")
		testing.expect_value(t, c.preflight_files[0].content, "linux arm\n")
		testing.expect_value(t, c.preflight_files[1].path, "linux_other.txt")
		testing.expect_value(t, c.preflight_files[1].content, "linux other\n")
	}
}

@(test)
test_preflight_brace_syntax_rejected_and_postflight_not_staged :: proc(t: ^testing.T) {
	fixture := `cask "test-brace" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight {
    write_file "#{staged_path}/ignored.txt", "ignored"
  }

  postflight do
    write_file "#{staged_path}/post.txt", "post"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-brace")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 0)
}

@(test)
test_preflight_do_token_boundary :: proc(t: ^testing.T) {
	fixture := `cask "test-do-boundary" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight download
    write_file "#{staged_path}/ignored.txt", "ignored"
  end

  preflight do
    write_file "#{staged_path}/valid.txt", "valid"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-do-boundary")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[0].content, "valid\n")
	}
}

@(test)
test_generic_heredoc_skipped_without_corrupting_scope :: proc(t: ^testing.T) {
	fixture := `cask "test-generic-heredoc" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  postflight do
    system_command "/bin/sh", args: ["-c", <<~EOS]
      if [ -d "/foo" ]; then
        preflight do
          write_file "#{staged_path}/evil.txt", "evil"
        end
      fi
    EOS
    write_file "#{staged_path}/post.txt", "post"
  end

  preflight do
    write_file "#{staged_path}/real.txt", "real"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-generic-heredoc")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "real.txt")
		testing.expect_value(t, c.preflight_files[0].content, "real\n")
	}
}

@(test)
test_preflight_quoted_content_with_heredoc_marker_and_comments :: proc(t: ^testing.T) {
	fixture := `cask "test-quotes-and-comments" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    write_file "#{staged_path}/quoted_shift.txt", "content with <<~EOS inside", overwrite: true
    write_file "#{staged_path}/comment_opts.txt", "comment test", overwrite: false # append_newline: false
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-quotes-and-comments")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 2)
	if len(c.preflight_files) == 2 {
		testing.expect_value(t, c.preflight_files[0].path, "quoted_shift.txt")
		testing.expect_value(t, c.preflight_files[0].content, "content with <<~EOS inside\n")
		testing.expect_value(t, c.preflight_files[0].no_overwrite, false)

		testing.expect_value(t, c.preflight_files[1].path, "comment_opts.txt")
		testing.expect_value(t, c.preflight_files[1].content, "comment test\n")
		testing.expect_value(t, c.preflight_files[1].no_overwrite, true)
	}
}

@(test)
test_postflight_file_write_heredoc_does_not_leak_into_preflight :: proc(t: ^testing.T) {
	fixture := `cask "test-postflight-heredoc" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  postflight do
    File.write "#{staged_path}/runner.sh", <<~EOS
      preflight do
        write_file "#{staged_path}/evil.txt", "evil"
      end
    EOS
    File.write("#{staged_path}/another.sh", <<~EOS)
      echo "hello"
    EOS
  end

  preflight do
    write_file "#{staged_path}/legit.txt", "legit"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-postflight-heredoc")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "legit.txt")
		testing.expect_value(t, c.preflight_files[0].content, "legit\n")
	}
}

@(test)
test_find_heredoc_terminator_offset_alignment :: proc(t: ^testing.T) {
	// Leading quote string before << operator to verify byte offset alignment
	line1 := `"prefix_with_quotes", <<~EOS`
	term1, ok1 := find_heredoc_terminator(line1)
	testing.expect(t, ok1, "heredoc should be detected after quoted prefix")
	testing.expect_value(t, term1, "EOS")

	line2 := `File.write("#{staged_path}/test", <<~'CUSTOM_TERM', overwrite: false)`
	term2, ok2 := find_heredoc_terminator(line2)
	testing.expect(t, ok2, "heredoc should be detected with custom terminator")
	testing.expect_value(t, term2, "CUSTOM_TERM")

	line3 := `x = "string with << inside" + " more"`
	_, ok3 := find_heredoc_terminator(line3)
	testing.expect(t, !ok3, "quoted << should not be treated as heredoc")
}

@(test)
test_preflight_unterminated_quote_does_not_panic :: proc(t: ^testing.T) {
	fixture := `cask "test-unterminated" do
  version "1.0.0"
  url "https://example.com/app.tar.gz"

  preflight do
    File.write("unterminated, <<~EOS)
      some body
    EOS
    write_file "#{staged_path}/valid.txt", "valid content"
    write_file "#{staged_path}/unterminated_content.txt", "unterminated
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-unterminated")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.txt")
		testing.expect_value(t, c.preflight_files[0].content, "valid content\n")
	}
}

@(test)
test_preflight_interpolated_path_traversal_rejected :: proc(t: ^testing.T) {
	fixture := `cask "test-interp-traversal" do
  version "../../evil"
  url "https://example.com/app.tar.gz"

  preflight do
    write_file "#{staged_path}/#{version}/app.desktop", "evil"
    write_file "#{staged_path}/valid.desktop", "good"
  end
end
`
	c, ok := parse_ruby_cask(fixture, "test-interp-traversal")
	testing.expect(t, ok, "parse_ruby_cask should succeed")
	defer destroy_ruby_cask(c)

	testing.expect_value(t, len(c.preflight_files), 1)
	if len(c.preflight_files) == 1 {
		testing.expect_value(t, c.preflight_files[0].path, "valid.desktop")
		testing.expect_value(t, c.preflight_files[0].content, "good\n")
	}
}


