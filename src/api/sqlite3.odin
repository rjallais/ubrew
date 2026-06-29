package api

import "core:c"

foreign import sqlite3_lib "sqlite3.o"

SQLITE_OK   :: 0
SQLITE_ROW  :: 100
SQLITE_DONE :: 101

SQLITE_OPEN_READONLY  :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE    :: 0x00000004
SQLITE_OPEN_NOMUTEX   :: 0x00008000

Sqlite3Db   :: struct {}
Sqlite3Stmt :: struct {}

foreign sqlite3_lib {
	sqlite3_initialize   :: proc() -> i32 ---
	sqlite3_shutdown     :: proc() -> i32 ---
	sqlite3_config       :: proc(op: i32, #c_vararg args: ..any) -> i32 ---
	sqlite3_open_v2      :: proc(filename: cstring, ppDb: ^^Sqlite3Db, flags: i32, zVfs: cstring) -> i32 ---
	sqlite3_close        :: proc(db: ^Sqlite3Db) -> i32 ---
	sqlite3_exec         :: proc(db: ^Sqlite3Db, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> i32 ---
	sqlite3_prepare_v2   :: proc(db: ^Sqlite3Db, sql: cstring, nByte: i32, ppStmt: ^^Sqlite3Stmt, pzTail: ^cstring) -> i32 ---
	sqlite3_step         :: proc(stmt: ^Sqlite3Stmt) -> i32 ---
	sqlite3_column_text  :: proc(stmt: ^Sqlite3Stmt, iCol: i32) -> cstring ---
	sqlite3_column_int   :: proc(stmt: ^Sqlite3Stmt, iCol: i32) -> i32 ---
	sqlite3_finalize     :: proc(stmt: ^Sqlite3Stmt) -> i32 ---
	sqlite3_reset        :: proc(stmt: ^Sqlite3Stmt) -> i32 ---
	sqlite3_errmsg       :: proc(db: ^Sqlite3Db) -> cstring ---
	sqlite3_changes      :: proc(db: ^Sqlite3Db) -> i32 ---
	sqlite3_bind_text    :: proc(stmt: ^Sqlite3Stmt, index: i32, value: cstring, n: i32, destructor: rawptr) -> i32 ---
	sqlite3_bind_int     :: proc(stmt: ^Sqlite3Stmt, index: i32, value: i32) -> i32 ---
}

SQLITE_TRANSIENT :: rawptr(~uintptr(0))
