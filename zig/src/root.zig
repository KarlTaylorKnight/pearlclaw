//! Zeroclaw — Zig port (pilot scope: parser + memory subset + dispatcher).
//!
//! This is the public root module. Each pilot subsystem lives under its
//! own subdirectory and is re-exported here; downstream binaries
//! (`eval-parser`, `eval-memory`, `eval-dispatcher`, `agent-benchmarks`)
//! import this module via `@import("zeroclaw")`.
//!
//! Out of scope for the pilot:
//!   - Async runtime (libxev) — enters at full memory port (D7).
//!   - LLM providers — Ollama + OpenAI only, post-pilot (D8).
//!   - Channels — orchestrator + cli only, post-pilot (D11).

const std = @import("std");

pub const tool_call_parser = @import("tool_call_parser/root.zig");
pub const memory = @import("memory/root.zig");
pub const runtime = @import("runtime/root.zig");
pub const providers = @import("providers/root.zig");
pub const agent_tools = @import("agent_tools/root.zig");
pub const api = @import("api/root.zig");
pub const auth_service = providers.auth.service;

// Re-exports for ergonomics. Stable surface that the pilot will hold to.
// Real types land here as each module's port reaches green.
//
// pub const ParsedToolCall = tool_call_parser.ParsedToolCall;
// pub const parseToolCalls = tool_call_parser.parseToolCalls;

test {
    std.testing.refAllDecls(@This());
}
