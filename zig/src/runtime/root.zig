pub const agent = @import("agent/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
