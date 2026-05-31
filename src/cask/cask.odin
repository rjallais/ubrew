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

Artifact :: union {
    App_Artifact,
    Font_Artifact,
    Binary_Artifact,
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
