//! ImageInfoTool port of `zeroclaw-tools/src/image_info.rs`.

const std = @import("std");
const common = @import("fs_common.zig");
const parser_types = @import("../tool_call_parser/types.zig");
const security_stub = @import("security_stub.zig");

pub const Tool = common.Tool;
pub const ToolResult = common.ToolResult;
pub const SecurityStub = security_stub.SecurityStub;

const NAME = "image_info";
const DESCRIPTION = "Read image file metadata (format, dimensions, size) and optionally return base64-encoded data.";
const MAX_IMAGE_BYTES: u64 = 5_242_880;

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Path to the image file (absolute or relative to workspace)"
    \\    },
    \\    "include_base64": {
    \\      "type": "boolean",
    \\      "description": "Include base64-encoded image data in output (default: false)"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
;

const Dimensions = struct {
    w: u32,
    h: u32,
};

pub const ImageInfoTool = struct {
    security: ?SecurityStub,

    pub fn init(_: std.mem.Allocator) ImageInfoTool {
        return .{ .security = null };
    }

    pub fn initWithSecurity(security: SecurityStub) ImageInfoTool {
        return .{ .security = security };
    }

    pub fn deinit(_: *ImageInfoTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *ImageInfoTool) Tool {
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
        const self: *ImageInfoTool = @ptrCast(@alignCast(ptr));
        return common.resultFromReturn(allocator, try self.dispatch(allocator, args));
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ImageInfoTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        return common.parametersSchema(allocator, PARAMETERS_SCHEMA_JSON);
    }

    fn dispatch(self: *ImageInfoTool, allocator: std.mem.Allocator, args: std.json.Value) !common.FsReturn {
        if (self.security) |*security| {
            return dispatchWithSecurity(allocator, args, security);
        }

        const workspace_canon = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
            return common.failureFmt(allocator, "Cannot resolve path '.': {s}", .{common.rustIoError(err)});
        };
        defer allocator.free(workspace_canon);

        var security = SecurityStub{ .workspace_dir = workspace_canon };
        return dispatchWithSecurity(allocator, args, &security);
    }
};

fn dispatchWithSecurity(
    allocator: std.mem.Allocator,
    args: std.json.Value,
    security: *SecurityStub,
) !common.FsReturn {
    var reader = common.JsonArgs{ .allocator = allocator, .value = args };
    defer reader.deinit();

    const path_str = reader.requiredString("path") catch |err| return common.invalidResult(&reader, err);
    const include_base64 = optionalBool(reader, "include_base64", false);

    if (!security.isPathAllowed(path_str)) {
        return common.failureFmt(allocator, "Path not allowed: {s} (must be within workspace)", .{path_str});
    }

    const meta = std.fs.cwd().statFile(path_str) catch |err| switch (err) {
        error.FileNotFound => return common.failureFmt(allocator, "File not found: {s}", .{path_str}),
        else => return common.failureFmt(allocator, "Failed to read file metadata: {s}", .{common.rustIoError(err)}),
    };
    const file_size = meta.size;

    if (file_size > MAX_IMAGE_BYTES) {
        return common.failureFmt(
            allocator,
            "Image too large: {d} bytes (max 5242880 bytes)",
            .{file_size},
        );
    }

    const read_limit = std.math.cast(usize, MAX_IMAGE_BYTES + 1) orelse std.math.maxInt(usize);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path_str, read_limit) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return common.failureFmt(allocator, "Failed to read image file: {s}", .{common.rustIoError(err)}),
    };
    defer allocator.free(bytes);

    const format = detectFormat(bytes);
    const dimensions = extractDimensions(bytes, format);

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();
    try writer.print("File: {s}\nFormat: {s}\nSize: {d} bytes", .{ path_str, format, file_size });

    if (dimensions) |dims| {
        try writer.print("\nDimensions: {d}x{d}", .{ dims.w, dims.h });
    }

    if (include_base64) {
        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        const encoded_buf = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded_buf);
        _ = std.base64.standard.Encoder.encode(encoded_buf, bytes);
        try writer.print("\ndata:{s};base64,{s}", .{ mimeForFormat(format), encoded_buf });
    }

    return .{ .output = try output.toOwnedSlice() };
}

