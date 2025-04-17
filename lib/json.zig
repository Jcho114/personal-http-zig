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

fn parseString(index: usize, buffer: []const u8, allocator: std.mem.Allocator) !ParseStringResult {
    if (index >= buffer.len) {
        return error.IndexOutOfRange;
    }

    var i = index;
    if (buffer[i] != '"') {
        return error.ParseStringError;
    }
    i += 1;

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    while (i < buffer.len and buffer[i] != '"') {
        if (buffer[i] == '\\') {
            if (!inSlice(u8, controlFilter, buffer[i + 1])) {
                return error.ParseStringError;
            }
            if (i + 1 < buffer.len and buffer[i + 1] == 'u') {
                const hex = buffer[i + 2 .. i + 6];
                const value = try std.fmt.parseInt(u21, hex, 16);
                var unibuffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(value, &unibuffer);
                try result.appendSlice(unibuffer[0..len]);
                i += 6;
            } else {
                try result.append(buffer[i + 1]);
                i += 2;
            }
        } else {
            try result.append(buffer[i]);
            i += 1;
        }
    }

    if (buffer[i] != '"') {
        return error.ParseStringError;
    }

    const value = try result.toOwnedSlice();
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
            const res = try parseString(i, buffer, allocator);
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
                    .value = JsonValue{ .int = @as(i64, @intFromFloat(res.value)) },
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

fn unparseValue(value: JsonValue, allocator: std.mem.Allocator) anyerror![]const u8 {
    switch (value) {
        .object => return try value.object.unparse(),
        .array => return try value.array.unparse(),
        .string => return try unparseString(value.string, allocator),
        .int => return try std.fmt.allocPrint(allocator, "{d}", .{value.int}),
        .float => if (@floor(value.float) == value.float) {
            return try std.fmt.allocPrint(allocator, "{d}.0", .{value.float});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}", .{value.float});
        },
        .bool => return try std.fmt.allocPrint(allocator, "{}", .{value.bool}),
        .null => return try std.fmt.allocPrint(allocator, "null", .{}),
    }
}

