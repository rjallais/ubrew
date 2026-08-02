package installer

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// JWS_Header represents the parsed header of a JSON Web Signature (JWS).
JWS_Header :: struct {
	alg: string,
	typ: string,
	kid: string,
}

base64url_decode :: proc(input: string, allocator := context.temp_allocator) -> (string, bool) {
	if len(input) == 0 do return "", false
	s, _ := strings.replace_all(input, "-", "+", context.temp_allocator)
	s, _ = strings.replace_all(s, "_", "/", context.temp_allocator)

	pad := (4 - (len(s) % 4)) % 4
	switch pad {
	case 1: s = fmt.tprintf("%s=", s)
	case 2: s = fmt.tprintf("%s==", s)
	case 3: s = fmt.tprintf("%s===", s)
	}

	decoded_bytes, err := base64.decode(s, allocator = allocator)
	if err != nil do return "", false
	return string(decoded_bytes), true
}

// verify_jws_token checks a raw JWS string (header.payload.signature) for
// valid base64url structure, a supported algorithm (RS256 / ES256 / PS256),
// and a payload that CONTAINS the expected_sha256.
//
// SECURITY NOTE: this is an attestation-hash gate, NOT cryptographic
// signature verification. The signature segment is only checked for
// presence — it is never verified against a public key, so a forged
// signature on a structurally valid token passes. Do not use this function
// as the sole integrity gate for downloaded binaries. expected_sha256 is
// mandatory: a caller that cannot supply the expected hash gets false, so a
// missing expectation can never silently widen the trust decision.
verify_jws_token :: proc(token: string, expected_sha256: string) -> bool {
	if len(token) == 0 do return false
	if len(expected_sha256) == 0 do return false

	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 {
		return false
	}

	header_json, hok := base64url_decode(parts[0], context.temp_allocator)
	if !hok do return false

	val, err := json.parse(transmute([]u8)header_json)
	if err != nil do return false
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj do return false

	alg_str := ""
	if alg_val, ok := obj["alg"]; ok {
		if s, s_ok := alg_val.(json.String); s_ok {
			alg_str = string(s)
		}
	}

	// Supported Homebrew JWS signing algorithms: RS256, ES256, PS256
	if alg_str != "RS256" && alg_str != "ES256" && alg_str != "PS256" {
		return false
	}

	// The expected hash must be present in the payload; a mismatch is a hard
	// rejection (there is no non-empty-signature fallback).
	payload_data, pok := base64url_decode(parts[1], context.temp_allocator)
	if !pok do return false
	if !strings.contains(payload_data, expected_sha256) do return false

	// Structural check only: a signature segment must be present.
	return len(parts[2]) > 0
}
