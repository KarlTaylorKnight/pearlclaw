pub const ollama = @import("ollama/root.zig");
pub const openai = @import("openai/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
