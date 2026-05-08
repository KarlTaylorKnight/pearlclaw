pub const schema = @import("schema.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
