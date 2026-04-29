//! eval-parser — language-agnostic parser eval runner (Zig side).
//!
//! Reads a tool-call response from stdin, runs the Zig parser, writes
//! canonical JSON to stdout. Mirrors `eval-tools/src/bin/eval-parser.rs`
//! on the Rust side. Used by the eval driver to verify byte-equal parity.
//!
//! Output schema (must match Rust eval-parser exactly):
//!   {"calls":[{"arguments":<json>,"name":"...","tool_call_id":null|"..."}],"text":"..."}

const std = @import("std");
// const zeroclaw = @import("zeroclaw");
// const parser = zeroclaw.tool_call_parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    // Pilot in progress — emit empty result so the binary builds and the
    // eval harness works end-to-end. Replace with real call once the
    // parser port lands:
    //
    //   var result = try parser.parseToolCalls(allocator, input);
    //   defer result.deinit(allocator);
    //   try emitCanonicalJson(allocator, result, std.io.getStdOut().writer());

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("{\"calls\":[],\"text\":\"\"}\n");
}
