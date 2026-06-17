package history

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

HISTORY_FILE :: "/opt/ubrew/db/history.json"

Action :: enum {
	Install,
	Upgrade,
	Downgrade,
	Reinstall,
	Uninstall,
}

action_strings :: [Action]string {
	.Install =    "install",
	.Upgrade =    "upgrade",
	.Downgrade =  "downgrade",
	.Reinstall =  "reinstall",
	.Uninstall =  "uninstall",
}

action_string :: proc(a: Action) -> string {
	s := action_strings
	return s[a]
}

NO_FROM_VERSION :: ""
NO_FROM_REVISION :: -1

Entry :: struct {
	version:       string,
	revision:      int,
	action:        string,
	timestamp:     string,
	from_version:  string,
	from_revision: int,
}

has_from_version :: proc(e: Entry) -> bool {
	return len(e.from_version) > 0
}

has_from_revision :: proc(e: Entry) -> bool {
	return e.from_revision != NO_FROM_REVISION
}

iso8601_now :: proc() -> string {
	t := time.now()
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
		year, int(month), day, hour, minute, second)
}

json_escape :: proc(b: ^strings.Builder, s: string) {
	for c in s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:      strings.write_rune(b, c)
		}
	}
}

write_entry_json :: proc(b: ^strings.Builder, e: Entry) {
	strings.write_string(b, "{\"version\":\"")
	json_escape(b, e.version)
	strings.write_string(b, "\",\"revision\":")
	fmt.sbprintf(b, "%d", e.revision)
	strings.write_string(b, ",\"action\":\"")
	json_escape(b, e.action)
	strings.write_string(b, "\",\"timestamp\":\"")
	json_escape(b, e.timestamp)
	strings.write_string(b, "\"")
	if has_from_version(e) {
		strings.write_string(b, ",\"from_version\":\"")
		json_escape(b, e.from_version)
		strings.write_rune(b, '"')
	}
	if has_from_revision(e) {
		strings.write_string(b, ",\"from_revision\":")
		fmt.sbprintf(b, "%d", e.from_revision)
	}
	strings.write_rune(b, '}')
}

load :: proc(allocator := context.allocator) -> (names: [dynamic]string, entries_map: map[string][dynamic]Entry) {
	names = make([dynamic]string, allocator)
	entries_map = make(map[string][dynamic]Entry, allocator)

	data, rerr := os.read_entire_file(HISTORY_FILE, allocator)
	if rerr != nil {
		return
	}
	defer delete(data)

	content := strings.trim_space(string(data))
	if len(content) == 0 { return }

	val, perr := json.parse(data)
	if perr != nil {
		fmt.printf("Warning: failed to parse history.json: %v\n", perr)
		return
	}
	defer json.destroy_value(val)

	root, is_obj := val.(json.Object)
	if !is_obj { return }

	pkgs_val, has_pkgs := root["packages"]
	if !has_pkgs { return }
	pkgs_obj, is_obj2 := pkgs_val.(json.Object)
	if !is_obj2 { return }

	for pkg_name, pkg_val in pkgs_obj {
		pkg_arr, is_arr := pkg_val.(json.Array)
		if !is_arr { continue }
		entries := make([dynamic]Entry, allocator)
		for item in pkg_arr {
			item_obj, is_obj3 := item.(json.Object)
			if !is_obj3 { continue }
			e := Entry{}
			if v, ok := item_obj["version"]; ok {
				if s, ok2 := v.(json.String); ok2 { e.version = strings.clone(string(s), allocator) }
			}
			if v, ok := item_obj["revision"]; ok {
				if n, ok2 := v.(json.Integer); ok2 { e.revision = int(n) }
			}
			if v, ok := item_obj["action"]; ok {
				if s, ok2 := v.(json.String); ok2 { e.action = strings.clone(string(s), allocator) }
			}
			if v, ok := item_obj["timestamp"]; ok {
				if s, ok2 := v.(json.String); ok2 { e.timestamp = strings.clone(string(s), allocator) }
			}
			if v, ok := item_obj["from_version"]; ok {
				if s, ok2 := v.(json.String); ok2 { e.from_version = strings.clone(string(s), allocator) }
			}
			if v, ok := item_obj["from_revision"]; ok {
				if n, ok2 := v.(json.Integer); ok2 { e.from_revision = int(n) }
			}
			append(&entries, e)
		}
		cloned_name := strings.clone(pkg_name, allocator)
		entries_map[cloned_name] = entries
		append(&names, cloned_name)
	}
	return
}

save :: proc(names: [dynamic]string, entries_map: map[string][dynamic]Entry) -> bool {
	b, berr := strings.builder_make(context.allocator)
	if berr != nil {
		fmt.printf("Warning: failed to create string builder for history: %v\n", berr)
		return false
	}
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "{\"packages\":{")

	first_pkg := true
	for name in names {
		entries, ok := entries_map[name]
		if !ok { continue }

		if !first_pkg {
			strings.write_rune(&b, ',')
		}
		first_pkg = false

		strings.write_rune(&b, '"')
		json_escape(&b, name)
		strings.write_string(&b, "\":[")

		first_entry := true
		for e in entries {
			if !first_entry {
				strings.write_rune(&b, ',')
			}
			first_entry = false
			write_entry_json(&b, e)
		}

		strings.write_string(&b, "]}")
	}

	strings.write_string(&b, "}\n")

	dir := "/opt/ubrew/db"
	os.make_directory_all(dir, os.perm(0o755))

	output := strings.to_string(b)
	werr := os.write_entire_file_from_string(HISTORY_FILE, output)
	if werr != nil {
		fmt.printf("Warning: failed to write history to %s: %v\n", HISTORY_FILE, werr)
		return false
	}
	return true
}

record :: proc(names: ^[dynamic]string, entries_map: ^map[string][dynamic]Entry,
               name: string, version: string, action: Action,
               from_version: string = NO_FROM_VERSION, from_revision: int = NO_FROM_REVISION,
               allocator := context.allocator) {
	entry := Entry{
		version =       version,
		revision =      0,
		action =        action_string(action),
		timestamp =     iso8601_now(),
		from_version =  from_version,
		from_revision = from_revision,
	}

	if existing, ok := entries_map^[name]; ok {
		append(&existing, entry)
		entries_map^[name] = existing
	} else {
		entries := make([dynamic]Entry, allocator)
		append(&entries, entry)
		entries_map^[name] = entries
		append(names, strings.clone(name, allocator))
	}
}

record_install :: proc(names: ^[dynamic]string, entries_map: ^map[string][dynamic]Entry,
                       name: string, version: string, allocator := context.allocator) {
	record(names, entries_map, name, version, .Install, allocator = allocator)
}

record_upgrade :: proc(names: ^[dynamic]string, entries_map: ^map[string][dynamic]Entry,
                       name: string, version: string, from_ver: string, from_rev: int = 0,
                       allocator := context.allocator) {
	record(names, entries_map, name, version, .Upgrade, from_ver, from_rev, allocator)
}

record_uninstall :: proc(names: ^[dynamic]string, entries_map: ^map[string][dynamic]Entry,
                         name: string, version: string, allocator := context.allocator) {
	record(names, entries_map, name, version, .Uninstall, allocator = allocator)
}

destroy :: proc(names: ^[dynamic]string, entries_map: ^map[string][dynamic]Entry) {
	for name, entries in entries_map {
		delete(entries)
		delete_key(entries_map, name)
	}
	delete(names[:])
}
