const std = @import("std");
const http = @import("http.zig");

const Headers = http.Headers;
const Method = http.Method;

pub const Request = struct {
    const Params = std.hash_map.StringHashMap([]const u8);

    allocator: std.mem.Allocator,
    method: Method,
    target: []const u8,
    protocol: []const u8,
    headers: Headers,
    body: []const u8,
    params: Params,

    pub fn init(allocator: std.mem.Allocator) !*Request {
        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = Method.GET,
            .target = "/",
            .protocol = "HTTP/1.1",
            .headers = Headers.init(allocator),
            .body = "",
            .params = Params.init(allocator),
        };
        return request;
    }

    pub fn parse(stream: []u8, allocator: std.mem.Allocator) !*Request {
        var it = std.mem.splitSequence(u8, stream, "\r\n");
        const firstLine = it.next() orelse return error.ParseError;
        var firstLineIt = std.mem.splitSequence(u8, firstLine, " ");

        const methodString = firstLineIt.next() orelse return error.ParseError;
        const method = std.meta.stringToEnum(Method, methodString) orelse return error.ParseError;

        const targetString = firstLineIt.next() orelse return error.ParseError;
        var targetIt = std.mem.splitSequence(u8, targetString, "?");
        const target = targetIt.next() orelse return error.ParseError;

        var params = Params.init(allocator);
        const paramString = targetIt.rest();
        if (paramString.len > 0) {
            var paramsIt = std.mem.splitSequence(u8, paramString, "&");
            while (paramsIt.next()) |par| {
                var paramIt = std.mem.splitSequence(u8, par, "=");
                const key = paramIt.next() orelse return error.ParseError;
                const value = paramIt.rest();
                try params.put(key, value);
            }
        }

        const protocol = firstLineIt.next() orelse return error.ParseError;

        var headers = Headers.init(allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.ParseError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .protocol = protocol,
            .headers = headers,
            .body = body,
            .params = params,
        };
        return request;
    }

    pub fn param(self: *Request, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn format(self: *Request, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const methodString = std.enums.tagName(Method, self.method) orelse std.debug.panic("unable to parse method to string...", .{});
        try writer.print("{s} {s} {s}\r\n", .{ methodString, self.target, self.protocol });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
    }

    pub fn deinit(self: *Request) void {
        self.allocator.destroy(self);
    }
};
