//! HardwareBoardInfoTool port of `zeroclaw-tools/src/hardware_board_info.rs`.
//!
//! Datasheet-lookup branch only — the Rust source's `#[cfg(feature="probe")]`
//! probe-rs branch is intentionally dropped per Phase 7-G pinned decision.
//! probe-rs requires a USB-attached MCU and is not exercised by deterministic
//! eval fixtures; live USB/SWD parity is out of scope.

const std = @import("std");
const common = @import("fs_common.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;

const NAME = "hardware_board_info";
const DESCRIPTION =
    "Return full board info (chip, architecture, memory map) for connected hardware. " ++
    "Use when: user asks for 'board info', 'what board do I have', 'connected hardware', " ++
    "'chip info', 'what hardware', or 'memory map'.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "board": {
    \\      "type": "string",
    \\      "description": "Optional board name (e.g. nucleo-f401re). If omitted, returns info for first configured board."
    \\    }
    \\  }
    \\}
;

const BoardEntry = struct {
    name: []const u8,
    chip: []const u8,
    desc: []const u8,
};

const BOARD_INFO = [_]BoardEntry{
    .{
        .name = "nucleo-f401re",
        .chip = "STM32F401RET6",
        .desc = "ARM Cortex-M4, 84 MHz. Flash: 512 KB, RAM: 128 KB. User LED on PA5 (pin 13).",
    },
    .{
        .name = "nucleo-f411re",
        .chip = "STM32F411RET6",
        .desc = "ARM Cortex-M4, 100 MHz. Flash: 512 KB, RAM: 128 KB. User LED on PA5 (pin 13).",
    },
    .{
        .name = "arduino-uno",
        .chip = "ATmega328P",
        .desc = "8-bit AVR, 16 MHz. Flash: 16 KB, SRAM: 2 KB. Built-in LED on pin 13.",
    },
    .{
        .name = "arduino-uno-q",
        .chip = "STM32U585 + Qualcomm",
        .desc = "Dual-core: STM32 (MCU) + Linux (aarch64). GPIO via Bridge app on port 9999.",
    },
    .{
        .name = "esp32",
        .chip = "ESP32",
        .desc = "Dual-core Xtensa LX6, 240 MHz. Flash: 4 MB typical. Built-in LED on GPIO 2.",
    },
    .{
        .name = "rpi-gpio",
        .chip = "Raspberry Pi",
        .desc = "ARM Linux. Native GPIO via sysfs/rppal. No fixed LED pin.",
    },
};

fn staticInfoForBoard(board: []const u8) ?BoardEntry {
    for (BOARD_INFO) |entry| {
        if (std.mem.eql(u8, entry.name, board)) return entry;
    }
    return null;
}

fn memoryMapStatic(board: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, board, "nucleo-f401re") or std.mem.eql(u8, board, "nucleo-f411re")) {
        return "Flash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)";
    }
    if (std.mem.eql(u8, board, "arduino-uno")) {
        return "Flash: 16 KB, SRAM: 2 KB, EEPROM: 1 KB";
    }
    if (std.mem.eql(u8, board, "esp32")) {
        return "Flash: 4 MB, IRAM/DRAM per ESP-IDF layout";
    }
    return null;
}

pub const HardwareBoardInfoTool = struct {
    boards: []const []const u8,

    /// Caller retains ownership of `boards`; mirrors Rust constructor (boards
    /// is a config-derived read-only list owned upstream).
    pub fn init(_: std.mem.Allocator, boards: []const []const u8) HardwareBoardInfoTool {
        return .{ .boards = boards };
    }

    pub fn deinit(_: *HardwareBoardInfoTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *HardwareBoardInfoTool) Tool {
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
        const self: *HardwareBoardInfoTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *HardwareBoardInfoTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *HardwareBoardInfoTool, allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
        const explicit = boardArg(args);
        const board = explicit orelse firstBoard(self.boards) orelse "unknown";

        if (self.boards.len == 0) {
            return common.failure(
                allocator,
                "No peripherals configured. Add boards to config.toml [peripherals.boards].",
            );
        }

        if (staticInfoForBoard(board)) |entry| {
            return .{ .output = try formatKnown(allocator, board, entry) };
        }

        return .{ .output = try std.fmt.allocPrint(
            allocator,
            "Board '{s}' configured. No static info available.",
            .{board},
        ) };
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

fn formatKnown(allocator: std.mem.Allocator, board: []const u8, entry: BoardEntry) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print(
        "**Board:** {s}\n**Chip:** {s}\n**Description:** {s}",
        .{ board, entry.chip, entry.desc },
    );
    if (memoryMapStatic(board)) |mem| {
        try out.writer().print("\n\n**Memory map:**\n{s}", .{mem});
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
    var tool_impl = HardwareBoardInfoTool.init(std.testing.allocator, boards);
    defer tool_impl.deinit(std.testing.allocator);
    return tool_impl.tool().execute(std.testing.allocator, parsed.value);
}

test "hardware_board_info nucleo-f401re returns full info with memory map" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var result = try executeWithBoards(&boards, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        "**Board:** nucleo-f401re\n**Chip:** STM32F401RET6\n**Description:** ARM Cortex-M4, 84 MHz. Flash: 512 KB, RAM: 128 KB. User LED on PA5 (pin 13).\n\n**Memory map:**\nFlash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)",
        result.output,
    );
}

test "hardware_board_info arduino-uno-q skips memory map (no static entry)" {
    const boards = [_][]const u8{"arduino-uno-q"};
    var result = try executeWithBoards(&boards, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    // Memory map is absent; the description line is the last line.
    try std.testing.expectEqualStrings(
        "**Board:** arduino-uno-q\n**Chip:** STM32U585 + Qualcomm\n**Description:** Dual-core: STM32 (MCU) + Linux (aarch64). GPIO via Bridge app on port 9999.",
        result.output,
    );
}

test "hardware_board_info unknown board returns terse message" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var result = try executeWithBoards(&boards, "{\"board\":\"mystery\"}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        "Board 'mystery' configured. No static info available.",
        result.output,
    );
}

test "hardware_board_info empty boards config returns error" {
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

test "hardware_board_info spec exposes name, description, parameters" {
    const boards = [_][]const u8{"nucleo-f401re"};
    var tool_impl = HardwareBoardInfoTool.init(std.testing.allocator, &boards);
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
    var tool_impl = HardwareBoardInfoTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    const boards = [_][]const u8{};
    var parsed = try parseArgs(std.testing.allocator, "{}");
    defer parsed.deinit();
    var tool_impl = HardwareBoardInfoTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    const boards = [_][]const u8{"nucleo-f401re"};
    var tool_impl = HardwareBoardInfoTool.init(allocator, &boards);
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer @import("../tool_call_parser/types.zig").freeJsonValue(allocator, &value);
}

test "hardware_board_info execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}
