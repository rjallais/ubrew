// DAG-aware parallel formula install
//
// Uses core:thread.Pool with dynamic task submission.  Each formula node
// starts with dep_remaining = number of dependencies (in this batch).  When a
// task finishes, it decrements its DEPENDENTS' remaining-dep counts; any that
// reach 0 are submitted to the pool.
//
// Thread-safety:
//   - install_bottle / install_source use filesystem paths unique per
//     package (different keg dirs, different store entries), so they
//     don't clobber each other.
//   - Symlinks under PREFIX/bin are per binary name — no two packages
//     share a binary name, so there is no race on the link target.
//     HOMEBREW_PREFIX file links (link_keg_files) are per-package file
//     sets; two formulae rarely ship the same top-level file name, but
//     if they do the `overwrite=false` conflict path in link_one
//     serialises via filesystem atomicity (os.remove+symlink) — a lost
//     race would be retried on next `ubrew link`.
//   - history.load + history.save are serialised under dag_history_mutex
//     because the file is a single JSON blob.  remove_formula (called on
//     forced reinstalls) serialises its own history writes under the same
//     mutex.
//   - The error flag is set under a mutex and checked once after the pool
//     finishes.

package main

import "core:fmt"
import "base:intrinsics"
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
	dep_remaining:    i32,  // atomic; dep count that must reach 0 before this can run
	skipped:          i32,  // atomic; 1 = a dependency failed, do not install
	dependents_start: int,  // first index in dependents_flat
	dependents_count: int,  // number of dependent entries
}

// Per-run state threaded into every task.
DAG_State :: struct {
	formulas:          []formula.Formula,
	force_flags:       []bool,
	on_request_flags:  []bool,
	nodes:             []Formula_DAG_Node,
	dependents_flat:   []int,
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

	node := &ctx.nodes[idx]

	// If a dependency failed, skip this formula entirely.
	if intrinsics.atomic_load(&node.skipped) != 0 {
		dag_notify_dependents(ctx, idx)
		return
	}

	// Snapshot the old version BEFORE installing, so we can distinguish
	// install from upgrade correctly in history.
	old_version := ""
	if os.is_dir(fmt.tprintf("%s/%s", installer.CELLAR_DIR, f.name)) {
		if keg_path, ok := exec_formula_latest_keg(f.name); ok {
			if idx := strings.last_index(keg_path, "/"); idx >= 0 {
				old_version = strings.clone(keg_path[idx+1:], context.temp_allocator)
			}
		}
	}

	// Handle force reinstall: remove the existing keg + record uninstall
	// history under dag_history_mutex.
	if force {
		_ = unlink_formula_bins(f.name)
		formula_dir := fmt.tprintf("%s/%s", installer.CELLAR_DIR, f.name)
		// brew-parity: drop the shared prefix's links and the linked-keg
		// record before the keg goes away, so a failed reinstall never
		// leaves dangling links behind.
		formula_marker := fmt.tprintf("%s/%s/", installer.CELLAR_DIR, f.name)
		listing_alloc := context.allocator
		if v_infos, v_err := os.read_directory_by_path(formula_dir, -1, listing_alloc); v_err == nil {
			defer os.file_info_slice_delete(v_infos, listing_alloc)
			for v_info in v_infos {
				if v_info.type == .Directory && is_version_dir(v_info.name) {
					unlinked, unlink_failed := 0, 0
					installer.unlink_keg_files(v_info.fullpath, installer.HOMEBREW_PREFIX, formula_marker, false, &unlinked, &unlink_failed)
					if unlink_failed > 0 {
						fmt.printf("ubrew: warning: %d file(s) failed to unlink for %s/%s in shared prefix\n", unlink_failed, f.name, v_info.name)
					}
					if installer.PREFIX != installer.HOMEBREW_PREFIX {
						unlinked, unlink_failed = 0, 0
						installer.unlink_keg_files(v_info.fullpath, installer.PREFIX, formula_marker, false, &unlinked, &unlink_failed)
						if unlink_failed > 0 {
							fmt.printf("ubrew: warning: %d file(s) failed to unlink for %s/%s in ubrew prefix\n", unlink_failed, f.name, v_info.name)
						}
					}
				}
			}
		}
		installer.remove_linked_keg_record(f.name)
		os.remove_all(formula_dir)
		unlink_formula_opt_links(f.name)

		sync.guard(&dag_history_mutex)
		h_names, h_entries := history.load(context.allocator)
		defer history.destroy(&h_names, &h_entries)
		history.record_uninstall(&h_names, &h_entries, f.name, f.version)
		history.save(h_names, h_entries)
	}

	// Install the formula.
	result := install_formula_kernel(f^, ctx.build_from_source, force, on_request)

	did_install := false
	switch result {
	case .Failed:
		sync.guard(&ctx.error_mutex)
		ctx.error_flag = true
		intrinsics.atomic_store(&node.skipped, i32(1))  // dependents will skip themselves
	case .NoOp:
		// Already installed — skip history.
	case .Success:
		did_install = true
	}

	// Record install/upgrade history under dag_history_mutex.
	if did_install {
		sync.guard(&dag_history_mutex)

		h_names, h_entries := history.load(context.allocator)
		defer history.destroy(&h_names, &h_entries)

		if old_version != "" && old_version != f.version {
			history.record_upgrade(&h_names, &h_entries, f.name, f.version, old_version)
		} else {
			history.record_install(&h_names, &h_entries, f.name, f.version)
		}
		history.save(h_names, h_entries)
	}

	// Notify dependents: decrement dep_remaining; submit if zero.
	dag_notify_dependents(ctx, idx)
}

