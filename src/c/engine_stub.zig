//! Stub root for the vendored SQLite amalgamation static library.
//!
//! The amalgamation (`vendor/sqlite3.c`) is compiled into `sqlite_amalg` and
//! linked from the public `zig_libsql` module and package tests. Consumers never
//! import this file — they only link the static lib via the module graph.
