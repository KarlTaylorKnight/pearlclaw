//! eval-parser — language-agnostic parser eval runner (Zig side).
//!
//! Reads a tool-call response from stdin, runs the Zig parser, writes
//! canonical JSON to stdout. Mirrors `eval-tools/src/bin/eval-parser.rs`
//! on the Rust side. Used by the eval driver to verify byte-equal parity.
//!
//! Output schema (must match Rust eval-parser exactly):
//!   {"calls":[{"arguments":<json>,"name":"...","tool_call_id":null|"..."}],"text":"..."}

const std = @import("std");
const zeroclaw = @import("zeroclaw");
const parser = zeroclaw.tool_call_parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    var result = try parser.parseToolCalls(allocator, input, null);
    defer result.deinit(allocator);

    try emitCanonicalJson(allocator, result, std.io.getStdOut().writer());
}

fn emitCanonicalJson(allocator: std.mem.Allocator, result: parser.ParseResult, writer: anytype) !void {
    try writer.writeAll("{\"calls\":[");
    for (result.calls, 0..) |call, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"arguments\":");
        try parser.writeCanonicalJsonValue(allocator, call.arguments, writer);
        try writer.writeAll(",\"name\":");
        try std.json.stringify(call.name, .{}, writer);
        try writer.writeAll(",\"tool_call_id\":");
        if (call.tool_call_id) |id| {
            try std.json.stringify(id, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"text\":");
    try std.json.stringify(result.text, .{}, writer);
    try writer.writeAll("}\n");
}
