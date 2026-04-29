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
//! Memory model: caller-owns. Pass an `std.mem.Allocator`; free results
//! with `freeParseResult`. Arena-allocator helper available for batch-free.

// Skeleton stubs. The pilot implementation will replace these.
// Source of truth during port: rust/crates/zeroclaw-tool-call-parser/src/lib.rs

const std = @import("std");

// pub const ParsedToolCall = @import("types.zig").ParsedToolCall;
// pub const parseToolCalls = @import("entry.zig").parseToolCalls;

// Placeholder so `zig build test` compiles before the port lands.
test "placeholder" {
    try std.testing.expect(true);
}
