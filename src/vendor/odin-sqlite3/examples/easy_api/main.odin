package easy_api

import sqlite "../.."
import sa "../../addons"
import "core:fmt"
import "core:mem" // needed only for the tracking allocator

Album :: struct {
	id:        u32 `sqlite:"AlbumId"`,
	title:     string `sqlite:"Title"`,
	// Not the best representation of an ID but it showcases that enums work
	artist_id: ArtistId `sqlite:"ArtistId"`,
}

ArtistId :: enum {
	AC_DC     = 1,
	Accept    = 2,
	Aerosmith = 3,
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

	fmt.printfln("default config: %#v\n", sa.config)

	// actual example code
	sa.config.log_level = .Info // if nil, does not log
	sa.config.extra_runtime_checks = true // does extra checks on enum values

	db: ^sqlite.Connection
	if rc := sqlite.open("./sample.sqlite", &db); rc != .Ok {
		fmt.panicf("failed to open database. result code {}", rc)
	}

	fmt.printfln("connected to database\n")
	defer {
		sqlite.close(db)
		fmt.printfln("\nconnection closed")
	}

	// query example
	{
		fmt.println("======= query example begin =======\n")
		defer fmt.println("\n======= query example end =======")

		albums: [dynamic]Album
		defer {
			for album in albums {
				delete(album.title)
			}

			delete(albums)
		}

		if rc := sa.query(
			db,
			&albums,
			"select AlbumId, Title, ArtistId from Album where ArtistId <= ? limit ?",
			{{1, i64(ArtistId.Aerosmith)}, {2, i32(5)}},
		); rc != .Ok {
			fmt.panicf("failed to execute query. result code {}", rc)
		}

		fmt.printfln("albums: %#v", albums)
	}

	// execute example. this is a type of query that you want to update/insert/delete stuff
	// but not return data.
	// p.s. I know that the query below does not mutate the data - I don't want the data to be changed
	{
		fmt.println("\n======= execute example begin =======\n")
		defer fmt.println("\n======= execute example end =======")

		if rc := sa.execute(db, "select 1"); rc != .Ok {
			fmt.panicf("failed to execute query. result code {}", rc)
		}
	}
}
