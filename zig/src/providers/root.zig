pub const ollama = @import("ollama/root.zig");
pub const openai = @import("openai/root.zig");
pub const provider = @import("provider.zig");
pub const Provider = provider.Provider;

test {
    @import("std").testing.refAllDecls(@This());
}
