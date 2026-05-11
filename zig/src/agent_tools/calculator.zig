//! CalculatorTool port of `zeroclaw-tools/src/calculator.rs`.

const std = @import("std");
const tool_mod = @import("tool.zig");
const parser_types = @import("../tool_call_parser/types.zig");

pub const Tool = tool_mod.Tool;
pub const ToolResult = tool_mod.ToolResult;

const NAME = "calculator";
const DESCRIPTION =
    "Perform arithmetic and statistical calculations. Supports 25 functions: " ++
    "add, subtract, divide, multiply, pow, sqrt, abs, modulo, round, " ++
    "log, ln, exp, factorial, sum, average, median, mode, min, max, " ++
    "range, variance, stdev, percentile, count, percentage_change, clamp. " ++
    "Use this tool whenever you need to compute a numeric result instead of guessing.";

const PARAMETERS_SCHEMA_JSON =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "function": {
    \\      "type": "string",
    \\      "description": "Calculation to perform. Arithmetic: add(values), subtract(values), divide(values), multiply(values), pow(a,b), sqrt(x), abs(x), modulo(a,b), round(x,decimals). Logarithmic/exponential: log(x,base?), ln(x), exp(x), factorial(x). Aggregation: sum(values), average(values), count(values), min(values), max(values), range(values). Statistics: median(values), mode(values), variance(values), stdev(values), percentile(values,p). Utility: percentage_change(a,b), clamp(x,min_val,max_val).",
    \\      "enum": [
    \\        "add", "subtract", "divide", "multiply", "pow", "sqrt",
    \\        "abs", "modulo", "round", "log", "ln", "exp", "factorial",
    \\        "sum", "average", "median", "mode", "min", "max", "range",
    \\        "variance", "stdev", "percentile", "count",
    \\        "percentage_change", "clamp"
    \\      ]
    \\    },
    \\    "values": {
    \\      "type": "array",
    \\      "items": { "type": "number" },
    \\      "description": "Array of numeric values. Required for: add, subtract, divide, multiply, sum, average, median, mode, min, max, range, variance, stdev, percentile, count."
    \\    },
    \\    "a": {
    \\      "type": "number",
    \\      "description": "First operand. Required for: pow, modulo, percentage_change."
    \\    },
    \\    "b": {
    \\      "type": "number",
    \\      "description": "Second operand. Required for: pow, modulo, percentage_change."
    \\    },
    \\    "x": {
    \\      "type": "number",
    \\      "description": "Input number. Required for: sqrt, abs, exp, ln, log, factorial."
    \\    },
    \\    "base": {
    \\      "type": "number",
    \\      "description": "Logarithm base (default: 10). Optional for: log."
    \\    },
    \\    "decimals": {
    \\      "type": "integer",
    \\      "description": "Number of decimal places for rounding. Required for: round."
    \\    },
    \\    "p": {
    \\      "type": "integer",
    \\      "description": "Percentile rank (0-100). Required for: percentile."
    \\    },
    \\    "min_val": {
    \\      "type": "number",
    \\      "description": "Minimum bound. Required for: clamp."
    \\    },
    \\    "max_val": {
    \\      "type": "number",
    \\      "description": "Maximum bound. Required for: clamp."
    \\    }
    \\  },
    \\  "required": ["function"]
    \\}
;

const CalcReturn = union(enum) {
    output: []u8,
    error_msg: []u8,
};

