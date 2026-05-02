pub const dispatcher = @import("dispatcher.zig");

pub const ChatMessage = dispatcher.ChatMessage;
pub const ChatResponse = dispatcher.ChatResponse;
pub const ConversationMessage = dispatcher.ConversationMessage;
pub const NativeToolDispatcher = dispatcher.NativeToolDispatcher;
pub const ParsedToolCall = dispatcher.ParsedToolCall;
pub const ParseResult = dispatcher.ParseResult;
pub const ToolCall = dispatcher.ToolCall;
pub const ToolDispatcher = dispatcher.ToolDispatcher;
pub const ToolExecutionResult = dispatcher.ToolExecutionResult;
pub const ToolResultMessage = dispatcher.ToolResultMessage;
pub const XmlToolDispatcher = dispatcher.XmlToolDispatcher;

test {
    @import("std").testing.refAllDecls(@This());
}
