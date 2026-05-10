pub const ollama = @import("ollama/root.zig");
pub const openai = @import("openai/root.zig");
pub const auth = @import("auth/root.zig");
pub const multimodal = @import("multimodal.zig");
pub const provider = @import("provider.zig");
pub const secrets = @import("secrets.zig");
pub const MAX_API_ERROR_CHARS = secrets.MAX_API_ERROR_CHARS;
pub const scrubSecretPatterns = secrets.scrubSecretPatterns;
pub const sanitizeApiError = secrets.sanitizeApiError;
pub const Provider = provider.Provider;
pub const Capabilities = provider.Capabilities;
pub const ProviderCapabilities = provider.ProviderCapabilities;
pub const ChatRequest = provider.ChatRequest;
pub const ToolCall = provider.ToolCall;
pub const TokenUsage = provider.TokenUsage;
pub const ChatResponse = provider.ChatResponse;
pub const ToolResultMessage = provider.ToolResultMessage;
pub const ConversationMessage = provider.ConversationMessage;
pub const StreamChunk = provider.StreamChunk;
pub const StreamEvent = provider.StreamEvent;
pub const StreamOptions = provider.StreamOptions;
pub const StreamError = provider.StreamError;
pub const ProviderCapabilityError = provider.ProviderCapabilityError;
pub const ToolsPayload = provider.ToolsPayload;
pub const buildToolInstructionsText = provider.buildToolInstructionsText;

test {
    @import("std").testing.refAllDecls(@This());
}
