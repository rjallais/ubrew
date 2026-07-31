# Agent Instructions for `ubrew`

This file lists the most critical, repo-specific, and non-obvious gotchas that an AI agent is highly likely to miss without help. Keep this compact and verified.

---

## 1. Odin Language & Memory Gotchas (CRITICAL)

* **Named Return Value Optimization Bug**: Avoid named return values (e.g., `(names: [dynamic]string, err: bool)`) combined with local `make()` re-assignments in `trusted_taps_load`. It can cause compilation discrepancies or uninitialized allocator segfaults on some platforms/compiler versions. Use standard, explicit local variables.
* **Double-Frees on Builder Views**: `strings.to_string(builder)` returns a view of the builder's internal buffer, NOT an allocated string. Calling `delete(result)` after `strings.builder_destroy(&builder)` triggers a fatal double-free segfault (`malloc: pointer being freed was not allocated`).
* **`os.read_directory_by_path` respects the passed allocator** (Odin dev-2026-07+): `read_directory_by_path` clones entries using the passed allocator via `file_info_clone(fi, allocator)` and clones the result slice via `slice.clone(dfi[:], allocator)`. Always pair with `defer os.file_info_slice_delete(infos, allocator)`. The internal temp arena guard is only for the iteration backing buffer — the data itself is on the allocator you passed. This works correctly with `context.allocator`. The `context.temp_allocator` pattern from earlier Odin versions is no longer needed and passing it will cause invalid-free crashes if `file_info_slice_delete` is called or leaks if it's omitted.
* **`os.read_entire_file` + `delete` allocator mismatch**: `os.read_entire_file(file, allocator)` allocates the returned `[]u8` with the passed allocator. The corresponding `delete(data)` on it defaults to `context.allocator` — if you passed a different allocator (e.g. `context.temp_allocator`), the `delete` will call `free()` on a non-heap pointer, SIGABRTing with `free(): invalid pointer`. Always match: `data := os.read_entire_file(path, allocator) or_return; defer delete(data, allocator)`.
* **Slice Literal Limitations**: Odin does not support inline array literals in range headers (e.g., `for prefix in []string{...}`). Declare slice variables separately.
* **Struct Definitions**: `type X :: struct {}` is illegal in Odin. Just write `X :: struct {}`.
* **Dynamic Array Doubling**: Using the 3-arg `make([dynamic]T, len, allocator)` pre-allocates `len` default-zero elements. Subsequent `append()` calls will add elements *after* those, doubling the expected length. Use the 4-arg capacity-only version instead: `make([dynamic]T, 0, len, allocator)`.

---

## 2. Curl Speculative Probing Gotchas

* **Benchmarking expected 404s**: speculative tap list checks or branch detection (e.g., in `client.odin` and `tap.odin`) should never use `-S` / `--show-error` (i.e. use `-sfL` instead of `-sfSL` or `-fsSL`). This completely silences expected and benign 404s from polluting `stderr`.
* **Parallel vs. Single Downloads**:
  * For **single downloads** (the 99% common case), use curl's `-#` (`--progress-bar`) *without* `--parallel` to render a beautiful, single-line hash-mark progress bar.
  * For **multi-package batch downloads**, use curl's parallel silent mode (`-sL --no-progress-meter --parallel`) to avoid printing cluttered, multi-line progress headers.

---

## 3. Toolchain & Platform Quirks

* **Darwin-Specific `clonefile`**: `clonefile` in `src/platform/copy.odin` is compiled only when `ODIN_OS == .Darwin`. Redefine its c-link signature as `clonefile :: proc "c" (src: cstring, dst: cstring, flags: c.uint) -> c.int` so that cstrings can be passed directly, preventing compile-time type assignment failures on macOS runners.
* **Statically Linked Binaries**: For Go/Rust tools (like `podman-tui`), `patchelf --print-rpath` writes noisy `cannot find section '.dynamic'` errors to `stderr`. Always redirect `stderr` to `/dev/null` in `exec_cmd_capture` to keep the CLI clean.
* **No `--version` verification on target binaries**: Do not automatically verify installations by running the binary with `--version`. Many CLI tools (such as `podman-tui` or daemon-starters) either do not support `--version` or require subcommands, causing false-positive installation check failures.

---

## 4. Tap Trust & Verification

* **Tap Trust**: Third-party taps (not starting with `homebrew/`) are untrusted by default. To tap or query them, they must first be explicitly trusted via `ubrew tap trust <user/repo>`.
* **CI Environment Prep**: On a clean virtual machine runner (e.g. GitHub Actions), ensure the following are run before any tests:
  1. Set up own folder permissions: `sudo mkdir -p /opt/ubrew && sudo chown -R $USER /opt/ubrew`
  2. Build the binary (e.g., `mise run build`) to ensure the `./ubrew` executable is generated
  3. Pre-trust testing taps: `./ubrew tap trust ublue-os/tap` and `./ubrew tap trust justrach/nanobrew`
  4. Expose ubrew prefix path: `echo "/opt/ubrew/prefix/bin" >> $GITHUB_PATH`
