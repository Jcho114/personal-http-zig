const std = @import("std");

const wsFilter = "\n\r\t ";

fn inSlice(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |thing| {
        if (thing == needle) {
            return true;
        }
    }
    return false;
}

fn parseWsp(index: usize, buffer: []const u8) !usize {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }
    var i = index;
    while (index < buffer.len and inSlice(u8, wsFilter, buffer[i])) {
        i += 1;
    }
    return i;
}

const digitsFilter = "0123456789";

const ParseNumberResult = struct {
    value: f64,
    index: usize,
};

fn parseNumber(index: usize, buffer: []const u8) !ParseNumberResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    const negative = buffer[index] == '-';
    var i = index;
    if (negative) {
        i += 1;
    }

    if (!inSlice(u8, digitsFilter[1..], buffer[i])) {
        return error.ParseNumberError;
    }

    var whole: f64 = 0;
    while (i < buffer.len) {
        const digit = std.fmt.parseInt(u8, &[_]u8{buffer[i]}, 10) catch {
            break;
        };
        whole = whole * 10.0 + @as(f64, @floatFromInt(digit));
        i += 1;
    }

    var isFraction = false;
    if (buffer[i] == '.') {
        isFraction = true;
        i += 1;
    }

    var fraction: f64 = 0;
    var decimal: f64 = 1.0;
    while (i < buffer.len and isFraction) {
        const digit = std.fmt.parseInt(u8, &[_]u8{buffer[i]}, 10) catch {
            break;
        };
        fraction = fraction + (@as(f64, @floatFromInt(digit)) / std.math.pow(f64, 10.0, decimal));
        decimal += 1.0;
        i += 1;
    }

    var res = whole + fraction;
    if (negative) {
        res *= -1;
    }

    return .{
        .value = res,
        .index = i,
    };
}

const controlFilter = "\"\\/bfnrtu";

const ParseStringResult = struct { value: []const u8, index: usize };

fn parseString(index: usize, buffer: []const u8) !ParseStringResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    var i = index;
    if (buffer[i] != '"') {
        return error.ParseStringError;
    }
    i += 1;

    while (i < buffer.len and buffer[i] != '"') {
        if (buffer[i] == '\\') {
            if (!inSlice(u8, controlFilter, buffer[i])) {
                return error.ParseStringError;
            }
            if (i + 1 < buffer.len and buffer[i + 1] == 'u') {
                i += 4;
            }
        }
        i += 1;
    }

    if (buffer[i] != '"') {
        return error.ParseStringError;
    }

    const value = buffer[index + 1 .. i];
    return .{
        .value = value,
        .index = i + 1,
    };
}

const ParseBoolResult = struct {
    value: bool,
    index: usize,
};

fn parseBool(index: usize, buffer: []const u8) !ParseBoolResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    if (index + 4 <= buffer.len and std.mem.eql(u8, buffer[index .. index + 4], "true")) {
        return .{
            .value = true,
            .index = index + 4,
        };
    }

    if (index + 5 <= buffer.len and std.mem.eql(u8, buffer[index .. index + 5], "false")) {
        return .{
            .value = false,
            .index = index + 5,
        };
    }

    return error.ParseBoolError;
}

const JsonValueTag = enum { object, array, string, int, float, bool, null };

fn GetTagType(comptime tag: JsonValueTag) type {
    return switch (tag) {
        .object => *JsonObject,
        .array => *JsonArray,
        .string => []const u8,
        .int => i64,
        .float => f64,
        .bool => bool,
        .null => bool,
    };
}

const JsonValue = union(JsonValueTag) {
    object: *JsonObject,
    array: *JsonArray,
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null: bool,
};

const ParseValueResult = struct {
    value: JsonValue,
    index: usize,
};

fn parseValue(index: usize, buffer: []const u8, allocator: std.mem.Allocator) anyerror!ParseValueResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    const i = try parseWsp(index, buffer);
    switch (buffer[i]) {
        '"' => {
            const res = try parseString(i, buffer);
            return .{
                .value = JsonValue{ .string = res.value },
                .index = try parseWsp(res.index, buffer),
            };
        },
        '-', '0'...'9' => {
            const res = try parseNumber(i, buffer);
            const isFloat = inSlice(u8, buffer[i..res.index], '.');
            if (isFloat) {
                return .{
                    .value = JsonValue{ .float = res.value },
                    .index = try parseWsp(res.index, buffer),
                };
            } else {
                return .{
                    .value = JsonValue{ .int = @as(i32, @intFromFloat(res.value)) },
                    .index = try parseWsp(res.index, buffer),
                };
            }
        },
        'f', 't' => {
            const res = try parseBool(i, buffer);
            return .{
                .value = JsonValue{ .bool = res.value },
                .index = try parseWsp(res.index, buffer),
            };
        },
        'n' => {
            if (std.mem.eql(u8, buffer[i .. i + 4], "null")) {
                return .{ .value = JsonValue{ .null = true }, .index = try parseWsp(i + 4, buffer) };
            } else return error.ParseNullError;
        },
        '[' => {
            const res = try parseArray(i, buffer, allocator);
            const array = try JsonArray.init(allocator);
            array.array = res.value;
            return .{
                .value = JsonValue{ .array = array },
                .index = try parseWsp(res.index, buffer),
            };
        },
        '{' => {
            const res = try parseObject(i, buffer, allocator);
            const object = try JsonObject.init(allocator);
            object.object = res.value;
            return .{
                .value = JsonValue{ .object = object },
                .index = try parseWsp(res.index, buffer),
            };
        },
        else => return error.ParseValueError,
    }
}

