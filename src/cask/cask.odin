package cask

App_Artifact :: struct {
    name: string,
}

Font_Artifact :: struct {
    name: string,
}

Binary_Artifact :: struct {
    source: string,
    target: string,
}

Wallpaper_Artifact :: struct {
	glob: string,
}

AppImage_Artifact :: struct {
	source: string,
	target: string,
}

Generic_Artifact :: struct {
	source: string,
	target: string,
}

Preflight_File :: struct {
	path:    string,
	content: string,
}

Artifact :: union {
	App_Artifact,
	Font_Artifact,
	Binary_Artifact,
	Wallpaper_Artifact,
	AppImage_Artifact,
	Generic_Artifact,
}

Cask :: struct {
    token:           string,
    name:            string,
    desc:            string,
    version:         string,
    url:             string,
    sha256:          string,
    homepage:        string,
    artifacts:       []Artifact,
    preflight_files: []Preflight_File,
    auto_updates:    bool,
}
