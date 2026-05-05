const std = @import("std");
const parser_types = @import("../../tool_call_parser/types.zig");

pub const Options = struct {
    temperature: f64,
};

pub const OutgoingFunction = struct {
    name: []u8,
    arguments: std.json.Value,

    pub fn deinit(self: *OutgoingFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        parser_types.freeJsonValue(allocator, &self.arguments);
        self.* = undefined;
    }
};

pub const OutgoingToolCall = struct {
    kind: []u8,
    function: OutgoingFunction,

    pub fn deinit(self: *OutgoingToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        self.function.deinit(allocator);
        self.* = undefined;
    }
};

pub const Message = struct {
    role: []u8,
    content: ?[]u8 = null,
    images: ?[][]u8 = null,
    tool_calls: ?[]OutgoingToolCall = null,
    tool_name: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, role: []const u8, content: ?[]const u8) !Message {
        return .{
            .role = try allocator.dupe(u8, role),
            .content = if (content) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        if (self.content) |content| allocator.free(content);
        if (self.images) |images| {
            for (images) |image| allocator.free(image);
            allocator.free(images);
        }
        if (self.tool_calls) |calls| {
            for (calls) |*call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.tool_name) |tool_name| allocator.free(tool_name);
        self.* = undefined;
    }
};

pub const ChatRequest = struct {
    model: []u8,
    messages: []Message,
    stream: bool,
    options: Options,
    think: ?bool = null,
    tools: ?[]std.json.Value = null,

    pub fn deinit(self: *ChatRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.tools) |tools| {
            for (tools) |*tool| parser_types.freeJsonValue(allocator, tool);
            allocator.free(tools);
        }
        self.* = undefined;
    }
};

pub const OllamaFunction = struct {
    name: []u8,
    arguments: std.json.Value,

    pub fn deinit(self: *OllamaFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        parser_types.freeJsonValue(allocator, &self.arguments);
        self.* = undefined;
    }
};

pub const OllamaToolCall = struct {
    id: ?[]u8 = null,
    function: OllamaFunction,

    pub fn deinit(self: *OllamaToolCall, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        self.function.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResponseMessage = struct {
    content: []u8,
    tool_calls: []OllamaToolCall,
    thinking: ?[]u8 = null,

    pub fn deinit(self: *ResponseMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        for (self.tool_calls) |*call| call.deinit(allocator);
        allocator.free(self.tool_calls);
        if (self.thinking) |thinking| allocator.free(thinking);
        self.* = undefined;
    }
};

pub const ApiChatResponse = struct {
    message: ResponseMessage,
    prompt_eval_count: ?u64 = null,
    eval_count: ?u64 = null,

    pub fn deinit(self: *ApiChatResponse, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

test "message owns role and content" {
    var message = try Message.init(std.testing.allocator, "user", "hello");
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("user", message.role);
    try std.testing.expectEqualStrings("hello", message.content.?);
}