pub const JsonArray = struct {
    array: std.ArrayList(JsonValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*JsonArray {
        const res = try allocator.create(JsonArray);
        res.* = .{
            .array = std.ArrayList(JsonValue).init(allocator),
            .allocator = allocator,
        };
        return res;
    }

    pub fn parse(buffer: []const u8, allocator: std.mem.Allocator) !*JsonArray {
        const res = try allocator.create(JsonArray);
        const parseRes = try parseArray(0, buffer, allocator);
        if (parseRes.index != buffer.len) {
            return error.ParseArrayError;
        }
        res.* = .{
            .array = parseRes.value,
            .allocator = allocator,
        };
        return res;
    }

    pub fn get(self: *JsonArray, comptime tag: JsonValueTag, index: usize) !GetTagType(tag) {
        if (index >= self.array.items.len) return error.IndexOutOfRange;

        const val = self.array.items[index];
        if (val != tag) return error.UnexpectedType;

        return @field(val, @tagName(tag));
    }

    pub fn deinit(self: *JsonArray) void {
        for (self.array.items) |item| {
            switch (item) {
                .array => {
                    item.array.deinit();
                },
                .object => {
                    item.object.deinit();
                },
                else => continue,
            }
        }
        self.array.deinit();
        self.allocator.destroy(self);
    }
};

const ParseArrayResult = struct {
    value: std.ArrayList(JsonValue),
    index: usize,
};

fn parseArray(index: usize, buffer: []const u8, allocator: std.mem.Allocator) anyerror!ParseArrayResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    var i = index;
    if (buffer[i] != '[') {
        return error.ParseArrayError;
    }
    i += 1;

    i = try parseWsp(i, buffer);
    var list = std.ArrayList(JsonValue).init(allocator);

    if (buffer[i] == ']') {
        return .{
            .value = list,
            .index = i + 1,
        };
    }

    while (true) {
        const res = try parseValue(i, buffer, allocator);
        try list.append(res.value);
        i = try parseWsp(res.index, buffer);
        if (buffer[i] == ']') {
            break;
        }
        if (buffer[i] != ',') {
            return error.ParseArrayError;
        }
        i += 1;
    }
    i += 1;

    return .{
        .value = list,
        .index = i,
    };
}

pub const JsonObject = struct {
    object: std.hash_map.StringHashMap(JsonValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*JsonObject {
        const res = try allocator.create(JsonObject);
        res.* = .{
            .object = std.hash_map.StringHashMap(JsonValue).init(allocator),
            .allocator = allocator,
        };
        return res;
    }

    pub fn parse(buffer: []const u8, allocator: std.mem.Allocator) !*JsonObject {
        const res = try allocator.create(JsonObject);
        const parseRes = try parseObject(0, buffer, allocator);
        if (parseRes.index != buffer.len) {
            return error.ParseObjectError;
        }
        res.* = .{
            .object = parseRes.value,
            .allocator = allocator,
        };
        return res;
    }

    pub fn deinit(self: *JsonObject) void {
        var iter = self.object.valueIterator();
        while (iter.next()) |item| {
            switch (item.*) {
                .array => {
                    item.array.deinit();
                },
                .object => {
                    item.object.deinit();
                },
                else => continue,
            }
        }
        self.object.deinit();
        self.allocator.destroy(self);
    }
};

const ParseObjectResult = struct {
    value: std.hash_map.StringHashMap(JsonValue),
    index: usize,
};

fn parseObject(index: usize, buffer: []const u8, allocator: std.mem.Allocator) anyerror!ParseObjectResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    var i = index;
    if (buffer[i] != '{') {
        return error.ParseObjectError;
    }
    i += 1;

    i = try parseWsp(i, buffer);

    var object = std.hash_map.StringHashMap(JsonValue).init(allocator);

    if (buffer[i] == '}') {
        return .{
            .value = object,
            .index = i + 1,
        };
    }

    while (true) {
        const keyRes = try parseString(i, buffer);
        const key = keyRes.value;
        i = try parseWsp(keyRes.index, buffer);
        const valRes = try parseValue(i, buffer, allocator);
        const value = valRes.value;
        i = try parseWsp(valRes.index, buffer);
        try object.put(key, value);
        if (buffer[i] == ']') {
            break;
        }
        if (buffer[i] != ',') {
            return error.ParseObjectError;
        }
        i += 1;
    }
    i += 1;

    return .{
        .value = object,
        .index = i,
    };
}

