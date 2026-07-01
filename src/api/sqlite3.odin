package api

import "core:c"
import fts "../vendor/odin-sqlite3"

// ----------------------------------------------------------------
// Re-exported types from the vendored odin-sqlite3 community bindings
// ----------------------------------------------------------------
Connection          :: fts.Connection
Statement           :: fts.Statement
Result_Code         :: fts.Result_Code
Destructor          :: fts.Destructor
Destructor_Behavior :: fts.Destructor_Behavior
Backup              :: fts.Backup
Blob                :: fts.Blob

// Open flags (kept as raw i32 for bitwise-OR compatibility)
SQLITE_OPEN_READONLY  :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE    :: 0x00000004
SQLITE_OPEN_NOMUTEX   :: 0x00008000

// Re-export useful functions under the old api.* namespace so client.odin
// can use them without a separate import alias.
// (client.odin now imports fts directly for SQLite calls; these re-exports
//  are for other packages that might reference api.sqlite3_*)
// client.odin imports fts directly for SQLite calls; these re-exports
// are for other packages that might reference api.sqlite3_*
// (not currently used — kept for compatibility)