fn unparseString(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try out.append('"');

    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice("\\\\"),
            '\"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\t' => try out.appendSlice("\\t"),
            '\r' => try out.appendSlice("\\r"),
            else => try out.append(c),
        }
    }

    try out.append('"');

    return try out.toOwnedSlice();
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

    pub fn unparse(self: *JsonArray) ![]const u8 {
        return try unparseArray(self.array, self.allocator);
    }

    fn roundtrip(buffer: []const u8, allocator: std.mem.Allocator) !bool {
        const first = try JsonArray.parse(buffer, allocator);
        defer first.deinit();

        const str = try first.unparse();
        defer allocator.free(str);

        const second = try JsonArray.parse(str, allocator);
        defer second.deinit();

        return first.equals(second);
    }

    pub fn equals(self: *JsonArray, other: *JsonArray) bool {
        if (self.array.items.len != other.array.items.len) return false;

        for (0..self.array.items.len) |i| {
            const left = self.array.items[i];
            const right = other.array.items[i];
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
                return false;
            }
            switch (left) {
                .object => if (!left.object.equals(right.object)) return false,
                .array => if (!left.array.equals(right.array)) return false,
                .string => if (!std.mem.eql(u8, left.string, right.string)) return false,
                .int => if (left.int != right.int) return false,
                .float => if (left.float != right.float) return false,
                .bool => if (left.bool != right.bool) return false,
                .null => if (left.null != right.null) return false,
            }
        }

        return true;
    }

    pub fn get(self: *JsonArray, comptime tag: JsonValueTag, index: usize) !GetTagType(tag) {
        if (index >= self.array.items.len) return error.IndexOutOfRange;

        const val = self.array.items[index];
        if (val != tag) return error.UnexpectedType;

        return @field(val, @tagName(tag));
    }

    pub fn add(self: *JsonArray, comptime tag: JsonValueTag, value: GetTagType(tag)) !void {
        const addValue = if (tag == .string) try self.allocator.dupe(u8, value) else value;
        try self.array.append(@unionInit(JsonValue, @tagName(tag), addValue));
    }

    pub fn addObject(self: *JsonArray) !*JsonObject {
        const object = try JsonObject.init(self.allocator);
        try self.array.append(.{ .object = object });
        return object;
    }

    pub fn addObjectWith(self: *JsonArray, buildFn: fn (*JsonObject) anyerror!void) !void {
        const object = try JsonObject.init(self.allocator);
        try buildFn(object);
        try self.array.append(.{ .object = object });
    }

    pub fn addArray(self: *JsonArray) !*JsonArray {
        const array = try JsonArray.init(self.allocator);
        try self.array.append(.{ .array = array });
        return array;
    }

    pub fn addArrayWith(self: *JsonArray, buildFn: fn (*JsonArray) anyerror!void) !void {
        const array = try JsonArray.init(self.allocator);
        try buildFn(array);
        try self.array.append(.{ .array = array });
    }

    pub fn deinit(self: *JsonArray) void {
        for (self.array.items) |item| {
            switch (item) {
                .array => item.array.deinit(),
                .object => item.object.deinit(),
                .string => self.allocator.free(item.string),
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

fn unparseArray(array: std.ArrayList(JsonValue), allocator: std.mem.Allocator) anyerror![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.append('[');

    for (array.items, 0..array.items.len) |item, i| {
        const str = try unparseValue(item, allocator);
        defer allocator.free(str);
        try result.appendSlice(str);
        if (i != array.items.len - 1) {
            try result.appendSlice(", ");
        }
    }

    try result.append(']');

    return result.toOwnedSlice();
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

    pub fn unparse(self: *JsonObject) ![]const u8 {
        return try unparseObject(self.object, self.allocator);
    }

    pub fn get(self: *JsonObject, comptime tag: JsonValueTag, key: []const u8) !GetTagType(tag) {
        const val = self.object.get(key) orelse return error.KeyDoesNotExist;

        if (val != tag) return error.UnexpectedType;

        return @field(val, @tagName(tag));
    }

    pub fn put(self: *JsonObject, comptime tag: JsonValueTag, key: []const u8, value: GetTagType(tag)) !void {
        const putKey = try self.allocator.dupe(u8, key);
        const putValue = if (tag == .string) try self.allocator.dupe(u8, value) else value;
        try self.object.put(putKey, @unionInit(JsonValue, @tagName(tag), putValue));
    }

    pub fn putObject(self: *JsonObject, key: []const u8) !*JsonObject {
        const putKey = try self.allocator.dupe(u8, key);
        const object = try JsonObject.init(self.allocator);
        try self.object.put(putKey, .{ .object = object });
        return object;
    }

    pub fn putObjectWith(self: *JsonObject, key: []const u8, buildFn: fn (*JsonObject) anyerror!void) !void {
        const putKey = try self.allocator.dupe(u8, key);
        const object = try JsonObject.init(self.allocator);
        try buildFn(object);
        try self.object.put(putKey, .{ .object = object });
    }

    pub fn putArray(self: *JsonObject, key: []const u8) !*JsonArray {
        const dupedKey = try self.allocator.dupe(u8, key);
        const array = try JsonArray.init(self.allocator);
        try self.object.put(dupedKey, .{ .array = array });
        return array;
    }

    pub fn putArrayWith(self: *JsonArray, key: []const u8, buildFn: fn (*JsonArray) anyerror!void) !void {
        const dupedKey = try self.allocator.dupe(u8, key);
        const array = try JsonArray.init(self.allocator);
        try buildFn(array);
        try self.object.put(dupedKey, .{ .array = array });
    }

    fn roundtrip(buffer: []const u8, allocator: std.mem.Allocator) !bool {
        const first = try JsonObject.parse(buffer, allocator);
        defer first.deinit();

        const str = try first.unparse();
        defer allocator.free(str);

        const second = try JsonObject.parse(str, allocator);
        defer second.deinit();

        return first.equals(second);
    }

    pub fn equals(self: *JsonObject, other: *JsonObject) bool {
        if (self.object.count() != other.object.count()) return false;

        var iter = self.object.iterator();
        while (iter.next()) |leftEntry| {
            const leftKey = leftEntry.key_ptr.*;
            const leftValue = leftEntry.value_ptr.*;
            const rightValue = other.object.get(leftKey) orelse return false;
            if (std.meta.activeTag(leftValue) != std.meta.activeTag(rightValue)) {
                return false;
            }
            switch (leftValue) {
                .object => if (!leftValue.object.equals(rightValue.object)) return false,
                .array => if (!leftValue.array.equals(rightValue.array)) return false,
                .string => if (!std.mem.eql(u8, leftValue.string, rightValue.string)) return false,
                .int => if (leftValue.int != rightValue.int) return false,
                .float => if (leftValue.float != rightValue.float) return false,
                .bool => if (leftValue.bool != rightValue.bool) return false,
                .null => if (leftValue.null != rightValue.null) return false,
            }
        }

        return true;
    }

    pub fn deinit(self: *JsonObject) void {
        var iter = self.object.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            switch (value) {
                .array => value.array.deinit(),
                .object => value.object.deinit(),
                .string => self.allocator.free(value.string),
                else => {},
            }
            self.allocator.free(key);
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
        const keyRes = try parseString(i, buffer, allocator);
        const key = keyRes.value;
        i = try parseWsp(keyRes.index, buffer);
        const colonIndex = std.mem.indexOf(u8, buffer[i..], ":") orelse return error.ParseObjectError;
        i = i + colonIndex + 1;
        i = try parseWsp(i, buffer);
        const valRes = try parseValue(i, buffer, allocator);
        const value = valRes.value;
        i = try parseWsp(valRes.index, buffer);
        try object.put(key, value);
        if (buffer[i] == '}') {
            break;
        }
        if (buffer[i] != ',') {
            return error.ParseObjectError;
        }
        i += 1;
        i = try parseWsp(i, buffer);
    }
    i += 1;

    return .{
        .value = object,
        .index = i,
    };
}

fn unparseObject(object: std.hash_map.StringHashMap(JsonValue), allocator: std.mem.Allocator) anyerror![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.append('{');

    var iter = object.iterator();
    const total = object.count();
    var i: usize = 0;
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        const val_str = try unparseValue(val, allocator);
        defer allocator.free(val_str);

        const entry_str = try std.fmt.allocPrint(allocator, "\"{s}\": {s}", .{ key, val_str });
        defer allocator.free(entry_str);

        try result.appendSlice(entry_str);

        if (i < total - 1) {
            try result.appendSlice(", ");
        }

        i += 1;
    }

    try result.append('}');

    return result.toOwnedSlice();
}

const expect = std.testing.expect;

test "white space parsing" {
    try expect(try parseWsp(0, "test") == 0);
    try expect(try parseWsp(0, "   test") == 3);
    try expect(try parseWsp(0, "\t\r\n test") == 4);
}

// TODO - support exponentials
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
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const res1 = try parseString(0, "\"a\"", allocator);
    defer allocator.free(res1.value);
    try expect(std.mem.eql(u8, res1.value, "a"));
    try expect(res1.index == 3);

    const res2 = try parseString(0, "\"1\"", allocator);
    defer allocator.free(res2.value);
    try expect(std.mem.eql(u8, res2.value, "1"));
    try expect(res2.index == 3);

    const res3 = try parseString(0, "\"😊\"", allocator);
    defer allocator.free(res3.value);
    try expect(std.mem.eql(u8, res3.value, "😊"));
    try expect(res3.index == 6);

    const res4 = try parseString(0, "\"\t123\"", allocator);
    defer allocator.free(res4.value);
    try expect(std.mem.eql(u8, res4.value, "\t123"));
    try expect(res4.index == 6);

    const res5 = try parseString(0, "\"\"", allocator);
    defer allocator.free(res5.value);
    try expect(std.mem.eql(u8, res5.value, ""));
    try expect(res5.index == 2);

    const res6 = try parseString(0, "\"a\\\"b\\\"\"", allocator);
    defer allocator.free(res6.value);
    try expect(std.mem.eql(u8, res6.value, "a\"b\""));
    try expect(res6.index == 8);

    const res7 = try parseString(0, "\"\\u0041\"", allocator);
    defer allocator.free(res7.value);
    try expect(std.mem.eql(u8, res7.value, "A"));
    try expect(res6.index == 8);
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

    try expect(try JsonArray.roundtrip("[1,2.0,3,4]", allocator));
    try expect(try JsonArray.roundtrip("[]", allocator));
    try expect(try JsonArray.roundtrip("[1]", allocator));
    try expect(try JsonArray.roundtrip("[true, -10.0, -1]", allocator));
    try expect(try JsonArray.roundtrip("[true, false, null]", allocator));
    try expect(try JsonArray.roundtrip("[\"test\"]", allocator));
    try expect(try JsonArray.roundtrip("[1, [true]]", allocator));
}

// TODO - Account for integer and float value overflow (there are some niche errors with that)
test "object parsing" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try expect(try JsonObject.roundtrip("{}", allocator));
    try expect(try JsonObject.roundtrip("{\"value\": 10}", allocator));
    try expect(try JsonObject.roundtrip("{\"name\":\"John\",\"age\":30}", allocator));
    try expect(try JsonObject.roundtrip("{\"person\":{\"name\":\"Alice\",\"age\":28},\"location\":\"NY\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"numbers\":[1,2,3,4],\"letters\":[\"a\",\"b\",\"c\"]}", allocator));
    try expect(try JsonObject.roundtrip("{\"is_active\":true,\"is_deleted\":false,\"data\":null}", allocator));
    try expect(try JsonObject.roundtrip("{\"string\":\"hello\",\"number\":123,\"float\":12.34,\"bool\":true,\"null_value\":null}", allocator));
    try expect(try JsonObject.roundtrip("{\"created_at\":\"2025-04-16T10:00:00Z\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"1\":\"one\",\"2\":\"two\",\"3\":\"three\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"matrix\":[[1,2,3],[4,5,6]]}", allocator));
    try expect(try JsonObject.roundtrip("{\"empty_array\":[],\"empty_object\":{}}", allocator));
    try expect(try JsonObject.roundtrip("{\"pi\":3.141592653589793}", allocator));
    try expect(try JsonObject.roundtrip("{\"UserId\":12345,\"userName\":\"john_doe\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"message\":\"Hello, \\\"World\\\"!\\nNew Line & Tab\\t\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"name\":\"Mary\",\"city\":\"Los Angeles\"}", allocator));
    try expect(try JsonObject.roundtrip("{\"description\":\"A very long string that could be used in testing how the parser and serializer handle long text content.\"}", allocator));
}

