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

Artifact :: union {
	App_Artifact,
	Font_Artifact,
	Binary_Artifact,
	Wallpaper_Artifact,
	AppImage_Artifact,
	Generic_Artifact,
}

Cask :: struct {
    token:     string,
    name:      string,
    version:   string,
    url:       string,
    sha256:    string,
    homepage:  string,
    artifacts: []Artifact,
}
