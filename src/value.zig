//! SQL values for binding and (later) result materialization.

pub const Type = enum {
    null,
    integer,
    float,
    text,
    blob,
};

pub const Value = union(Type) {
    null: void,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,

    pub fn fromInt(v: i64) Value {
        return .{ .integer = v };
    }

    pub fn fromFloat(v: f64) Value {
        return .{ .float = v };
    }

    pub fn fromText(v: []const u8) Value {
        return .{ .text = v };
    }

    pub fn fromBlob(v: []const u8) Value {
        return .{ .blob = v };
    }

    pub fn fromNull() Value {
        return .{ .null = {} };
    }
};
