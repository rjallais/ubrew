// DAG-aware parallel formula install
//
// Uses core:thread.Pool with dynamic task submission.  Each formula node
// starts with dep_remaining = number of dependencies (in this batch).  When a
// task finishes, it decrements dependents' counters; any that reach 0 are
// submitted to the pool.  Casks (no cross-deps) run in a second wave.
//
// Thread-safety:
//   - install_bottle / install_source use filesystem paths unique per
//     package (different keg dirs, different store entries), so they
//     don't clobber each other.
//   - Symlinks under PREFIX/bin are per binary name — no two packages
//     share a binary name, so there is no race on the link target.
//   - history.load + history.save are serialised under dag_history_mutex
//     because the file is a single JSON blob.
//   - The error flag is set under a mutex and checked once after the pool
//     finishes.

package main

import "core:fmt"
import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/info"
import "core:thread"
import "formula"
import "history"
import "installer"

// ── DAG node ─────────────────────────────────────────────────────────────

Formula_DAG_Node :: struct {
	dep_remaining: i32,   // atomic; dep count that must reach 0 before this can run
	deps_start:    int,   // first index in deps_flat
	deps_count:    int,   // number of dep entries
}

// Per-run state threaded into every task.
DAG_State :: struct {
	formulas:          []formula.Formula,
	force_flags:       []bool,
	on_request_flags:  []bool,
	nodes:             []Formula_DAG_Node,
	deps_flat:         []int,
	pool:              ^thread.Pool,
	error_flag:        bool,
	error_mutex:       sync.Mutex,
	build_from_source: bool,
}

// Package-level mutex for serialising history file access.
@(private)
dag_history_mutex: sync.Mutex

// ── Task proc ────────────────────────────────────────────────────────────

dag_formula_task :: proc(t: thread.Task) {
	ctx := cast(^DAG_State)t.data
	idx := cast(int)t.user_index

	f := &ctx.formulas[idx]
	force := ctx.force_flags[idx]
	on_request := ctx.on_request_flags[idx]

	// Install the formula (download already done).
	result := install_formula_kernel(f^, ctx.build_from_source, force, on_request)

	switch result {
	case .Failed:
		sync.guard(&ctx.error_mutex)
		ctx.error_flag = true
	case .NoOp:
		// Already installed — skip history, but still drain dependents.
	case .Success:
		// Record history under mutex.
		record_formula_history(f.name, f.version)
	}

	// Decrement dependents; schedule newly-ready nodes.
	node := &ctx.nodes[idx]
	for i in 0 ..< node.deps_count {
		dep_idx := ctx.deps_flat[node.deps_start + i]
		old := intrinsics.atomic_sub(&ctx.nodes[dep_idx].dep_remaining, i32(1))
		if old == 1 {
			thread.pool_add_task(ctx.pool, context.allocator, dag_formula_task, ctx, dep_idx)
		}
	}
}

// ── Entry point ──────────────────────────────────────────────────────────

run_parallel_formula_install :: proc(
	formulas: []formula.Formula,
	force_flags: []bool,
	on_request_flags: []bool,
	dep_indices: [][]int,   // dep_indices[i] lists deps by their *index in formulas*
	build_from_source: bool,
) -> bool {
	n := len(formulas)
	if n == 0 do return true

	// Size the worker pool.
	logical_cores := 4
	if physical, logical, ok := info.cpu_core_count(); ok {
		logical_cores = logical
	}
	num_workers := max(1, min(logical_cores, n))

	// Flatten dep lists & init nodes.
	total_deps := 0
	for i in 0 ..< n do total_deps += len(dep_indices[i])

	nodes := make([]Formula_DAG_Node, n, context.allocator)
	deps_flat := make([]int, total_deps, context.allocator)
	cursor := 0
	for i in 0 ..< n {
		nodes[i].dep_remaining = i32(len(dep_indices[i]))
		nodes[i].deps_start = cursor
		nodes[i].deps_count = len(dep_indices[i])
		for d in dep_indices[i] {
			deps_flat[cursor] = d
			cursor += 1
		}
	}

	// Prepare pool.
	pool: thread.Pool
	ctx := DAG_State {
		formulas          = formulas,
		force_flags       = force_flags,
		on_request_flags  = on_request_flags,
		nodes             = nodes,
		deps_flat         = deps_flat,
		pool              = &pool,
		build_from_source = build_from_source,
	}

	thread.pool_init(&pool, context.allocator, num_workers)
	thread.pool_start(&pool)

	// Seed: nodes whose deps are already zero.
	for i in 0 ..< n {
		if nodes[i].dep_remaining == 0 {
			thread.pool_add_task(&pool, context.allocator, dag_formula_task, &ctx, i)
		}
	}

	thread.pool_finish(&pool)
	thread.pool_destroy(&pool)

	delete(nodes)
	delete(deps_flat)

	return !ctx.error_flag
}

// ── History helper (called under dag_history_mutex) ──────────────────────

record_formula_history :: proc(name, version: string) {
	sync.guard(&dag_history_mutex)

	h_names, h_entries := history.load(context.allocator)
	defer history.destroy(&h_names, &h_entries)

	is_upgrade := false
	old_version := ""
	cellar_dir := fmt.tprintf("%s/%s", installer.CELLAR_DIR, name)
	if os.is_dir(cellar_dir) {
		is_upgrade = true
		if keg_path, ok := exec_formula_latest_keg(name); ok {
			if idx := strings.last_index(keg_path, "/"); idx >= 0 {
				old_version = strings.clone(keg_path[idx+1:], context.temp_allocator)
			}
		}
	}

	if is_upgrade && old_version != "" {
		history.record_upgrade(&h_names, &h_entries, name, version, old_version)
	} else {
		history.record_install(&h_names, &h_entries, name, version)
	}
	history.save(h_names, h_entries)
}