fn optionalBool(reader: common.JsonArgs, key: []const u8, default: bool) bool {
    const raw = reader.field(key) orelse return default;
    if (raw != .bool) return default;
    return raw.bool;
}

fn detectFormat(bytes: []const u8) []const u8 {
    if (bytes.len < 4) {
        return "unknown";
    }
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) {
        return "png";
    } else if (std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) {
        return "jpeg";
    } else if (std.mem.startsWith(u8, bytes, "GIF8")) {
        return "gif";
    } else if (std.mem.startsWith(u8, bytes, "RIFF") and bytes.len >= 12 and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "webp";
    } else if (std.mem.startsWith(u8, bytes, "BM")) {
        return "bmp";
    } else {
        return "unknown";
    }
}

fn extractDimensions(bytes: []const u8, format: []const u8) ?Dimensions {
    if (std.mem.eql(u8, format, "png")) {
        if (bytes.len >= 24) {
            const w = std.mem.readInt(u32, bytes[16..20], .big);
            const h = std.mem.readInt(u32, bytes[20..24], .big);
            return .{ .w = w, .h = h };
        }
        return null;
    }
    if (std.mem.eql(u8, format, "gif")) {
        if (bytes.len >= 10) {
            const w: u32 = std.mem.readInt(u16, bytes[6..8], .little);
            const h: u32 = std.mem.readInt(u16, bytes[8..10], .little);
            return .{ .w = w, .h = h };
        }
        return null;
    }
    if (std.mem.eql(u8, format, "bmp")) {
        if (bytes.len >= 26) {
            const w = std.mem.readInt(u32, bytes[18..22], .little);
            const h_raw = std.mem.readInt(i32, bytes[22..26], .little);
            const h: u32 = @abs(h_raw);
            return .{ .w = w, .h = h };
        }
        return null;
    }
    if (std.mem.eql(u8, format, "jpeg")) {
        return jpegDimensions(bytes);
    }
    return null;
}

fn jpegDimensions(bytes: []const u8) ?Dimensions {
    var i: usize = 2;
    while (i + 1 < bytes.len) {
        if (bytes[i] != 0xFF) return null;
        const marker = bytes[i + 1];
        i += 2;

        if (marker >= 0xC0 and marker <= 0xC3) {
            if (i + 7 > bytes.len) return null;
            const h: u32 = std.mem.readInt(u16, bytes[i + 3 ..][0..2], .big);
            const w: u32 = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
            return .{ .w = w, .h = h };
        }

        if (i + 1 >= bytes.len) return null;
        const seg_len: usize = std.mem.readInt(u16, bytes[i..][0..2], .big);
        if (seg_len < 2) return null;
        i += seg_len;
    }
    return null;
}