const JsonArgs = struct {
    allocator: std.mem.Allocator,
    value: std.json.Value,
    error_msg: ?[]u8 = null,

    fn deinit(self: *JsonArgs) void {
        if (self.error_msg) |msg| self.allocator.free(msg);
        self.error_msg = null;
    }

    fn takeError(self: *JsonArgs) []u8 {
        const msg = self.error_msg.?;
        self.error_msg = null;
        return msg;
    }

    fn setError(self: *JsonArgs, message: []const u8) !void {
        self.error_msg = try self.allocator.dupe(u8, message);
    }

    fn setErrorFmt(self: *JsonArgs, comptime fmt: []const u8, args: anytype) !void {
        self.error_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    fn field(self: JsonArgs, key: []const u8) ?std.json.Value {
        if (self.value != .object) return null;
        return self.value.object.get(key);
    }

    fn function(self: *JsonArgs) ![]const u8 {
        const raw = self.field("function") orelse {
            try self.setError("Missing required parameter: function");
            return error.InvalidArgument;
        };
        if (raw != .string) {
            try self.setError("Missing required parameter: function");
            return error.InvalidArgument;
        }
        return raw.string;
    }

    fn number(self: *JsonArgs, key: []const u8, name: []const u8) !f64 {
        const raw = self.field(key) orelse {
            try self.setErrorFmt("Missing required parameter: {s}", .{name});
            return error.InvalidArgument;
        };
        const n = valueAsF64(raw) orelse {
            try self.setErrorFmt("Missing required parameter: {s}", .{name});
            return error.InvalidArgument;
        };
        return n;
    }

    fn optionalF64(self: JsonArgs, key: []const u8) ?f64 {
        const raw = self.field(key) orelse return null;
        return valueAsF64(raw);
    }

    fn integer(self: *JsonArgs, key: []const u8, name: []const u8) !i64 {
        const raw = self.field(key) orelse {
            try self.setErrorFmt("Missing required parameter: {s}", .{name});
            return error.InvalidArgument;
        };
        if (raw != .integer) {
            try self.setErrorFmt("Missing required parameter: {s}", .{name});
            return error.InvalidArgument;
        }
        return raw.integer;
    }

    fn values(self: *JsonArgs, min_len: usize) ![]f64 {
        const raw = self.field("values") orelse {
            try self.setError("Missing required parameter: values (array of numbers)");
            return error.InvalidArgument;
        };
        if (raw != .array) {
            try self.setError("Missing required parameter: values (array of numbers)");
            return error.InvalidArgument;
        }
        if (raw.array.items.len < min_len) {
            try self.setErrorFmt("Expected at least {d} value(s), got {d}", .{
                min_len,
                raw.array.items.len,
            });
            return error.InvalidArgument;
        }

        const nums = try self.allocator.alloc(f64, raw.array.items.len);
        errdefer self.allocator.free(nums);
        for (raw.array.items, 0..) |item, i| {
            const n = valueAsF64(item) orelse {
                try self.setErrorFmt("values[{d}] is not a valid number", .{i});
                return error.InvalidArgument;
            };
            nums[i] = n;
        }
        return nums;
    }
};

pub const CalculatorTool = struct {
    pub fn init(_: std.mem.Allocator) CalculatorTool {
        return .{};
    }

    pub fn deinit(_: *CalculatorTool, _: std.mem.Allocator) void {}

    pub fn tool(self: *CalculatorTool) Tool {
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
        _ = @as(*CalculatorTool, @ptrCast(@alignCast(ptr)));
        return execute(allocator, args);
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *CalculatorTool = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub fn parametersSchema(allocator: std.mem.Allocator) !std.json.Value {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, PARAMETERS_SCHEMA_JSON, .{});
        defer parsed.deinit();
        return parser_types.cloneJsonValue(allocator, parsed.value);
    }

    pub fn execute(allocator: std.mem.Allocator, args: std.json.Value) !ToolResult {
        const calc = try dispatch(allocator, args);
        return switch (calc) {
            .output => |output| .{
                .success = true,
                .output = output,
                .error_msg = null,
            },
            .error_msg => |msg| blk: {
                errdefer allocator.free(msg);
                const output = try allocator.dupe(u8, "");
                break :blk .{
                    .success = false,
                    .output = output,
                    .error_msg = msg,
                };
            },
        };
    }

    fn dispatch(allocator: std.mem.Allocator, args: std.json.Value) !CalcReturn {
        var reader = JsonArgs{ .allocator = allocator, .value = args };
        defer reader.deinit();

        const function_name = reader.function() catch |err| return invalidResult(&reader, err);
        const output = dispatchNamed(&reader, function_name) catch |err| return invalidResult(&reader, err);
        return .{ .output = output };
    }

    fn dispatchNamed(reader: *JsonArgs, function_name: []const u8) ![]u8 {
        if (std.mem.eql(u8, function_name, "add")) return calcAdd(reader);
        if (std.mem.eql(u8, function_name, "subtract")) return calcSubtract(reader);
        if (std.mem.eql(u8, function_name, "divide")) return calcDivide(reader);
        if (std.mem.eql(u8, function_name, "multiply")) return calcMultiply(reader);
        if (std.mem.eql(u8, function_name, "pow")) return calcPow(reader);
        if (std.mem.eql(u8, function_name, "sqrt")) return calcSqrt(reader);
        if (std.mem.eql(u8, function_name, "abs")) return calcAbs(reader);
        if (std.mem.eql(u8, function_name, "modulo")) return calcModulo(reader);
        if (std.mem.eql(u8, function_name, "round")) return calcRound(reader);
        if (std.mem.eql(u8, function_name, "log")) return calcLog(reader);
        if (std.mem.eql(u8, function_name, "ln")) return calcLn(reader);
        if (std.mem.eql(u8, function_name, "exp")) return calcExp(reader);
        if (std.mem.eql(u8, function_name, "factorial")) return calcFactorial(reader);
        if (std.mem.eql(u8, function_name, "sum")) return calcSum(reader);
        if (std.mem.eql(u8, function_name, "average")) return calcAverage(reader);
        if (std.mem.eql(u8, function_name, "median")) return calcMedian(reader);
        if (std.mem.eql(u8, function_name, "mode")) return calcMode(reader);
        if (std.mem.eql(u8, function_name, "min")) return calcMin(reader);
        if (std.mem.eql(u8, function_name, "max")) return calcMax(reader);
        if (std.mem.eql(u8, function_name, "range")) return calcRange(reader);
        if (std.mem.eql(u8, function_name, "variance")) return calcVariance(reader);
        if (std.mem.eql(u8, function_name, "stdev")) return calcStdev(reader);
        if (std.mem.eql(u8, function_name, "percentile")) return calcPercentile(reader);
        if (std.mem.eql(u8, function_name, "count")) return calcCount(reader);
        if (std.mem.eql(u8, function_name, "percentage_change")) return calcPercentageChange(reader);
        if (std.mem.eql(u8, function_name, "clamp")) return calcClamp(reader);

        try reader.setErrorFmt("Unknown function: {s}", .{function_name});
        return error.InvalidArgument;
    }
};

fn invalidResult(reader: *JsonArgs, err: anyerror) anyerror!CalcReturn {
    if (err == error.InvalidArgument) {
        return .{ .error_msg = reader.takeError() };
    }
    return err;
}

fn valueAsF64(value: std.json.Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => |inner| @floatFromInt(inner),
        .float => |inner| inner,
        .number_string => |inner| std.fmt.parseFloat(f64, inner) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(n)) return null;
    return n;
}

