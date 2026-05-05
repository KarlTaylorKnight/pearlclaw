pub const ollama = @import("ollama/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
