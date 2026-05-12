//! HardwareMemoryMapTool port of `zeroclaw-tools/src/hardware_memory_map.rs`.
//!
//! Datasheet-lookup branch only — the Rust source's `#[cfg(feature="probe")]`
//! probe-rs branch is intentionally dropped per Phase 7-G pinned decision.
//! probe-rs requires a USB-attached MCU and is not exercised by deterministic
//! eval fixtures; live USB/SWD parity is out of scope.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "hardware_memory_map";
const DESCRIPTION =
    "Return the memory map (flash and RAM address ranges) for connected hardware. " ++
    "Use when: user asks for 'upper and lower memory addresses', 'memory map', " ++
    "'address space', or 'readable addresses'. Returns flash/RAM ranges from datasheets.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "board": {
    \\      "type": "string",
    \\      "description": "Optional board name (e.g. nucleo-f401re, arduino-uno). If omitted, returns map for first configured board."
    \\    }
    \\  }
    \\}
;

const MEMORY_MAP_NAMES = [_][]const u8{
    "nucleo-f401re",
    "nucleo-f411re",
    "arduino-uno",
    "arduino-mega",
    "esp32",
};

const MEMORY_MAP_VALUES = [_][]const u8{
    "Flash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)\nSTM32F401RET6, ARM Cortex-M4",
    "Flash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)\nSTM32F411RET6, ARM Cortex-M4",
    "Flash: 0x0000 - 0x3FFF (16 KB, ATmega328P)\nSRAM: 0x0100 - 0x08FF (2 KB)\nEEPROM: 0x0000 - 0x03FF (1 KB)",
    "Flash: 0x0000 - 0x3FFFF (256 KB, ATmega2560)\nSRAM: 0x0200 - 0x21FF (8 KB)\nEEPROM: 0x0000 - 0x0FFF (4 KB)",
    "Flash: 0x3F40_0000 - 0x3F7F_FFFF (4 MB typical)\nIRAM: 0x4000_0000 - 0x4005_FFFF\nDRAM: 0x3FFB_0000 - 0x3FFF_FFFF",
};

fn staticMapForBoard(board: []const u8) ?[]const u8 {
    for (MEMORY_MAP_NAMES, MEMORY_MAP_VALUES) |name, value| {
        if (std.mem.eql(u8, name, board)) return value;
    }
    return null;
}

pub const HardwareMemoryMapTool = struct {
    boards: []const []const u8,

    /// Caller retains ownership of `boards` (list of board name slices). The
    /// slice and its contents must outlive this tool. This mirrors the Rust
    /// constructor that takes `Vec<String>` by value but in the Zig pilot
    /// the boards configuration is read-only and owned upstream.
    pub fn init(_: std.mem.Allocator, boards: []const []const u8) HardwareMemoryMapTool {
        return .{ .boards = boards };
    }

    pub fn deinit(_: *HardwareMemoryMapTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *HardwareMemoryMapTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: Tool.VTable = .{
        .name = nameImpl,
        .description = descriptionImpl,
        .parametersSchema = parametersSchemaImpl,
        .execute = executeImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(_: *anyopaque) []const u8 {
        return NAME;
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return DESCRIPTION;
    }

    fn parametersSchemaImpl(_: *anyopaque, allocator: std.mem.Allocator) anyerror!std.json.Value {
        return parametersSchema(allocator);
    }

    fn executeImpl(ptr: *anyopaque, allocator: std.mem.Allocator, args: std.json.Value) anyerror!ToolResult {
        const self: *HardwareMemoryMapTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *HardwareMemoryMapTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *HardwareMemoryMapTool, allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
        // Resolve effective board name: explicit args.board > first configured
        // board > literal "unknown". Mirrors the Rust precedence chain.
        const explicit = boardArg(args);
        const board = explicit orelse firstBoard(self.boards) orelse "unknown";

        if (self.boards.len == 0) {
            return common.failure(
                allocator,
                "No peripherals configured. Add boards to config.toml [peripherals.boards].",
            );
        }

        if (staticMapForBoard(board)) |map| {
            return .{ .output = try std.fmt.allocPrint(
                allocator,
                "**{s}** (from datasheet):\n{s}",
                .{ board, map },
            ) };
        }

        return .{ .output = try formatUnknown(allocator, board) };
    }
};

fn boardArg(args: std.json.Value) ?[]const u8 {
    if (args != .object) return null;
    const raw = args.object.get("board") orelse return null;
    if (raw != .string) return null;
    return raw.string;
}

fn firstBoard(boards: []const []const u8) ?[]const u8 {
    if (boards.len == 0) return null;
    return boards[0];
}

fn formatUnknown(allocator: std.mem.Allocator, board: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print("No memory map for board '{s}'. Known boards: ", .{board});
    for (MEMORY_MAP_NAMES, 0..) |name, idx| {
        if (idx != 0) try out.appendSlice(", ");
        try out.appendSlice(name);
    }
    return out.toOwnedSlice();
}

// ─── Tests ──────────────────────────────────────────────────────────────

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn executeWithBoards(boards: []const []const u8, json: []const u8) !ToolResult {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();
    var tool_impl = HardwareMemoryMapTool.init(std.testing.allocator, boards);
    defer tool_impl.deinit(std.testing.allocator);
    return tool_impl.tool().execute(std.testing.allocator, parsed.value);
}

test "hardware_memory_map static lookup matches nucleo-f401re datasheet" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var result = try executeWithBoards(&boards, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        "**nucleo-f401re** (from datasheet):\nFlash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)\nSTM32F401RET6, ARM Cortex-M4",
        result.output,
    );
    try std.testing.expect(result.error_msg == null);
}

test "hardware_memory_map explicit board arg overrides first configured board" {
    const boards = [_][]const u8{ "nucleo-f401re", "esp32" };
    var result = try executeWithBoards(&boards, "{\"board\":\"esp32\"}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "**esp32** (from datasheet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "0x3F40_0000") != null);
}

test "hardware_memory_map unknown board lists known boards" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var result = try executeWithBoards(&boards, "{\"board\":\"mystery\"}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        "No memory map for board 'mystery'. Known boards: nucleo-f401re, nucleo-f411re, arduino-uno, arduino-mega, esp32",
        result.output,
    );
}

test "hardware_memory_map empty boards config returns error" {
    const boards = [_][]const u8{};
    var result = try executeWithBoards(&boards, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expectEqualStrings(
        "No peripherals configured. Add boards to config.toml [peripherals.boards].",
        result.error_msg.?,
    );
}

test "hardware_memory_map spec exposes name, description, parameters" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var tool_impl = HardwareMemoryMapTool.init(std.testing.allocator, &boards);
    defer tool_impl.deinit(std.testing.allocator);

    var spec = try tool_impl.tool().spec(std.testing.allocator);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(NAME, spec.name);
    try std.testing.expectEqualStrings(DESCRIPTION, spec.description);
    try std.testing.expect(spec.parameters == .object);
    try std.testing.expect(spec.parameters.object.contains("properties"));
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    const boards = [_][]const u8{"nucleo-f401re"};
    var parsed = try parseArgs(std.testing.allocator, "{}");
    defer parsed.deinit();
    var tool_impl = HardwareMemoryMapTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    const boards = [_][]const u8{};
    var parsed = try parseArgs(std.testing.allocator, "{}");
    defer parsed.deinit();
    var tool_impl = HardwareMemoryMapTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    const boards = [_][]const u8{"nucleo-f401re"};
    var tool_impl = HardwareMemoryMapTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "hardware_memory_map execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