fn calcError(reader: *JsonArgs, message: []const u8) ![]u8 {
    try reader.setError(message);
    return error.InvalidArgument;
}

fn calcErrorFmt(reader: *JsonArgs, comptime fmt: []const u8, args: anytype) ![]u8 {
    try reader.setErrorFmt(fmt, args);
    return error.InvalidArgument;
}

fn calcAdd(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(2);
    defer reader.allocator.free(values);
    var result: f64 = 0.0;
    for (values) |v| result += v;
    return formatNum(reader.allocator, result);
}

fn calcSubtract(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(2);
    defer reader.allocator.free(values);
    var result = values[0];
    for (values[1..]) |v| result -= v;
    return formatNum(reader.allocator, result);
}

fn calcDivide(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(2);
    defer reader.allocator.free(values);
    var result = values[0];
    for (values[1..]) |v| {
        if (v == 0.0) return calcError(reader, "Division by zero");
        result /= v;
    }
    return formatNum(reader.allocator, result);
}

fn calcMultiply(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(2);
    defer reader.allocator.free(values);
    var result: f64 = 1.0;
    for (values) |v| result *= v;
    return formatNum(reader.allocator, result);
}

fn calcPow(reader: *JsonArgs) ![]u8 {
    const base = try reader.number("a", "a (base)");
    const exp = try reader.number("b", "b (exponent)");
    return formatNum(reader.allocator, std.math.pow(f64, base, exp));
}

fn calcSqrt(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    if (x < 0.0) return calcError(reader, "Cannot compute square root of a negative number");
    return formatNum(reader.allocator, @sqrt(x));
}

fn calcAbs(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    return formatNum(reader.allocator, @abs(x));
}

fn calcModulo(reader: *JsonArgs) ![]u8 {
    const a = try reader.number("a", "a");
    const b = try reader.number("b", "b");
    if (b == 0.0) return calcError(reader, "Modulo by zero");
    return formatNum(reader.allocator, @rem(a, b));
}