fn mimeForFormat(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, "png")) return "image/png";
    if (std.mem.eql(u8, format, "jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, format, "gif")) return "image/gif";
    if (std.mem.eql(u8, format, "webp")) return "image/webp";
    if (std.mem.eql(u8, format, "bmp")) return "image/bmp";
    return "application/octet-stream";
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

const MINIMAL_PNG: [69]u8 = .{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
    0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "image_info tool metadata and schema" {
    var tool_impl = ImageInfoTool.initWithSecurity(.{ .workspace_dir = "." });
    defer tool_impl.deinit(std.testing.allocator);
    const tool_value = tool_impl.tool();
    try std.testing.expectEqualStrings("image_info", tool_value.name());
    try std.testing.expect(std.mem.indexOf(u8, tool_value.description(), "image") != null);

    var schema = try tool_value.parametersSchema(std.testing.allocator);
    defer parser_types.freeJsonValue(std.testing.allocator, &schema);
    try std.testing.expect(schema == .object);
    try std.testing.expect(schema.object.get("properties").?.object.get("path") != null);
    try std.testing.expect(schema.object.get("properties").?.object.get("include_base64") != null);
}

test "image_info detects formats in Rust order" {
    try std.testing.expectEqualStrings("png", detectFormat("\x89PNG\r\n\x1a\n"));
    try std.testing.expectEqualStrings("jpeg", detectFormat("\xFF\xD8\xFF\xE0"));
    try std.testing.expectEqualStrings("gif", detectFormat("GIF89a"));
    try std.testing.expectEqualStrings("webp", detectFormat("RIFF\x00\x00\x00\x00WEBP"));
    try std.testing.expectEqualStrings("bmp", detectFormat("BM\x00\x00"));
    try std.testing.expectEqualStrings("unknown", detectFormat("\x00\x01"));
    try std.testing.expectEqualStrings("unknown", detectFormat("this is not an image"));
}

test "image_info extracts png gif bmp and unknown dimensions" {
    try std.testing.expectEqual(Dimensions{ .w = 1, .h = 1 }, extractDimensions(&MINIMAL_PNG, "png").?);

    const gif = [_]u8{
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
        0x40, 0x01, 0xF0, 0x00,
    };
    try std.testing.expectEqual(Dimensions{ .w = 320, .h = 240 }, extractDimensions(&gif, "gif").?);

    var bmp = [_]u8{0} ** 26;
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[18..22], 1024, .little);
    std.mem.writeInt(i32, bmp[22..26], -768, .little);
    try std.testing.expectEqual(Dimensions{ .w = 1024, .h = 768 }, extractDimensions(&bmp, "bmp").?);

    try std.testing.expect(extractDimensions("random data here", "unknown") == null);
}

test "image_info extracts jpeg dimensions and rejects malformed zero segment" {
    var jpeg = std.ArrayList(u8).init(std.testing.allocator);
    defer jpeg.deinit();
    try jpeg.appendSlice(&.{
        0xFF, 0xD8,
        0xFF, 0xE0,
        0x00, 0x10,
    });
    try jpeg.appendNTimes(0, 14);
    try jpeg.appendSlice(&.{
        0xFF, 0xC0,
        0x00, 0x11,
        0x08, 0x01,
        0xE0, 0x02,
        0x80,
    });
    try std.testing.expectEqual(Dimensions{ .w = 640, .h = 480 }, extractDimensions(jpeg.items, "jpeg").?);

    const malformed = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xE0,
        0x00, 0x00,
    };
    try std.testing.expect(extractDimensions(&malformed, "jpeg") == null);
}

test "image_info standard base64 matches Rust STANDARD padded output" {
    const bytes = "\x89PNG";
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try std.testing.allocator.alloc(u8, encoded_len);
    defer std.testing.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    try std.testing.expectEqualStrings("iVBORw==", encoded);
}

test "image_info executes png and base64 output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "test.png", .data = &MINIMAL_PNG });
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "test.png" });
    defer std.testing.allocator.free(path);

    const arg_path = try jsonString(std.testing.allocator, path);
    defer std.testing.allocator.free(arg_path);
    const args_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":{s},\"include_base64\":true}}", .{arg_path});
    defer std.testing.allocator.free(args_json);
    var parsed = try parseArgs(std.testing.allocator, args_json);
    defer parsed.deinit();

    var tool_impl = ImageInfoTool.initWithSecurity(.{ .workspace_dir = dir });
    defer tool_impl.deinit(std.testing.allocator);
    var result = try tool_impl.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Format: png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Size: 69 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Dimensions: 1x1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB") != null);
}

