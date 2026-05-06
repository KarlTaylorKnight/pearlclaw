const std = @import("std");

pub const Message = struct {
    role: []u8,
    content: []u8,

    pub fn init(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !Message {
        return .{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
        };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ChatRequest = struct {
    model: []u8,
    messages: []Message,
    temperature: f64,
    max_tokens: ?u32 = null,

    pub fn deinit(self: *ChatRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        self.* = undefined;
    }
};

pub const ResponseMessage = struct {
    content: ?[]u8 = null,
    reasoning_content: ?[]u8 = null,

    pub fn effectiveContent(self: ResponseMessage, allocator: std.mem.Allocator) ![]u8 {
        if (self.content) |content| {
            if (content.len != 0) return try allocator.dupe(u8, content);
        }
        if (self.reasoning_content) |reasoning| {
            return try allocator.dupe(u8, reasoning);
        }
        return try allocator.dupe(u8, "");
    }

    pub fn deinit(self: *ResponseMessage, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.reasoning_content) |reasoning| allocator.free(reasoning);
        self.* = undefined;
    }
};

pub const Choice = struct {
    message: ResponseMessage,

    pub fn deinit(self: *Choice, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

pub const ChatResponse = struct {
    choices: []Choice,

    pub fn deinit(self: *ChatResponse, allocator: std.mem.Allocator) void {
        for (self.choices) |*choice| choice.deinit(allocator);
        allocator.free(self.choices);
        self.* = undefined;
    }
};

test "effective content falls back to reasoning content" {
    var message = ResponseMessage{
        .content = try std.testing.allocator.dupe(u8, ""),
        .reasoning_content = try std.testing.allocator.dupe(u8, "thinking"),
    };
    defer message.deinit(std.testing.allocator);

    const result = try message.effectiveContent(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("thinking", result);
}