fn calcRound(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    const decimals = try reader.integer("decimals", "decimals");
    if (decimals < 0) return calcError(reader, "decimals must be non-negative");
    const pow_exp: i32 = if (decimals > std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(decimals);
    const multiplier = std.math.pow(f64, 10.0, @floatFromInt(pow_exp));
    return formatNum(reader.allocator, @round(x * multiplier) / multiplier);
}

fn calcLog(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    if (x <= 0.0) return calcError(reader, "Logarithm requires a positive number");
    const base = reader.optionalF64("base") orelse 10.0;
    if (base <= 0.0 or base == 1.0) {
        return calcError(reader, "Logarithm base must be positive and not equal to 1");
    }
    return formatNum(reader.allocator, @log(x) / @log(base));
}

fn calcLn(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    if (x <= 0.0) return calcError(reader, "Natural logarithm requires a positive number");
    return formatNum(reader.allocator, @log(x));
}

fn calcExp(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    return formatNum(reader.allocator, @exp(x));
}

fn calcFactorial(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    if (x < 0.0 or x != @floor(x)) {
        return calcError(reader, "Factorial requires a non-negative integer");
    }
    if (x > 170.0) return calcError(reader, "Factorial result exceeds f64 range (max input: 170)");
    const n: u128 = @intFromFloat(@round(x));
    if (n > 170) return calcError(reader, "Factorial result exceeds f64 range (max input: 170)");

    var result: u128 = 1;
    var i: u128 = 2;
    while (i <= n) : (i += 1) {
        result *%= i;
    }
    return std.fmt.allocPrint(reader.allocator, "{d}", .{result});
}

fn calcSum(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    var result: f64 = 0.0;
    for (values) |v| result += v;
    return formatNum(reader.allocator, result);
}

fn calcAverage(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len == 0) return calcError(reader, "Cannot compute average of an empty array");
    var sum: f64 = 0.0;
    for (values) |v| sum += v;
    return formatNum(reader.allocator, sum / @as(f64, @floatFromInt(values.len)));
}

fn calcMedian(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len == 0) return calcError(reader, "Cannot compute median of an empty array");
    std.sort.heap(f64, values, {}, f64LessThan);
    const len = values.len;
    if (len % 2 == 0) {
        const lower = values[len / 2 - 1];
        const upper = values[len / 2];
        return formatNum(reader.allocator, lower + (upper - lower) / 2.0);
    }
    return formatNum(reader.allocator, values[len / 2]);
}

fn calcMode(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len == 0) return calcError(reader, "Cannot compute mode of an empty array");

    var freq = std.AutoHashMap(u64, usize).init(reader.allocator);
    defer freq.deinit();
    for (values) |v| {
        const key: u64 = @bitCast(v);
        const entry = try freq.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var max_freq: usize = 0;
    var freq_it = freq.valueIterator();
    while (freq_it.next()) |count| {
        if (count.* > max_freq) max_freq = count.*;
    }

    var seen = std.AutoHashMap(u64, void).init(reader.allocator);
    defer seen.deinit();
    var modes = std.ArrayList(f64).init(reader.allocator);
    defer modes.deinit();

    for (values) |v| {
        const key: u64 = @bitCast(v);
        if (freq.get(key).? == max_freq and !seen.contains(key)) {
            try seen.put(key, {});
            try modes.append(v);
        }
    }

    if (modes.items.len == 1) return formatNum(reader.allocator, modes.items[0]);

    var output = std.ArrayList(u8).init(reader.allocator);
    defer output.deinit();
    try output.appendSlice("Modes: ");
    for (modes.items, 0..) |mode, i| {
        if (i != 0) try output.appendSlice(", ");
        const formatted = try formatNum(reader.allocator, mode);
        defer reader.allocator.free(formatted);
        try output.appendSlice(formatted);
    }
    return output.toOwnedSlice();
}

fn calcMin(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    var min_val = values[0];
    for (values[1..]) |v| min_val = @min(min_val, v);
    return formatNum(reader.allocator, min_val);
}

fn calcMax(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    var max_val = values[0];
    for (values[1..]) |v| max_val = @max(max_val, v);
    return formatNum(reader.allocator, max_val);
}

fn calcRange(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len == 0) return calcError(reader, "Cannot compute range of an empty array");
    var min_val = std.math.inf(f64);
    var max_val = -std.math.inf(f64);
    for (values) |v| {
        min_val = @min(min_val, v);
        max_val = @max(max_val, v);
    }
    return formatNum(reader.allocator, max_val - min_val);
}

