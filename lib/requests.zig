const std = @import("std");
const http = @import("http.zig");

const Headers = http.Headers;
const Method = http.Method;
const Cookies = http.Cookies;

pub const Request = struct {
    const QueryParams = std.hash_map.StringHashMap([]const u8);
    const PathParams = std.hash_map.StringHashMap([]const u8);

    allocator: std.mem.Allocator,
    method: Method,
    target: []const u8,
    protocol: []const u8,
    headers: Headers,
    body: []const u8,
    queries: QueryParams,
    params: PathParams,
    cookies: Cookies,

    pub fn init(allocator: std.mem.Allocator) !*Request {
        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = Method.GET,
            .target = "/",
            .protocol = "HTTP/1.1",
            .headers = Headers.init(allocator),
            .body = "",
            .queries = QueryParams.init(allocator),
            .params = PathParams.init(allocator),
            .cookies = Cookies.init(allocator),
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

        var queries = QueryParams.init(allocator);
        const queryString = targetIt.rest();
        if (queryString.len > 0) {
            var queryIt = std.mem.splitSequence(u8, queryString, "&");
            while (queryIt.next()) |qry| {
                var qryIt = std.mem.splitSequence(u8, qry, "=");
                const key = qryIt.next() orelse return error.ParseError;
                const value = qryIt.rest();
                try queries.put(key, value);
            }
        }

        const protocol = firstLineIt.next() orelse return error.ParseError;

        var headers = Headers.init(allocator);
        var cookies = Cookies.init(allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.ParseError;
            const value = headerIt.rest();
            if (std.mem.eql(u8, key, "Cookie")) {
                var cookiesIt = std.mem.splitSequence(u8, value, "; ");
                while (cookiesIt.next()) |cookieStr| {
                    var cookieIt = std.mem.splitSequence(u8, cookieStr, "=");
                    const cookieKey = cookieIt.next() orelse return error.ParseError;
                    const cookieValue = cookieIt.rest();
                    try cookies.put(cookieKey, cookieValue);
                }
            } else {
                try headers.put(key, value);
            }
        }

        const body = it.rest();

        const params = PathParams.init(allocator);
        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .protocol = protocol,
            .headers = headers,
            .body = body,
            .queries = queries,
            .params = params,
            .cookies = cookies,
        };
        return request;
    }

    pub fn query(self: *Request, key: []const u8) ?[]const u8 {
        return self.queries.get(key);
    }

    pub fn param(self: *Request, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn cookie(self: *Request, key: []const u8) ?[]const u8 {
        return self.cookies.get(key);
    }

    pub fn format(self: *Request, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const methodString = std.enums.tagName(Method, self.method) orelse std.debug.panic("unable to parse method to string...", .{});
        try writer.print("{s} {s} {s}\r\n", .{ methodString, self.target, self.protocol });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        try writer.print("Cookie: ", .{});
        it = self.cookies.iterator();
        var index: usize = 0;
        const size = self.cookies.count();
        while (it.next()) |cookiePair| {
            if (index == size - 1) {
                try writer.print("{s}={s}", .{ cookiePair.key_ptr.*, cookiePair.value_ptr.* });
            } else {
                try writer.print("{s}={s}; ", .{ cookiePair.key_ptr.*, cookiePair.value_ptr.* });
            }
            index += 1;
        }
        try writer.print("\r\n", .{});
        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.queries.deinit();
        self.params.deinit();
        self.cookies.deinit();
        self.allocator.destroy(self);
    }
};