// dag_notify_dependents decrements dep_remaining on every node that depends
// on idx and submits any that reach 0.
dag_notify_dependents :: proc(ctx: ^DAG_State, idx: int) {
	node := &ctx.nodes[idx]
	for i in 0 ..< node.dependents_count {
		dep_idx := ctx.dependents_flat[node.dependents_start + i]
		if intrinsics.atomic_load(&node.skipped) != 0 {
			// A failed dependency: this dependent must not install either.
			// The flag is set before the counter decrement so it is visible
			// when the dependent is submitted (atomic ordering guarantees it).
			intrinsics.atomic_store(&ctx.nodes[dep_idx].skipped, i32(1))
		}
		old := intrinsics.atomic_sub(&ctx.nodes[dep_idx].dep_remaining, i32(1))
		if old == 1 {
			// All dependencies satisfied — submit to pool.
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

	// Fast path for single package: avoid thread pool initialization and thread spawning overhead
	if n == 1 {
		dummy_nodes := [1]Formula_DAG_Node{}
		ctx := DAG_State {
			formulas          = formulas,
			force_flags       = force_flags,
			on_request_flags  = on_request_flags,
			nodes             = dummy_nodes[:],
			dependents_flat   = nil,
			pool              = nil,
			build_from_source = build_from_source,
		}
		t := thread.Task {
			data = &ctx,
			user_index = 0,
		}
		dag_formula_task(t)
		return !ctx.error_flag
	}

	// Size the worker pool.
	cores := 4
	if _, logical, ok := info.cpu_core_count(); ok {
		cores = logical
	}
	num_workers := max(1, min(cores, n))

	// ── Build inverted adjacency: dependents lists ──
	//
	// dep_indices[i] = [d_0, d_1, ...] means "i depends on d_0, d_1".
	// We invert so that each node d knows which nodes depend on it.

	total_deps := 0
	for i in 0 ..< n do total_deps += len(dep_indices[i])

	nodes := make([]Formula_DAG_Node, n, context.allocator)
	dependents_flat := make([]int, total_deps, context.allocator)

	// Pass 1: count deps per node (for dep_remaining) and dependent count.
	for i in 0 ..< n {
		nodes[i].dep_remaining = i32(len(dep_indices[i]))
	}
	for i in 0 ..< n {
		for d in dep_indices[i] {
			nodes[d].dependents_count += 1
		}
	}

	// Pass 2: assign start offsets using the counts from pass 1.
	cursor := 0
	for i in 0 ..< n {
		nodes[i].dependents_start = cursor
		cursor += nodes[i].dependents_count
		nodes[i].dependents_count = 0  // reset to use as fill cursor below
	}

	// Pass 3: fill the dependent lists.  dependents_count doubles as fill
	// cursor during this pass.
	for i in 0 ..< n {
		for d in dep_indices[i] {
			pos := nodes[d].dependents_start + nodes[d].dependents_count
			dependents_flat[pos] = i
			nodes[d].dependents_count += 1
		}
	}

	// Prepare pool.
	pool: thread.Pool
	ctx := DAG_State {
		formulas          = formulas,
		force_flags       = force_flags,
		on_request_flags  = on_request_flags,
		nodes             = nodes,
		dependents_flat   = dependents_flat,
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
	delete(dependents_flat)

	return !ctx.error_flag
}