fn calcVariance(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len < 2) return calcError(reader, "Variance requires at least 2 values");
    const mean = meanOf(values);
    var sum_sq: f64 = 0.0;
    for (values) |v| sum_sq += std.math.pow(f64, v - mean, 2.0);
    return formatNum(reader.allocator, sum_sq / @as(f64, @floatFromInt(values.len)));
}

fn calcStdev(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len < 2) return calcError(reader, "Standard deviation requires at least 2 values");
    const mean = meanOf(values);
    var sum_sq: f64 = 0.0;
    for (values) |v| sum_sq += std.math.pow(f64, v - mean, 2.0);
    const variance = sum_sq / @as(f64, @floatFromInt(values.len));
    return formatNum(reader.allocator, @sqrt(variance));
}

fn calcPercentile(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    if (values.len == 0) return calcError(reader, "Cannot compute percentile of an empty array");
    const p = try reader.integer("p", "p (percentile rank 0-100)");
    if (p < 0 or p > 100) return calcError(reader, "Percentile rank must be between 0 and 100");

    std.sort.heap(f64, values, {}, f64LessThan);
    const idx_f = @as(f64, @floatFromInt(p)) / 100.0 * @as(f64, @floatFromInt(values.len - 1));
    const rounded = @round(idx_f);
    const clamped = @max(0.0, @min(rounded, @as(f64, @floatFromInt(values.len - 1))));
    const index: usize = @intFromFloat(clamped);
    return formatNum(reader.allocator, values[index]);
}

fn calcCount(reader: *JsonArgs) ![]u8 {
    const values = try reader.values(1);
    defer reader.allocator.free(values);
    return std.fmt.allocPrint(reader.allocator, "{d}", .{values.len});
}

fn calcPercentageChange(reader: *JsonArgs) ![]u8 {
    const old = try reader.number("a", "a (old value)");
    const new = try reader.number("b", "b (new value)");
    if (old == 0.0) return calcError(reader, "Cannot compute percentage change from zero");
    return formatNum(reader.allocator, (new - old) / @abs(old) * 100.0);
}

fn calcClamp(reader: *JsonArgs) ![]u8 {
    const x = try reader.number("x", "x");
    const min_val = try reader.number("min_val", "min_val");
    const max_val = try reader.number("max_val", "max_val");
    if (min_val > max_val) return calcError(reader, "min_val must be less than or equal to max_val");
    const clamped = if (x < min_val) min_val else if (x > max_val) max_val else x;
    return formatNum(reader.allocator, clamped);
}

fn f64LessThan(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn meanOf(values: []const f64) f64 {
    var sum: f64 = 0.0;
    for (values) |v| sum += v;
    return sum / @as(f64, @floatFromInt(values.len));
}

fn formatNum(allocator: std.mem.Allocator, n: f64) ![]u8 {
    if (std.math.isNan(n)) return allocator.dupe(u8, "NaN");
    if (std.math.isPositiveInf(n)) return allocator.dupe(u8, "inf");
    if (std.math.isNegativeInf(n)) return allocator.dupe(u8, "-inf");
    if (n == 0.0) return allocator.dupe(u8, "0");
    if (n == @floor(n) and @abs(n) < 1e15) {
        const rounded: i128 = @intFromFloat(@round(n));
        return std.fmt.allocPrint(allocator, "{d}", .{rounded});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{n});
}

fn parseArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn expectExecute(json: []const u8, success: bool, output: []const u8, error_substr: ?[]const u8) !void {
    var parsed = try parseArgs(std.testing.allocator, json);
    defer parsed.deinit();

    var calc = CalculatorTool.init(std.testing.allocator);
    defer calc.deinit(std.testing.allocator);

    var result = try calc.tool().execute(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(success, result.success);
    try std.testing.expectEqualStrings(output, result.output);
    if (error_substr) |needle| {
        try std.testing.expect(result.error_msg != null);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, needle) != null);
    } else {
        try std.testing.expect(result.error_msg == null);
    }
}