const expect = std.testing.expect;

test "white space parsing" {
    try expect(try parseWsp(0, "test") == 0);
    try expect(try parseWsp(0, "   test") == 3);
    try expect(try parseWsp(0, "\t\r\n test") == 4);
}

// TODO = support exponentials
test "number (aka float) parsing" {
    var res = try parseNumber(0, "10 ");
    try expect(res.value == 10.0);
    try expect(res.index == 2);

    res = try parseNumber(0, "-10 ");
    try expect(res.value == -10.0);
    try expect(res.index == 3);

    res = try parseNumber(0, "10.51 ");
    try expect(res.value == 10.51);
    try expect(res.index == 5);

    res = try parseNumber(0, "-10.51 ");
    try expect(res.value == -10.51);
    try expect(res.index == 6);
}

test "string parsing" {
    var res = try parseString(0, "\"a\"");
    try expect(std.mem.eql(u8, res.value, "a"));
    try expect(res.index == 3);

    res = try parseString(0, "\"1\"");
    try expect(std.mem.eql(u8, res.value, "1"));
    try expect(res.index == 3);

    res = try parseString(0, "\"😊\"");
    try expect(std.mem.eql(u8, res.value, "😊"));
    try expect(res.index == 6);

    res = try parseString(0, "\"\t123\"");
    try expect(std.mem.eql(u8, res.value, "\t123"));
    try expect(res.index == 6);

    res = try parseString(0, "\"\"");
    try expect(std.mem.eql(u8, res.value, ""));
    try expect(res.index == 2);
}

test "boolean parsing" {
    var res = try parseBool(0, "false");
    try expect(res.value == false);
    try expect(res.index == 5);

    res = try parseBool(0, "true");
    try expect(res.value == true);
    try expect(res.index == 4);
}

test "array parsing" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const res1 = try JsonArray.parse("[1,2.0,3,4]", allocator);
    defer res1.deinit();
    var exp1 = try JsonArray.init(allocator);
    defer exp1.deinit();
    try exp1.array.appendSlice(&[_]JsonValue{
        .{ .int = 1 },
        .{ .float = 2.0 },
        .{ .int = 3 },
        .{ .int = 4 },
    });
    try expect(res1.array.items.len == exp1.array.items.len);
    try expect(try res1.get(.int, 0) == try exp1.get(.int, 0));
    try expect(try res1.get(.float, 1) == try exp1.get(.float, 1));
    try expect(try res1.get(.int, 2) == try exp1.get(.int, 2));
    try expect(try res1.get(.int, 3) == try exp1.get(.int, 3));

    const res2 = try JsonArray.parse("[]", allocator);
    defer res2.deinit();
    var exp2 = try JsonArray.init(allocator);
    defer exp2.deinit();
    try expect(res2.array.items.len == exp2.array.items.len);

    const res3 = try JsonArray.parse("[1]", allocator);
    defer res3.deinit();
    var exp3 = try JsonArray.init(allocator);
    defer exp3.deinit();
    try exp3.array.appendSlice(&[_]JsonValue{.{ .int = 1 }});
    try expect(res3.array.items.len == exp3.array.items.len);
    try expect(try res3.get(.int, 0) == try exp3.get(.int, 0));

    const res4 = try JsonArray.parse("[true, false, null]", allocator);
    defer res4.deinit();
    var exp4 = try JsonArray.init(allocator);
    defer exp4.deinit();
    try exp4.array.appendSlice(&[_]JsonValue{ .{ .bool = true }, .{ .bool = false }, .{ .null = true } });
    try expect(res4.array.items.len == exp4.array.items.len);
    try expect(try res4.get(.bool, 0) == try exp4.get(.bool, 0));
    try expect(try res4.get(.bool, 1) == try exp4.get(.bool, 1));
    try expect(try res4.get(.null, 2) == try exp4.get(.null, 2));

    const res5 = try JsonArray.parse("[\"test\"]", allocator);
    defer res5.deinit();
    var exp5 = try JsonArray.init(allocator);
    defer exp5.deinit();
    try exp5.array.appendSlice(&[_]JsonValue{.{ .string = "test" }});
    try expect(res5.array.items.len == exp5.array.items.len);
    try expect(std.mem.eql(u8, try res5.get(.string, 0), try exp5.get(.string, 0)));

    const res6 = try JsonArray.parse("[1, [true]]", allocator);
    defer res6.deinit();
    var exp6 = try JsonArray.init(allocator);
    defer exp6.deinit();
    var exp6Nested = try JsonArray.init(allocator);
    try exp6Nested.array.append(.{ .bool = true });
    try exp6.array.appendSlice(&[_]JsonValue{ .{ .int = 1 }, .{ .array = exp6Nested } });
    try expect(res6.array.items.len == exp6.array.items.len);
    try expect(try res6.get(.int, 0) == try exp6.get(.int, 0));
    try expect(try (try res6.get(.array, 1)).get(.bool, 0) == try (try exp6.get(.array, 1)).get(.bool, 0));
}
