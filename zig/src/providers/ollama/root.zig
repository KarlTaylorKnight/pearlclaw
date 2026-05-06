pub const types = @import("types.zig");
pub const client = @import("client.zig");

pub const OllamaProvider = client.OllamaProvider;
pub const normalizeBaseUrl = client.normalizeBaseUrl;
pub const stripThinkTags = client.stripThinkTags;
pub const effectiveContent = client.effectiveContent;
pub const fallbackTextForEmptyContent = client.fallbackTextForEmptyContent;
pub const parseToolArguments = client.parseToolArguments;
pub const formatToolCallsForLoop = client.formatToolCallsForLoop;
pub const extractToolNameAndArgs = client.extractToolNameAndArgs;
pub const parseChatResponseBody = client.parseChatResponseBody;
pub const ProviderChatRequest = client.ProviderChatRequest;

pub const ChatRequest = types.ChatRequest;
pub const Message = types.Message;
pub const Options = types.Options;
pub const OutgoingToolCall = types.OutgoingToolCall;
pub const OutgoingFunction = types.OutgoingFunction;
pub const ApiChatResponse = types.ApiChatResponse;
pub const ResponseMessage = types.ResponseMessage;
pub const OllamaToolCall = types.OllamaToolCall;
pub const OllamaFunction = types.OllamaFunction;

test {
    @import("std").testing.refAllDecls(@This());
}