test "calculator arithmetic and statistical functions match Rust fixtures" {
    try expectExecute("{\"function\":\"add\",\"values\":[1,2,3]}", true, "6", null);
    try expectExecute("{\"function\":\"divide\",\"values\":[10,2]}", true, "5", null);
    try expectExecute("{\"function\":\"pow\",\"a\":2,\"b\":10}", true, "1024", null);
    try expectExecute("{\"function\":\"sqrt\",\"x\":16}", true, "4", null);
    try expectExecute("{\"function\":\"log\",\"x\":100}", true, "2", null);
    try expectExecute("{\"function\":\"log\",\"x\":8,\"base\":2}", true, "3", null);
    try expectExecute("{\"function\":\"factorial\",\"x\":5}", true, "120", null);
    try expectExecute("{\"function\":\"average\",\"values\":[1,2,3,4,5]}", true, "3", null);
    try expectExecute("{\"function\":\"median\",\"values\":[1,2,3,4]}", true, "2.5", null);
    try expectExecute(
        "{\"function\":\"stdev\",\"values\":[2,4,4,4,5,5,7,9]}",
        true,
        "2",
        null,
    );
    try expectExecute(
        "{\"function\":\"mode\",\"values\":[1,2,2,3,3,4]}",
        true,
        "Modes: 2, 3",
        null,
    );
}

test "calculator error cases return ToolResult failures" {
    try expectExecute("{\"function\":\"divide\",\"values\":[10,0]}", false, "", "Division by zero");
    try expectExecute("{\"function\":\"sqrt\",\"x\":-1}", false, "", "negative");
    try expectExecute("{\"function\":\"factorial\",\"x\":2.5}", false, "", "non-negative integer");
    try expectExecute("{\"function\":\"percentile\",\"values\":[1,2,3],\"p\":150}", false, "", "between 0 and 100");
    try expectExecute("{\"function\":\"nonexistent\"}", false, "", "Unknown function");
    try expectExecute("{\"values\":[1,2]}", false, "", "Missing required parameter: function");
    try expectExecute("{\"function\":\"clamp\",\"x\":5,\"min_val\":10,\"max_val\":0}", false, "", "min_val");
}

test "calculator spec returns owned provider-compatible ToolSpec" {
    var calc = CalculatorTool.init(std.testing.allocator);
    defer calc.deinit(std.testing.allocator);

    var spec = try calc.tool().spec(std.testing.allocator);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(NAME, spec.name);
    try std.testing.expectEqualStrings(DESCRIPTION, spec.description);
    try std.testing.expect(spec.parameters == .object);
    try std.testing.expect(spec.parameters.object.contains("properties"));
}

fn executeHappyOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"function\":\"add\",\"values\":[1,2,3]}");
    defer parsed.deinit();

    var calc = CalculatorTool.init(allocator);
    defer calc.deinit(allocator);
    var result = try calc.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("6", result.output);
}

fn executeErrorOomImpl(allocator: std.mem.Allocator) !void {
    var parsed = try parseArgs(std.testing.allocator, "{\"function\":\"divide\",\"values\":[1,0]}");
    defer parsed.deinit();

    var calc = CalculatorTool.init(allocator);
    defer calc.deinit(allocator);
    var result = try calc.tool().execute(allocator, parsed.value);
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "calculator execute is OOM safe for success and error results" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeHappyOomImpl, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeErrorOomImpl, .{});
}

fn parametersSchemaOomImpl(allocator: std.mem.Allocator) !void {
    var calc = CalculatorTool.init(allocator);
    defer calc.deinit(allocator);
    var value = try calc.tool().parametersSchema(allocator);
    defer parser_types.freeJsonValue(allocator, &value);
}

test "calculator parametersSchema is OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parametersSchemaOomImpl, .{});
}

test "calculator formatNum matches pinned Rust-style edge cases" {
    const allocator = std.testing.allocator;

    const two = try formatNum(allocator, 2.0);
    defer allocator.free(two);
    try std.testing.expectEqualStrings("2", two);

    const third = try formatNum(allocator, 1.0 / 3.0);
    defer allocator.free(third);
    try std.testing.expectEqualStrings("0.3333333333333333", third);

    const neg_zero = try formatNum(allocator, -0.0);
    defer allocator.free(neg_zero);
    try std.testing.expectEqualStrings("0", neg_zero);

    const large = try formatNum(allocator, 1e308);
    defer allocator.free(large);
    try std.testing.expectEqualStrings(
        "100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        large,
    );

    const small = try formatNum(allocator, 1.0 / 100_000_000.0);
    defer allocator.free(small);
    try std.testing.expectEqualStrings("0.00000001", small);
}
