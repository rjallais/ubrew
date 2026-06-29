package c_api

import sqlite "../.."
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem" // needed only for the tracking allocator
import "core:strings"

Album :: struct {
	id:        int,
	title:     string,
	artist_id: int,
}

main :: proc() {
	// setup tracking allocator. not necessary
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)

	context.allocator = mem.tracking_allocator(&track)
	defer {
		if len(track.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
			for entry in track.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	// actual example code
	db: ^sqlite.Connection
	if rc := sqlite.open("./sample.sqlite", &db); rc != .Ok {
		fmt.panicf("failed to open database. result code {}", rc)
	}

	fmt.println("connected to database\n")
	defer {
		sqlite.close(db)
		fmt.println("\nconnection closed")
	}

	// query example
	{
		fmt.println("======= query example begin =======\n")
		defer fmt.println("\n======= query example end =======")

		sql: cstring = "select AlbumId, Title, ArtistId from Album where ArtistId=? limit ?"
		stmt: ^sqlite.Statement
		if rc := sqlite.prepare_v2(db, sql, c.int(len(sql)), &stmt, nil); rc != .Ok {
			fmt.panicf("failed to prepare statement. result code: {}", rc)
		}

		// free statement after we're done with it
		defer sqlite.finalize(stmt)

		// set parameters
		if rc := sqlite.bind_int(stmt, param_idx = 1, param_value = 1); rc != .Ok { 	// sets ArtistId to 1
			fmt.panicf("failed to bind value to ArtistId. result code: {}", rc)
		}

		if rc := sqlite.bind_int(stmt, param_idx = 2, param_value = 3); rc != .Ok { 	// sets limit to 3
			fmt.panicf("failed to bind value to limit. result code: {}", rc)
		}

		fmt.printfln("prepared sql: {}\n", sqlite.expanded_sql(stmt))

		albums: [dynamic]Album
		defer {
			for album in albums {
				delete(album.title)
			}

			delete(albums)
		}

		for sqlite.step(stmt) == .Row {
			album := Album {
				id        = int(sqlite.column_int(stmt, 0)),
				title     = strings.clone_from(sqlite.column_text(stmt, 1)),
				artist_id = int(sqlite.column_int(stmt, 2)),
			}

			append(&albums, album)
		}

		fmt.printfln("albums: %#v", albums)
	}

	// exec example
	{
		fmt.println("\n======= exec example begin =======")
		defer fmt.println("\n======= exec example end =======")

		err: cstring
		num_results := 0
		sql: cstring = "select ArtistId, AlbumId, Title from Album limit 5"
		handle_results := proc "c" (
			ctx: rawptr,
			argc: c.int,
			argv: [^]cstring,
			col_names: [^]cstring,
		) -> c.int {
			context = runtime.default_context()

			num_results_ptr := cast(^int)ctx
			defer num_results_ptr^ += 1

			fmt.println("\nprinting values for row", num_results_ptr^)

			args := argv[:int(argc)]
			columns := col_names[:int(argc)]

			for arg, i in args {
				fmt.println(columns[i], "=", arg)
			}

			return 0

		}

		if rc := sqlite.exec(db, sql, handle_results, &num_results, &err); rc != .Ok {
			fmt.printfln("failed to execute query. err: {}", err)
			sqlite.free(cast(rawptr)err)
		}

		fmt.printfln("\ngot a total of {} rows", num_results)
	}
}
