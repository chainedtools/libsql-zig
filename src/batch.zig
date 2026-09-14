//! Batch statement execution (local transaction or remote Hrana batch).

const std = @import("std");
const value = @import("value.zig");

/// One step in a `Connection.batch` call.
pub const Step = struct {
    sql: []const u8,
    /// Positional bind values (`?1`, `?2`, …).
    args: []const value.Value = &.{},
    /// Named bind values (`:name`, `@name`, `$name`).
    named_args: []const NamedArg = &.{},
    /// Whether the client wants result rows for this step (remote mainly).
    want_rows: bool = false,
};

pub const NamedArg = struct {
    name: []const u8,
    value: value.Value,
};

/// Aggregate outcome of a batch. Row materialization for remote is optional
/// Phase 3.1 — for now we expose affected counts only when available.
pub const Result = struct {
    /// Number of steps that ran (not skipped).
    steps_run: usize = 0,
    /// Sum of affected rows when the backend reports them (best-effort).
    total_affected: i64 = 0,
};