test "image_info reports missing path missing file path not allowed and too large" {
    var parsed_missing = try parseArgs(std.testing.allocator, "{}");
    defer parsed_missing.deinit();
    var tool_impl = ImageInfoTool.initWithSecurity(.{
        .workspace_dir = ".",
        .extra_blocked_paths = &.{"blocked.png"},
    });
    defer tool_impl.deinit(std.testing.allocator);

    var missing_path = try tool_impl.tool().execute(std.testing.allocator, parsed_missing.value);
    defer missing_path.deinit(std.testing.allocator);
    try std.testing.expect(!missing_path.success);
    try std.testing.expectEqualStrings("Missing 'path' parameter", missing_path.error_msg.?);

    var parsed_blocked = try parseArgs(std.testing.allocator, "{\"path\":\"blocked.png\"}");
    defer parsed_blocked.deinit();
    var blocked = try tool_impl.tool().execute(std.testing.allocator, parsed_blocked.value);
    defer blocked.deinit(std.testing.allocator);
    try std.testing.expect(!blocked.success);
    try std.testing.expectEqualStrings("Path not allowed: blocked.png (must be within workspace)", blocked.error_msg.?);

    var parsed_missing_file = try parseArgs(std.testing.allocator, "{\"path\":\"/tmp/nonexistent_image_xyz.png\"}");
    defer parsed_missing_file.deinit();
    var missing_file_tool = ImageInfoTool.initWithSecurity(.{ .workspace_dir = "/" });
    defer missing_file_tool.deinit(std.testing.allocator);
    var missing_file = try missing_file_tool.tool().execute(std.testing.allocator, parsed_missing_file.value);
    defer missing_file.deinit(std.testing.allocator);
    try std.testing.expect(!missing_file.success);
    try std.testing.expectEqualStrings("File not found: /tmp/nonexistent_image_xyz.png", missing_file.error_msg.?);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var big_file = try tmp.dir.createFile("big.bin", .{});
    try big_file.setEndPos(MAX_IMAGE_BYTES + 1);
    big_file.close();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const big_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "big.bin" });
    defer std.testing.allocator.free(big_path);
    const big_arg_path = try jsonString(std.testing.allocator, big_path);
    defer std.testing.allocator.free(big_arg_path);
    const big_args_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":{s}}}", .{big_arg_path});
    defer std.testing.allocator.free(big_args_json);
    var parsed_big = try parseArgs(std.testing.allocator, big_args_json);
    defer parsed_big.deinit();
    var big_tool = ImageInfoTool.initWithSecurity(.{ .workspace_dir = dir });
    defer big_tool.deinit(std.testing.allocator);
    var big = try big_tool.tool().execute(std.testing.allocator, parsed_big.value);
    defer big.deinit(std.testing.allocator);
    try std.testing.expect(!big.success);
    try std.testing.expectEqualStrings("Image too large: 5242881 bytes (max 5242880 bytes)", big.error_msg.?);
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "oom.png", .data = &MINIMAL_PNG });
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "oom.png" });
    defer std.testing.allocator.free(path);
    const arg_path = try jsonString(std.testing.allocator, path);
    defer std.testing.allocator.free(arg_path);
    const args_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":{s},\"include_base64\":true}}", .{arg_path});
    defer std.testing.allocator.free(args_json);
    var parsed = try parseArgs(std.testing.allocator, args_json);
    defer parsed.deinit();

    var tool_impl = ImageInfoTool.initWithSecurity(.{ .workspace_dir = dir });
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"path\":\"blocked.png\"}");
    defer parsed.deinit();
    var tool_impl = ImageInfoTool.initWithSecurity(.{
        .workspace_dir = ".",
        .extra_blocked_paths = &.{"blocked.png"},
    });
    defer tool_impl.deinit(allocator);
    var result = try tool_impl.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var tool_impl = ImageInfoTool.initWithSecurity(.{ .workspace_dir = "." });
    defer tool_impl.deinit(allocator);
    var value = try tool_impl.tool().parametersSchema(allocator);
    defer parser_types.freeJsonValue(allocator, &value);
}

test "image_info execute and parametersSchema are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(value, .{}, out.writer());
    return out.toOwnedSlice();
}