test "array building" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var array = try JsonArray.init(allocator);
    defer array.deinit();
    try array.add(.int, 10);
    try array.add(.bool, true);
    try array.add(.string, "test");
    try expect(try array.get(.int, 0) == 10);
    try expect(try array.get(.bool, 1) == true);
    try expect(std.mem.eql(u8, try array.get(.string, 2), "test"));
}

test "object building" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var object = try JsonObject.init(allocator);
    defer object.deinit();
    try object.put(.int, "key1", 10);
    try object.put(.bool, "key2", false);
    try object.put(.string, "key3", "test");
    try expect(try object.get(.int, "key1") == 10);
    try expect(try object.get(.bool, "key2") == false);
    try expect(std.mem.eql(u8, try object.get(.string, "key3"), "test"));
}

// TODO - Figure out ways to combat the verbosity
test "nested array and object building" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var outerArray = try JsonArray.init(allocator);
    defer outerArray.deinit();
    try (try outerArray.addObject()).put(.int, "key", 10);
    try expect(try (try outerArray.get(.object, 0)).get(.int, "key") == 10);
    try outerArray.addArrayWith(struct {
        fn build(array: *JsonArray) !void {
            try array.add(.float, -5.2);
        }
    }.build);
    try expect(try (try outerArray.get(.array, 1)).get(.float, 0) == -5.2);

    var outerObject = try JsonObject.init(allocator);
    defer outerObject.deinit();
    try (try outerObject.putArray("array")).add(.int, 10);
    try expect(try (try outerObject.get(.array, "array")).get(.int, 0) == 10);
    try outerObject.putObjectWith("object", struct {
        fn build(object: *JsonObject) !void {
            try object.put(.float, "float", -5.2);
        }
    }.build);
    try expect(try (try outerObject.get(.object, "object")).get(.float, "float") == -5.2);
}
