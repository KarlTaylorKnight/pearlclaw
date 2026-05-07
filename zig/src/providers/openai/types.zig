const std = @import("std");
const parser_types = @import("../../tool_call_parser/types.zig");

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

pub const NativeChatRequest = struct {
    model: []u8,
    messages: []NativeMessage,
    temperature: f64,
    tools: ?[]NativeToolSpec = null,
    tool_choice: ?[]u8 = null,
    max_tokens: ?u32 = null,

    pub fn deinit(self: *NativeChatRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.tools) |tools| {
            for (tools) |*tool| tool.deinit(allocator);
            allocator.free(tools);
        }
        if (self.tool_choice) |tool_choice| allocator.free(tool_choice);
        self.* = undefined;
    }
};

pub const NativeMessage = struct {
    role: []u8,
    content: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: ?[]NativeToolCall = null,
    reasoning_content: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, role: []const u8, content: ?[]const u8) !NativeMessage {
        return .{
            .role = try allocator.dupe(u8, role),
            .content = if (content) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *NativeMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        if (self.content) |content| allocator.free(content);
        if (self.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        if (self.tool_calls) |calls| {
            for (calls) |*call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.reasoning_content) |reasoning| allocator.free(reasoning);
        self.* = undefined;
    }
};

pub const NativeToolSpec = struct {
    kind: []u8,
    function: NativeToolFunctionSpec,

    pub fn deinit(self: *NativeToolSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        self.function.deinit(allocator);
        self.* = undefined;
    }
};

pub const NativeToolFunctionSpec = struct {
    name: []u8,
    description: []u8,
    parameters: std.json.Value,

    pub fn deinit(self: *NativeToolFunctionSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        parser_types.freeJsonValue(allocator, &self.parameters);
        self.* = undefined;
    }
};

pub const NativeToolCall = struct {
    id: ?[]u8 = null,
    kind: ?[]u8 = null,
    function: NativeFunctionCall,

    pub fn deinit(self: *NativeToolCall, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.kind) |kind| allocator.free(kind);
        self.function.deinit(allocator);
        self.* = undefined;
    }
};

pub const NativeFunctionCall = struct {
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *NativeFunctionCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arguments);
        self.* = undefined;
    }
};

pub const NativeChatResponse = struct {
    choices: []NativeChoice,
    usage: ?UsageInfo = null,

    pub fn deinit(self: *NativeChatResponse, allocator: std.mem.Allocator) void {
        for (self.choices) |*choice| choice.deinit(allocator);
        allocator.free(self.choices);
        self.* = undefined;
    }
};

pub const UsageInfo = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    prompt_tokens_details: ?PromptTokensDetails = null,
};

pub const PromptTokensDetails = struct {
    cached_tokens: ?u64 = null,
};

pub const NativeChoice = struct {
    message: NativeResponseMessage,

    pub fn deinit(self: *NativeChoice, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

pub const NativeResponseMessage = struct {
    content: ?[]u8 = null,
    reasoning_content: ?[]u8 = null,
    tool_calls: ?[]NativeToolCall = null,

    pub fn effectiveContent(self: NativeResponseMessage, allocator: std.mem.Allocator) !?[]u8 {
        if (self.content) |content| {
            if (content.len != 0) return try allocator.dupe(u8, content);
        }
        if (self.reasoning_content) |reasoning| return try allocator.dupe(u8, reasoning);
        return null;
    }

    pub fn deinit(self: *NativeResponseMessage, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.reasoning_content) |reasoning| allocator.free(reasoning);
        if (self.tool_calls) |calls| {
            for (calls) |*call| call.deinit(allocator);
            allocator.free(calls);
        }
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
