//! Tool-call parser — Zig port of `crates/zeroclaw-tool-call-parser/src/lib.rs`.
//!
//! Public surface mirrors the Rust crate:
//!   - `ParsedToolCall` (struct)
//!   - `parseToolCalls(allocator, response) -> ParseResult` (main entry)
//!   - `canonicalizeJsonForToolSignature(...)`
//!   - `stripThinkTags(...)`
//!   - `stripToolResultBlocks(...)`
//!   - `detectToolCallParseIssue(...)`
//!   - `buildNativeAssistantHistoryFromParsedCalls(...)`
//!
//! Memory model: caller-owns. Pass an `std.mem.Allocator`; free parse
//! results with `ParseResult.deinit`.

pub const ParsedToolCall = @import("types.zig").ParsedToolCall;
pub const ParseResult = @import("types.zig").ParseResult;
pub const parseToolCalls = @import("entry.zig").parseToolCalls;
pub const canonicalizeJsonForToolSignature = @import("json.zig").canonicalizeJsonForToolSignature;
pub const writeCanonicalJsonValue = @import("json.zig").writeCanonicalJsonValue;
pub const stripThinkTags = @import("cleanup.zig").stripThinkTags;
pub const stripToolResultBlocks = @import("cleanup.zig").stripToolResultBlocks;
pub const detectToolCallParseIssue = @import("entry.zig").detectToolCallParseIssue;
pub const buildNativeAssistantHistoryFromParsedCalls = @import("entry.zig").buildNativeAssistantHistoryFromParsedCalls;

test {
    @import("std").testing.refAllDecls(@This());
}
